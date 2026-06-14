//! DEF/IMPL pairing, IMPORT resolution, graph construction.

use crate::cache::{ContentHash, hash_source};
use crate::graph::{ModuleGraph, ModuleId, ModuleNode};
use crate::search_path::SearchPath;
use crate::win32_finder::Win32Finder;
use newm2_lexer::{Env, preprocess, tokenize};
use newm2_parser::ast;
use newm2_parser::{parse_module, parse_module_with_source};
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub struct LoadError {
    pub message: String,
    pub path: Option<PathBuf>,
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if let Some(p) = &self.path {
            write!(f, "{}: {}", p.display(), self.message)
        } else {
            write!(f, "{}", self.message)
        }
    }
}

impl std::error::Error for LoadError {}

/// Modules implemented entirely in the compiler/runtime — never
/// loaded from disk. Their presence in IMPORT clauses is satisfied
/// by an intrinsic graph node with `is_intrinsic = true`.
pub const INTRINSIC_MODULES: &[&str] = &["SYSTEM", "COROUTINES"];

fn is_intrinsic(name: &str) -> bool {
    INTRINSIC_MODULES.iter().any(|n| *n == name)
}

/// Parse a single source file into an AST.
pub fn parse_file(path: &Path) -> Result<ast::Module, LoadError> {
    parse_file_with_env(path, &Env::target_default())
}

/// Parse a single source file into an AST using a caller-supplied
/// preprocessor environment.
pub fn parse_file_with_env(path: &Path, env: &Env) -> Result<ast::Module, LoadError> {
    let bytes = read_file(path)?;
    parse_bytes_with_env(&bytes, path, env)
}

/// Read a def file ONCE and return both its parsed AST and its content hash —
/// so the loader never re-reads a def to compute its hash separately.
fn parse_def_with_hash(path: &Path, env: &Env) -> Result<(ast::Module, ContentHash), LoadError> {
    let bytes = read_file(path)?;
    let hash = hash_source(&bytes);
    let ast = parse_bytes_with_env(&bytes, path, env)?;
    Ok((ast, hash))
}

fn read_file(path: &Path) -> Result<Vec<u8>, LoadError> {
    std::fs::read(path).map_err(|e| LoadError {
        message: format!("read failed: {e}"),
        path: Some(path.to_path_buf()),
    })
}

fn parse_bytes_with_env(bytes: &[u8], path: &Path, env: &Env) -> Result<ast::Module, LoadError> {
    let s = String::from_utf8_lossy(bytes);
    let preprocessed = preprocess(&s, env).map_err(|e| LoadError {
        message: format!("preprocess: {e}"),
        path: Some(path.to_path_buf()),
    })?;
    let tokens = tokenize(&preprocessed).map_err(|e| LoadError {
        message: format!("lex: {e}"),
        path: Some(path.to_path_buf()),
    })?;
    parse_module_with_source(&tokens, &preprocessed).map_err(|e| LoadError {
        message: format!("parse: {e}"),
        path: Some(path.to_path_buf()),
    })
}

/// Build the module graph rooted at `entry`. `entry` is the file the
/// user invoked the compiler on (typically a `.mod` PROGRAM module or
/// a `.def`); its imports are followed transitively. Each imported
/// module is resolved via `search_path`.
pub fn build_module_graph(
    entry: &Path,
    search_path: &SearchPath,
) -> Result<ModuleGraph, LoadError> {
    build_module_graph_with_env(entry, search_path, &Env::target_default())
}

pub fn build_module_graph_with_env(
    entry: &Path,
    search_path: &SearchPath,
    env: &Env,
) -> Result<ModuleGraph, LoadError> {
    build_module_graph_with_env_and_pack(entry, search_path, env, None)
}

pub fn build_module_graph_with_env_and_pack(
    entry: &Path,
    search_path: &SearchPath,
    env: &Env,
    win32_finder: Option<&Win32Finder>,
) -> Result<ModuleGraph, LoadError> {
    build_module_graph_with_extra_roots(entry, search_path, env, win32_finder, &[])
}

/// Like [`build_module_graph_with_env_and_pack`] but additionally force-loads
/// every module named in `extra_roots` into the graph even when no module
/// imports it. Used by `--m2-heap`: the codegen rewrites NEW/DISPOSE to call
/// `Heap.Alloc` / `Heap.Free`, so the `Heap` module must be compiled and linked
/// even though the user program never `IMPORT`s it.
pub fn build_module_graph_with_extra_roots(
    entry: &Path,
    search_path: &SearchPath,
    env: &Env,
    win32_finder: Option<&Win32Finder>,
    extra_roots: &[&str],
) -> Result<ModuleGraph, LoadError> {
    let mut g = ModuleGraph::new();
    let (entry_ast, entry_hash) = parse_def_with_hash(entry, env)?;
    let entry_name = entry_ast.name.clone();
    let entry_id = add_module(
        &mut g,
        entry_name.clone(),
        None,
        None,
        /* is_intrinsic = */ false,
        None,
    );

    match entry_ast.kind {
        ast::ModuleKind::Definition => {
            g.modules[entry_id.0].def_path = Some(entry.to_path_buf());
            g.modules[entry_id.0].def_ast = Some(entry_ast);
            g.modules[entry_id.0].def_hash = Some(entry_hash);

            let impl_path = search_path.find_impl_for_def(entry);
            let impl_ast = if let Some(path) = &impl_path {
                if should_load_impl_ast(path) {
                    let ast = parse_file_with_env(path, env)?;
                    if ast.name != entry_name {
                        return Err(LoadError {
                            message: format!(
                                "implementation module name mismatch: file declares {:?} but was paired with {entry_name:?}",
                                ast.name
                            ),
                            path: Some(path.clone()),
                        });
                    }
                    Some(ast)
                } else {
                    None
                }
            } else {
                None
            };
            g.modules[entry_id.0].impl_path = impl_path;
            g.modules[entry_id.0].impl_ast = impl_ast;
        }
        ast::ModuleKind::Implementation | ast::ModuleKind::Program | ast::ModuleKind::Local => {
            // A program is self-contained and has no def of its own; an
            // implementation/local module must pair with its *exactly* named def.
            let is_program = matches!(entry_ast.kind, ast::ModuleKind::Program);
            g.modules[entry_id.0].impl_path = Some(entry.to_path_buf());
            g.modules[entry_id.0].impl_ast = Some(entry_ast);

            if let Some(def_path) = search_path.find_def(&entry_name) {
                let (def_ast, def_hash) = parse_def_with_hash(&def_path, env)?;
                if def_ast.name == entry_name {
                    g.modules[entry_id.0].def_hash = Some(def_hash);
                    g.modules[entry_id.0].def_path = Some(def_path);
                    g.modules[entry_id.0].def_ast = Some(def_ast);
                } else if is_program && def_ast.name.eq_ignore_ascii_case(&entry_name) {
                    // The names differ only by case: on a case-insensitive
                    // filesystem `find_def("realconv")` matched a differently-cased
                    // library def (`RealConv.def`). The entry is a self-contained
                    // program with no def of its own — leave it unpaired.
                } else {
                    // Either a genuinely different name, or a case-only match for an
                    // implementation/local module. The latter must NOT silently drop
                    // its interface (opaque types, export checks); both are errors.
                    return Err(LoadError {
                        message: format!(
                            "module name mismatch: file declares {:?} but was paired with {entry_name:?}",
                            def_ast.name
                        ),
                        path: Some(def_path),
                    });
                }
            }
        }
    }

    // BFS over imports, parsing each newly-discovered DEF.
    let mut queue: Vec<ModuleId> = vec![entry_id];
    // Force-load extra roots (e.g. Heap for --m2-heap) so they are compiled and
    // linked even with no import edge from the entry.
    for r in extra_roots {
        resolve_or_load(&mut g, r, search_path, env, win32_finder, &mut queue)?;
    }
    while let Some(id) = queue.pop() {
        let names: Vec<String> = {
            let node = &g.modules[id.0];
            if node.impl_ast.is_none() && node.def_ast.is_none() {
                continue;
            }
            // A module's imports come from *both* its DEFINITION and its
            // IMPLEMENTATION: `IMPORT impc` may live only in the DEF while the
            // MOD imports nothing (separate compilation). Collect from each.
            let mut names = Vec::new();
            if let Some(a) = &node.def_ast {
                names.extend(collect_top_imports(a));
            }
            if let Some(a) = &node.impl_ast {
                names.extend(collect_top_imports(a));
            }
            names.sort();
            names.dedup();
            names
        };
        let mut child_ids = Vec::new();
        for name in &names {
            let child = resolve_or_load(&mut g, name, search_path, env, win32_finder, &mut queue)?;
            child_ids.push(child);
        }
        g.modules[id.0].imports = child_ids;

        // LOCAL MODULE enumeration: collect names from this module's
        // own decls and any nested procedure bodies.
        let local_names = {
            let node = &g.modules[id.0];
            let ast = node.impl_ast.as_ref().or(node.def_ast.as_ref()).unwrap();
            collect_local_module_names(ast)
        };
        g.modules[id.0].local_modules = local_names;
    }

    // Topological sort with cycle detection.
    g.topo_order = topo_sort(&g)?;
    Ok(g)
}

fn add_module(
    g: &mut ModuleGraph,
    name: String,
    def_path: Option<PathBuf>,
    def_ast: Option<ast::Module>,
    is_intrinsic: bool,
    def_hash: Option<ContentHash>,
) -> ModuleId {
    let id = ModuleId(g.modules.len());
    g.modules.push(ModuleNode {
        id,
        name: name.clone(),
        def_path,
        impl_path: None,
        def_ast,
        impl_ast: None,
        def_hash,
        imports: Vec::new(),
        local_modules: Vec::new(),
        is_intrinsic,
    });
    g.by_name.insert(name, id);
    id
}

fn resolve_or_load(
    g: &mut ModuleGraph,
    name: &str,
    search_path: &SearchPath,
    env: &Env,
    win32_finder: Option<&Win32Finder>,
    queue: &mut Vec<ModuleId>,
) -> Result<ModuleId, LoadError> {
    if let Some(id) = g.lookup(name) {
        return Ok(id);
    }
    if is_intrinsic(name) {
        let id = add_module(g, name.to_string(), None, None, true, None);
        return Ok(id);
    }
    // The Win32 def finder is an authoritative index over our generated
    // `library/NewM2` defs: binary-search the name to the def that declares it
    // and parse only that one file. It is consulted before the filesystem so a
    // Win32 module (e.g. `WIN32`) always resolves to our generated def, never a
    // same-named file elsewhere on the search path; a non-Win32 name misses the
    // index and falls through.
    if let Some(finder) = win32_finder {
        if let Some(def_path) = finder.find(name) {
            let (ast, def_hash) = parse_def_with_hash(&def_path, env)?;
            // Only accept it as this module when the def actually declares it
            // (the index also maps symbols to their owning module's def).
            if ast.name == name {
                let id =
                    add_module(g, name.to_string(), Some(def_path), Some(ast), false, Some(def_hash));
                queue.push(id);
                return Ok(id);
            }
        }
    }
    if let Some(def_path) = search_path.find_def(name) {
        let (ast, def_hash) = parse_def_with_hash(&def_path, env)?;
        if ast.name != name {
            return Err(LoadError {
                message: format!(
                    "module name mismatch: file declares {:?} but was imported as {name:?}",
                    ast.name
                ),
                path: Some(def_path),
            });
        }
        let impl_path = search_path.find_impl_for_def(&def_path);
        let impl_ast = if let Some(path) = &impl_path {
            if should_load_impl_ast(path) {
                let ast = parse_file_with_env(path, env)?;
                if ast.name != name {
                    return Err(LoadError {
                        message: format!(
                            "implementation module name mismatch: file declares {:?} but was imported as {name:?}",
                            ast.name
                        ),
                        path: Some(path.clone()),
                    });
                }
                Some(ast)
            } else {
                None
            }
        } else {
            None
        };
        let id = add_module(
            g,
            name.to_string(),
            Some(def_path.clone()),
            Some(ast),
            false,
            Some(def_hash),
        );
        g.modules[id.0].impl_path = impl_path;
        g.modules[id.0].impl_ast = impl_ast;
        queue.push(id);
        return Ok(id);
    }
    Err(LoadError {
        message: format!("module {name:?} not found in search path"),
        path: None,
    })
}

fn should_load_impl_ast(path: &Path) -> bool {
    !path.ancestors().any(|ancestor| {
        ancestor
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.eq_ignore_ascii_case("ADW reference"))
    })
}

fn collect_top_imports(m: &ast::Module) -> Vec<String> {
    let mut out = Vec::new();
    for imp in &m.imports {
        match imp {
            ast::Import::From { module, .. } => out.push(module.clone()),
            ast::Import::Plain { names, .. } => {
                for n in names {
                    // `IMPORT local := Real` aliases module `Real` to `local`;
                    // the module to load is the alias target, not the local name.
                    out.push(n.alias.clone().unwrap_or_else(|| n.name.clone()));
                }
            }
        }
    }
    out
}

fn collect_local_module_names(m: &ast::Module) -> Vec<String> {
    fn walk_decls(decls: &[ast::Decl], out: &mut Vec<String>) {
        for d in decls {
            match d {
                ast::Decl::LocalModule(m) => out.push(m.name.clone()),
                ast::Decl::Procedure(p) => {
                    if let Some(body) = &p.body {
                        walk_decls(&body.decls, out);
                    }
                }
                _ => {}
            }
        }
    }
    let mut out = Vec::new();
    walk_decls(&m.decls, &mut out);
    out
}

fn topo_sort(g: &ModuleGraph) -> Result<Vec<ModuleId>, LoadError> {
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Mark {
        New,
        Visiting,
        Done,
    }
    let mut marks = vec![Mark::New; g.modules.len()];
    let mut order = Vec::with_capacity(g.modules.len());
    fn visit(
        g: &ModuleGraph,
        id: ModuleId,
        marks: &mut [Mark],
        order: &mut Vec<ModuleId>,
        stack: &mut Vec<String>,
    ) -> Result<(), LoadError> {
        match marks[id.0] {
            Mark::Done => return Ok(()),
            // Circular imports are legal in ISO Modula-2 (the canonical case is
            // IOChan ↔ IOLink). A module's DEFINITION can be analysed without
            // the other's IMPLEMENTATION, so we break the back-edge and pick an
            // arbitrary init order rather than failing.
            Mark::Visiting => return Ok(()),
            Mark::New => {}
        }
        marks[id.0] = Mark::Visiting;
        stack.push(g.modules[id.0].name.clone());
        for &child in &g.modules[id.0].imports {
            visit(g, child, marks, order, stack)?;
        }
        stack.pop();
        marks[id.0] = Mark::Done;
        order.push(id);
        Ok(())
    }
    let mut stack = Vec::new();
    for i in 0..g.modules.len() {
        visit(g, ModuleId(i), &mut marks, &mut order, &mut stack)?;
    }
    Ok(order)
}
