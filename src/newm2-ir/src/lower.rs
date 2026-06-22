//! CFG lowering — AST + sema result → `IrModule`.
//!
//! Entry point: [`lower_module`].
//!
//! Scope:
//! - All eight control-flow patterns (IF/ELSIF/ELSE, CASE, WHILE, REPEAT,
//!   LOOP/EXIT, FOR, WITH, EXCEPT/FINALLY structural skeleton).
//! - Procedure bodies and the module-level BEGIN…END block.
//! - Expression lowering: literals, variable loads/stores, qualified
//!   procedure calls, binary/unary operators.
//! - GC safe-point insertion at loop back-edges when `mode == Gc`.

use std::collections::{HashMap, HashSet};

use newm2_loader::{ModuleGraph, ModuleId};
use newm2_lexer::Span;
use newm2_parser::ast;
use newm2_sema::scope::{ScopeId, SymbolKind, SymbolProvenance};
use newm2_sema::types::{Builtin, TypeKind};
use newm2_sema::{ClassSymbolId, SelectorBinding, SemaResult};

use crate::builder::FuncBuilder;
use crate::func::{Func, IrParam, LoopFrame};
use crate::inst::{BinOp, BlockId, CastKind, ConstVal, Inst, SetOpKind, Terminator, UnaryOp, ValueId, VecIntrin};
use new_asm;
use crate::module::{Global, IrModule, MemoryMode};

// ---- Entry point ----------------------------------------------------------

/// Lower a single module from AST+sema to IR.
///
/// Returns `None` for intrinsic-only modules (e.g. SYSTEM) that have no
/// on-disk implementation body to lower.
pub fn lower_module(
    graph: &ModuleGraph,
    mid: ModuleId,
    sema: &SemaResult,
    mode: MemoryMode,
) -> Option<IrModule> {
    lower_module_opts(graph, mid, sema, mode, true)
}

/// Like [`lower_module`] but with explicit control over ISO runtime checks
/// (array index, …); `lower_module` defaults them on. The driver passes `false`
/// for `--no-runtime-checks`.
pub fn lower_module_opts(
    graph: &ModuleGraph,
    mid: ModuleId,
    sema: &SemaResult,
    mode: MemoryMode,
    runtime_checks: bool,
) -> Option<IrModule> {
    let node = graph.get(mid);
    if node.is_intrinsic {
        return None;
    }

    // Use IMPLEMENTATION AST when available; fall back to DEFINITION AST
    // (useful for checking DEF-only modules in testing).
    let ast = node.impl_ast.as_ref().or(node.def_ast.as_ref())?;

    let mod_scope = *sema.module_scopes.get(&mid)?;

    let mut ir = IrModule::new(&node.name, mode);
    let mut ctx = ModCtx {
        sema,
        mid,
        graph,
        mode,
        mod_scope,
        runtime_checks,
        extern_ids: HashMap::new(),
        str_ids: HashMap::new(),
        captures: HashMap::new(),
    };

    // Pre-pass: work out which enclosing-scope variables each nested procedure
    // captures, so call sites (lowered before the nested bodies) can pass the
    // hidden by-reference arguments.
    compute_captures(&mut ctx, ast);

    emit_module_statics(sema, &node.name, &ast.decls, mod_scope, &mut ir);

    // Exported variables are declared in the DEFINITION module and not
    // re-declared in the IMPLEMENTATION, so their storage must be emitted from
    // the DEF's decls too. (For a DEF-only module `ast` already *is* the DEF;
    // the pointer guard avoids emitting the same statics twice.)
    if let Some(def) = node.def_ast.as_ref() {
        if !std::ptr::eq(def as *const _, ast as *const _) {
            emit_module_statics(sema, &node.name, &def.decls, mod_scope, &mut ir);
        }
    }

    // Lower top-level procedure declarations (and any nested procedures, and
    // the procedures of any LOCAL MODULEs).
    for decl in &ast.decls {
        lower_proc_tree(&mut ctx, &mut ir, decl, mod_scope);
    }

    // Lower class method bodies (emitted as `{Class}.{Method}` functions that
    // the vtable references and dispatch calls indirectly).
    for decl in &ast.decls {
        lower_class_method_bodies(&mut ctx, &mut ir, decl);
    }

    // Lower the module body. The BEGIN…(EXCEPT)… part is the *initializer*
    // (`<name>.body`, run in dependency order). A module-level FINALLY part is
    // the *finalizer* (`<name>.final`), which ISO runs at program termination
    // in reverse initialization order — NOT immediately after init — so it is
    // outlined into its own function and invoked separately by `run_modules`.
    // LOCAL MODULE initializers run before the enclosing module's BEGIN part.
    let local_inits = lower_local_module_init_fns(&mut ctx, &mut ir, &node.name, &ast.decls, mod_scope);

    let zero_pos = newm2_lexer::SourcePosition::START;
    let empty_body = ast::Block {
        stmts: Vec::new(),
        except: Vec::new(),
        finally: None,
        span: Span { start: zero_pos, end: zero_pos },
    };
    let body_ref = ast.body.as_ref().unwrap_or(&empty_body);
    {
        let body = body_ref;
        let has_final = body.finally.as_ref().is_some_and(|f| !f.is_empty());
        let has_init =
            !body.stmts.is_empty() || !body.except.is_empty() || !local_inits.is_empty();
        if has_init {
            let body_name = format!("{}.body", node.name);
            // The initializer is the body without its FINALLY part.
            let init = ast::Block {
                stmts: body.stmts.clone(),
                except: body.except.clone(),
                finally: None,
                span: body.span,
            };
            if init.except.is_empty() {
                let f = lower_block_as_func_with_prologue(
                    &mut ctx, &mut ir, &body_name, &init, &local_inits,
                );
                ir.funcs.push(f);
            } else {
                // Outline the protected region into `<name>.body$protected` and
                // emit a wrapper that runs it under nm2_run_protected, then
                // dispatches the EXCEPT handler. Module variables are module-
                // level statics, so the protected function needs no shared
                // frame state (the pointer is NIL).
                let protected_name = format!("{body_name}$protected");
                let addr = ctx.addr_ty();
                {
                    let state_param = IrParam { name: "$state".into(), ty: addr, is_var: false };
                    let mut fl = FuncLower::new(
                        &mut ctx, &mut ir, mod_scope, &protected_name, vec![state_param], None,
                    );
                    fl.lower_stmts(&init.stmts);
                    let f = fl.finish();
                    ir.funcs.push(f);
                }
                {
                    let mut fl =
                        FuncLower::new(&mut ctx, &mut ir, mod_scope, &body_name, vec![], None);
                    fl.emit_void_calls(&local_inits);
                    let nil = fl.emit_nil();
                    fl.lower_protected_wrapper(&init, &protected_name, nil, None);
                    let f = fl.finish();
                    ir.funcs.push(f);
                }
            }
        }
        if has_final {
            let final_name = format!("{}.final", node.name);
            let fin = ast::Block {
                stmts: body.finally.clone().unwrap_or_default(),
                except: Vec::new(),
                finally: None,
                span: body.span,
            };
            let f = lower_block_as_func(&mut ctx, &mut ir, &final_name, &fin);
            ir.funcs.push(f);
        }
    }

    // Emit ClassDesc globals for every class whose methods are implemented
    // in this module.  A class is considered "local" if it has at least one
    // non-abstract vtable slot whose defining-class name matches the current
    // module name (or if the class itself is named after the module — the
    // simple heuristic).
    //
    // For cross-module base classes, the ClassDesc will contain empty-string
    // slots for inherited abstract methods and the post-JIT patcher will
    // leave those as NULL (patched when the defining module is loaded).
    // Only classes *declared in this module* get a vtable global, so the same
    // `{Class}.vtable` symbol isn't multiply defined across the per-module LLVM
    // modules that are linked together. Inherited slots from a cross-module base
    // reference `{BaseClass}.{Method}` and are patched post-JIT.
    for decl in &ast.decls {
        let ast::Decl::Class(cd) = decl else {
            continue;
        };
        let Some(cid) = sema.classes.lookup(&cd.name) else {
            continue;
        };
        let class = sema.classes.get(cid);
        // An INTERFACE or a pure ABSTRACT class is never instantiated, so it needs
        // no `{Class}.vtable` global, and emitting one is actively harmful: two
        // modules declaring a same-named interface (e.g. a hand-written
        // IDWriteFactory and the generated Graphics_DirectWrite one) would each
        // emit `IDWriteFactory.vtable` and collide at link. Dispatch through an
        // interface uses the foreign COM object's vtable, never ours.
        //
        // Every CONCRETE native class IS emitted — INCLUDING a method-less
        // (field-only) class: it still gets a `[typeinfo]`-only vtable so its
        // instances can reach RTTI (field 0 -> vtable[-1]); otherwise NEW would
        // store NIL at field 0 and ISMEMBER/GUARD would always answer FALSE.
        if class.is_interface || class.is_abstract {
            continue;
        }
        let vtable_slots: Vec<String> = class
            .vtable
            .iter()
            .map(|slot| {
                if slot.is_abstract {
                    String::new()
                } else {
                    let def_class = sema.classes.get(slot.defining_class);
                    format!("{}.{}", def_class.name, slot.name)
                }
            })
            .collect();

        ir.globals.push(Global::ClassDesc {
            class_name: class.name.clone(),
            vtable_slots,
            has_typeinfo: true,
        });
    }

    // Emit a `{Class}.typeinfo` RTTI descriptor for every native class declared
    // in this module — concrete AND abstract (an abstract base must be a valid
    // ISMEMBER/GUARD target and the parent chain must reach it). COM interfaces
    // get none: they are discriminated by QueryInterface, not RTTI, and carry no
    // M2 typeinfo. This loop is deliberately INDEPENDENT of the all-abstract
    // vtable suppression above, so an abstract base that has no `{Class}.vtable`
    // still gets its `{Class}.typeinfo`.
    for decl in &ast.decls {
        let ast::Decl::Class(cd) = decl else { continue };
        let Some(cid) = sema.classes.lookup(&cd.name) else { continue };
        let class = sema.classes.get(cid);
        if class.is_interface {
            continue;
        }
        // depth = length of the base chain (0 at a root); parent_name = the
        // immediate base's name (its `{base}.typeinfo` is referenced by symbol).
        let mut depth: u64 = 0;
        let mut cur = class.base;
        while let Some(b) = cur {
            depth += 1;
            cur = sema.classes.get(b).base;
        }
        let parent_name = class.base.map(|b| sema.classes.get(b).name.clone());
        ir.globals.push(Global::TypeInfo {
            class_name: class.name.clone(),
            parent_name,
            depth,
        });
    }

    Some(ir)
}

// ---- Module-level context ------------------------------------------------

struct ModCtx<'g, 's> {
    sema: &'s SemaResult,
    mid: ModuleId,
    graph: &'g ModuleGraph,
    mode: MemoryMode,
    mod_scope: newm2_sema::scope::ScopeId,
    /// Emit ISO runtime checks (array index, …). On by default
    /// (`--no-runtime-checks` opt-out).
    runtime_checks: bool,
    /// Maps qualified proc name → index of its `ExternFunc` global.
    extern_ids: HashMap<String, u32>,
    /// Maps string literal content → index of its `StringConst` global.
    str_ids: HashMap<String, u32>,
    /// Maps a nested procedure's qualified name (`{module}.{proc}`) → the
    /// enclosing-scope variables it captures, lambda-lifted into hidden
    /// by-reference (`VAR`) parameters. Empty for non-capturing procs.
    captures: HashMap<String, Vec<CaptureVar>>,
}

/// One enclosing-scope variable captured by a nested procedure, passed by
/// reference as a hidden trailing `VAR` parameter.
#[derive(Clone)]
struct CaptureVar {
    name: String,
    ty: newm2_sema::types::TypeId,
}

struct ResolvedExternSig {
    params: Vec<IrParam>,
    return_ty: Option<newm2_sema::types::TypeId>,
    import_name: Option<String>,
    dll_name: Option<String>,
    is_variadic: bool,
}

/// Companion-param name carrying the runtime HIGH bound of an open-array
/// parameter `n`. Lives in the locals map beside the array pointer; the
/// native ABI passes it right after the pointer, and `HIGH`/`LEN` read it.
fn open_array_high_name(n: &str) -> String {
    format!("{n}$high")
}

/// True when `ty` is an open array (`ARRAY OF T`).
fn is_open_array_ty(sema: &SemaResult, ty: newm2_sema::types::TypeId) -> bool {
    matches!(sema.types.get(ty), TypeKind::OpenArray { .. })
}

impl<'g, 's> ModCtx<'g, 's> {
    /// Name of the module currently being lowered. Proc definitions and
    /// intra-module proc calls are qualified with this so cross-module
    /// qualified calls (`Strings.Length`) resolve to the right symbol and
    /// same-named procs in different modules don't collide at link time.
    fn module_name(&self) -> &str {
        &self.graph.get(self.mid).name
    }

    fn int_ty(&self) -> newm2_sema::types::TypeId {
        self.sema.types.builtin(newm2_sema::types::Builtin::Integer)
    }

    fn addr_ty(&self) -> newm2_sema::types::TypeId {
        self.sema.types.builtin(newm2_sema::types::Builtin::Address)
    }

    /// Get or create an `ExternFunc` global entry; return its index.
    fn get_or_add_extern(
        &mut self,
        ir: &mut IrModule,
        name: &str,
        import_name: Option<String>,
        dll_name: Option<String>,
        params: Option<Vec<IrParam>>,
        return_ty: Option<newm2_sema::types::TypeId>,
        is_variadic: bool,
    ) -> u32 {
        if let Some(&idx) = self.extern_ids.get(name) {
            if let Some(Global::ExternFunc {
                import_name: existing_import_name,
                dll_name: existing_dll_name,
                params: existing_params,
                return_ty: existing_return_ty,
                is_variadic: existing_is_variadic,
                ..
            }) = ir.globals.get_mut(idx as usize)
            {
                if existing_import_name.is_none() {
                    *existing_import_name = import_name;
                }
                if existing_dll_name.is_none() {
                    *existing_dll_name = dll_name;
                }
                if existing_params.is_none() {
                    *existing_params = params;
                }
                if existing_return_ty.is_none() {
                    *existing_return_ty = return_ty;
                }
                *existing_is_variadic = *existing_is_variadic || is_variadic;
            }
            return idx;
        }
        let idx = ir.globals.len() as u32;
        ir.globals.push(Global::ExternFunc {
            name: name.to_string(),
            import_name,
            dll_name,
            params,
            return_ty,
            is_variadic,
        });
        self.extern_ids.insert(name.to_string(), idx);
        idx
    }

    /// Get or create a `StringConst` global entry; return its index.
    fn get_or_add_string(&mut self, ir: &mut IrModule, value: &str) -> u32 {
        if let Some(&idx) = self.str_ids.get(value) {
            return idx;
        }
        let idx = ir.globals.len() as u32;
        let name = format!("str.{}", self.str_ids.len());
        ir.globals.push(Global::StringConst { name, value: value.to_string() });
        self.str_ids.insert(value.to_string(), idx);
        idx
    }
}

// ---- Procedure lowering --------------------------------------------------

// ---- Capturing nested procedures ----------------------------------------

struct ProcInfo<'a> {
    qname: String,
    scope: ScopeId,
    is_nested: bool,
    body: &'a ast::ProcBody,
}

fn short_name(q: &str) -> String {
    q.rsplit_once('.').map(|(_, s)| s.to_string()).unwrap_or_else(|| q.to_string())
}

/// Collect every procedure in `decls` (recursively), tagging each as nested
/// when it is enclosed by another procedure.
fn collect_procs<'a>(
    ctx: &ModCtx<'_, '_>,
    module: &str,
    decls: &'a [ast::Decl],
    parent_scope: ScopeId,
    parent_is_proc: bool,
    out: &mut Vec<ProcInfo<'a>>,
) {
    for decl in decls {
        if let ast::Decl::Procedure(p) = decl
            && let Some(body) = &p.body
        {
            let pscope = ctx
                .sema
                .proc_scopes
                .get(&(ctx.mid, p.name.clone()))
                .copied()
                .unwrap_or(parent_scope);
            out.push(ProcInfo {
                qname: format!("{module}.{}", p.name),
                scope: pscope,
                is_nested: parent_is_proc,
                body,
            });
            collect_procs(ctx, module, &body.decls, pscope, true, out);
        }
    }
}

/// Type of `name` if it is a genuine capture for a nested proc whose own scope
/// is `pscope`: i.e. a variable declared in an *enclosing procedure* scope
/// (not the proc's own scope, not a module/pervasive scope).
fn capture_type_for(
    ctx: &ModCtx<'_, '_>,
    pscope: ScopeId,
    name: &str,
) -> Option<newm2_sema::types::TypeId> {
    use newm2_sema::scope::ScopeKind;
    let mut s = pscope;
    loop {
        let sc = ctx.sema.scopes.get(s);
        if let Some(sym) = sc.get(name) {
            if s == pscope || s == ctx.mod_scope {
                return None;
            }
            if matches!(sc.kind, ScopeKind::Module | ScopeKind::Pervasive) {
                return None;
            }
            if let SymbolKind::Var { ty, .. } = sym.kind {
                return Some(ty);
            }
            return None;
        }
        s = sc.parent?;
    }
}

fn compute_captures(ctx: &mut ModCtx<'_, '_>, ast: &ast::Module) {
    let module = ctx.module_name().to_string();
    let mut procs: Vec<ProcInfo> = Vec::new();
    collect_procs(ctx, &module, &ast.decls, ctx.mod_scope, false, &mut procs);

    // Names referenced directly in each nested proc's own body (over-collected;
    // filtered to real captures below).
    let mut refs: HashMap<String, HashSet<String>> = HashMap::new();
    for p in procs.iter().filter(|p| p.is_nested) {
        let mut set = HashSet::new();
        collect_refs_procbody(p.body, &mut set);
        refs.insert(p.qname.clone(), set);
    }
    // short proc name → qualified name, for resolving transitive calls.
    let short_to_q: HashMap<String, String> = procs
        .iter()
        .filter(|p| p.is_nested)
        .map(|p| (short_name(&p.qname), p.qname.clone()))
        .collect();

    let mut caps: HashMap<String, Vec<CaptureVar>> = HashMap::new();
    loop {
        let mut changed = false;
        for p in procs.iter().filter(|p| p.is_nested) {
            // Candidate names: this proc's own refs, plus the captures of any
            // nested proc it calls (transitive capture).
            let mut cand: HashSet<String> = refs[&p.qname].clone();
            for n in &refs[&p.qname] {
                if let Some(q) = short_to_q.get(n)
                    && let Some(qcaps) = caps.get(q)
                {
                    for cv in qcaps {
                        cand.insert(cv.name.clone());
                    }
                }
            }
            let mut newc: Vec<CaptureVar> = cand
                .iter()
                .filter_map(|n| {
                    capture_type_for(ctx, p.scope, n).map(|ty| CaptureVar { name: n.clone(), ty })
                })
                .collect();
            newc.sort_by(|a, b| a.name.cmp(&b.name));
            let differs = match caps.get(&p.qname) {
                Some(pc) => {
                    pc.len() != newc.len()
                        || pc.iter().zip(&newc).any(|(a, b)| a.name != b.name)
                }
                None => !newc.is_empty(),
            };
            if differs {
                caps.insert(p.qname.clone(), newc);
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    ctx.captures = caps;
}

fn collect_refs_procbody(body: &ast::ProcBody, out: &mut HashSet<String>) {
    for decl in &body.decls {
        match decl {
            ast::Decl::Const(c) => collect_refs_expr(&c.value, out),
            ast::Decl::Var(v) => {
                if let Some(a) = &v.address {
                    collect_refs_expr(a, out);
                }
            }
            _ => {}
        }
    }
    collect_refs_block(&body.body, out);
}

fn collect_refs_block(b: &ast::Block, out: &mut HashSet<String>) {
    collect_refs_stmts(&b.stmts, out);
    for arm in &b.except {
        collect_refs_stmts(&arm.body, out);
    }
    if let Some(f) = &b.finally {
        collect_refs_stmts(f, out);
    }
}

fn collect_refs_stmts(stmts: &[ast::Stmt], out: &mut HashSet<String>) {
    for s in stmts {
        collect_refs_stmt(s, out);
    }
}

fn collect_refs_stmt(s: &ast::Stmt, out: &mut HashSet<String>) {
    match s {
        ast::Stmt::Assign { target, value, .. } => {
            collect_refs_designator(target, out);
            collect_refs_expr(value, out);
        }
        ast::Stmt::Call(e, _) => collect_refs_expr(e, out),
        ast::Stmt::If { arms, else_arm, .. } => {
            for (c, body) in arms {
                collect_refs_expr(c, out);
                collect_refs_stmts(body, out);
            }
            if let Some(e) = else_arm {
                collect_refs_stmts(e, out);
            }
        }
        ast::Stmt::Case { scrutinee, arms, else_arm, .. } => {
            collect_refs_expr(scrutinee, out);
            for a in arms {
                collect_refs_stmts(&a.body, out);
            }
            if let Some(e) = else_arm {
                collect_refs_stmts(e, out);
            }
        }
        ast::Stmt::Guard { selector, arms, else_arm, .. } => {
            collect_refs_expr(selector, out);
            for a in arms {
                collect_refs_stmts(&a.body, out);
            }
            if let Some(e) = else_arm {
                collect_refs_stmts(e, out);
            }
        }
        ast::Stmt::While(c, b, _) => {
            collect_refs_expr(c, out);
            collect_refs_stmts(b, out);
        }
        ast::Stmt::Repeat(b, c, _) => {
            collect_refs_stmts(b, out);
            collect_refs_expr(c, out);
        }
        ast::Stmt::For { start, end, step, body, .. } => {
            collect_refs_expr(start, out);
            collect_refs_expr(end, out);
            if let Some(s) = step {
                collect_refs_expr(s, out);
            }
            collect_refs_stmts(body, out);
        }
        ast::Stmt::Loop(b, _) => collect_refs_stmts(b, out),
        ast::Stmt::With(d, b, _) => {
            collect_refs_designator(d, out);
            collect_refs_stmts(b, out);
        }
        ast::Stmt::Return(Some(e), _) => collect_refs_expr(e, out),
        ast::Stmt::Raise(Some(e), _) => collect_refs_expr(e, out),
        ast::Stmt::Block(b) => collect_refs_block(b, out),
        _ => {}
    }
}

fn collect_refs_expr(e: &ast::Expr, out: &mut HashSet<String>) {
    match e {
        ast::Expr::Designator(d) => collect_refs_designator(d, out),
        ast::Expr::Call(callee, args, _) => {
            collect_refs_expr(callee, out);
            for a in args {
                collect_refs_expr(a, out);
            }
        }
        ast::Expr::Binary(_, l, r, _) => {
            collect_refs_expr(l, out);
            collect_refs_expr(r, out);
        }
        ast::Expr::Unary(_, x, _) => collect_refs_expr(x, out),
        ast::Expr::Set { elements, .. } => {
            for el in elements {
                match el {
                    ast::SetElem::Single(x) => collect_refs_expr(x, out),
                    ast::SetElem::Range(a, b) => {
                        collect_refs_expr(a, out);
                        collect_refs_expr(b, out);
                    }
                }
            }
        }
        _ => {}
    }
}

fn collect_refs_designator(d: &ast::Designator, out: &mut HashSet<String>) {
    if let Some(first) = d.base.segments.first() {
        out.insert(first.clone());
    }
    for sel in &d.selectors {
        if let ast::Selector::Index(ixs, _) = sel {
            for ix in ixs {
                collect_refs_expr(ix, out);
            }
        }
    }
}

/// Lower a procedure declaration and, recursively, any procedures nested in
/// its body. `lookup_scope` is the scope in which to resolve this procedure's
/// own signature (the module scope for top-level procs; the enclosing
/// procedure's scope for nested ones). Nested procedures are emitted as
/// ordinary module-qualified Funcs — calls already resolve to the same
/// `{module}.{proc}` name via provenance. Variables a nested proc reads/writes
/// from an enclosing procedure are lambda-lifted into hidden trailing `VAR`
/// parameters (see [`compute_captures`]).
/// Emit `Global::Static` entries for a module's variables, recursing into LOCAL
/// MODULEs. A local module's variables are flattened into the enclosing
/// module's statics (`{Enclosing}.{var}`), matching `lookup_module_static`.
fn emit_module_statics(
    sema: &SemaResult,
    enclosing_name: &str,
    decls: &[ast::Decl],
    scope: ScopeId,
    ir: &mut IrModule,
) {
    for decl in decls {
        match decl {
            ast::Decl::Var(v) => {
                for name in &v.names {
                    if let Some(sym) = sema.scopes.get(scope).get(name) {
                        if let SymbolKind::Var { ty, .. } = sym.kind {
                            ir.globals.push(Global::Static {
                                name: format!("{enclosing_name}.{name}"),
                                ty,
                                init: None,
                                exported: sym.exported,
                            });
                        }
                    }
                }
            }
            ast::Decl::LocalModule(m) => {
                if let Some(SymbolKind::Module(_, local_scope)) =
                    sema.scopes.get(scope).get(&m.name).map(|s| s.kind.clone())
                {
                    emit_module_statics(sema, enclosing_name, &m.decls, local_scope, ir);
                }
            }
            _ => {}
        }
    }
}

/// Lower each LOCAL MODULE's initialization body as a `{Enclosing}.{Local}$init`
/// function (in the local module's scope) and return their names in
/// declaration order. The enclosing module body calls them before its own
/// `BEGIN` part. Nested local modules initialize before their parent.
fn lower_local_module_init_fns(
    ctx: &mut ModCtx<'_, '_>,
    ir: &mut IrModule,
    enclosing_name: &str,
    decls: &[ast::Decl],
    scope: ScopeId,
) -> Vec<String> {
    let mut names = Vec::new();
    for decl in decls {
        let ast::Decl::LocalModule(m) = decl else {
            continue;
        };
        let Some(SymbolKind::Module(_, local_scope)) =
            ctx.sema.scopes.get(scope).get(&m.name).map(|s| s.kind.clone())
        else {
            continue;
        };
        names.extend(lower_local_module_init_fns(ctx, ir, enclosing_name, &m.decls, local_scope));
        if let Some(body) = &m.body {
            if !body.stmts.is_empty() || !body.except.is_empty() || body.finally.is_some() {
                let init_name = format!("{enclosing_name}.{}$init", m.name);
                let mut fl = FuncLower::new(ctx, ir, local_scope, &init_name, vec![], None);
                fl.lower_block(body);
                let f = fl.finish();
                ir.funcs.push(f);
                names.push(init_name);
            }
        }
    }
    names
}

fn lower_proc_tree(
    ctx: &mut ModCtx<'_, '_>,
    ir: &mut IrModule,
    decl: &ast::Decl,
    lookup_scope: ScopeId,
) {
    // A LOCAL MODULE contributes its procedures (and any nested local modules'
    // procedures) to the enclosing module, lowered in the local module's scope.
    if let ast::Decl::LocalModule(m) = decl {
        if let Some(SymbolKind::Module(_, local_scope)) = ctx
            .sema
            .scopes
            .get(lookup_scope)
            .get(&m.name)
            .map(|s| s.kind.clone())
        {
            for d in &m.decls {
                lower_proc_tree(ctx, ir, d, local_scope);
            }
        }
        return;
    }
    let ast::Decl::Procedure(proc) = decl else {
        return;
    };
    if let Some(f) = lower_decl_proc(ctx, ir, decl, lookup_scope) {
        ir.funcs.push(f);
    }
    // Recurse into nested procedures, resolving them against this proc's scope.
    if let Some(body) = &proc.body {
        let inner_scope = ctx
            .sema
            .proc_scopes
            .get(&(ctx.mid, proc.name.clone()))
            .copied()
            .unwrap_or(lookup_scope);
        for nested in &body.decls {
            lower_proc_tree(ctx, ir, nested, inner_scope);
        }
    }
}

fn lower_decl_proc(
    ctx: &mut ModCtx<'_, '_>,
    ir: &mut IrModule,
    decl: &ast::Decl,
    lookup_scope: ScopeId,
) -> Option<Func> {
    let proc = match decl {
        ast::Decl::Procedure(p) => p,
        _ => return None,
    };

    // ASM procedure — emit as `module asm` blob; no Func needed.
    if let Some(asm_body) = &proc.asm_body {
        ir.asm_procs.push(lower_asm_proc(ctx, proc, asm_body));
        return None;
    }

    let proc_body = proc.body.as_ref()?;

    let (mut params, ret_ty) = match ctx.sema.scopes.lookup(lookup_scope, &proc.name) {
        Some(sym) => match &sym.kind {
            SymbolKind::Proc(sig) => {
                // Native ABI: each open-array param gets an i64 HIGH companion
                // appended (so HIGH/LEN work in the body and callers match).
                let card_ty = ctx.sema.types.builtin(newm2_sema::types::Builtin::Cardinal);
                let mut params = Vec::with_capacity(sig.params.len());
                for param in &sig.params {
                    let name = param.name.clone().unwrap_or_default();
                    let open = is_open_array_ty(ctx.sema, param.ty);
                    params.push(IrParam {
                        name: name.clone(),
                        ty: param.ty,
                        is_var: param.mode == newm2_sema::types::ParamMode::Var,
                    });
                    if open {
                        params.push(IrParam {
                            name: open_array_high_name(&name),
                            ty: card_ty,
                            is_var: false,
                        });
                    }
                }
                (params, sig.return_ty)
            }
            _ => {
                let params = proc
                    .params
                    .iter()
                    .flat_map(|param| {
                        param.names.iter().map(|n| IrParam {
                            name: n.clone(),
                            ty: ctx.int_ty(),
                            is_var: param.mode == ast::ParamMode::Var,
                        })
                    })
                    .collect();
                (params, None)
            }
        },
        None => {
            let params = proc
                .params
                .iter()
                .flat_map(|param| {
                    param.names.iter().map(|n| IrParam {
                        name: n.clone(),
                        ty: ctx.int_ty(),
                        is_var: param.mode == ast::ParamMode::Var,
                    })
                })
                .collect();
            (params, None)
        }
    };

    let scope = ctx
        .sema
        .proc_scopes
        .get(&(ctx.mid, proc.name.clone()))
        .copied()
        .unwrap_or(ctx.mod_scope);

    // Qualify the definition by its module (`Strings.Length`) so that
    // cross-module qualified calls bind to it and same-named procs across
    // modules don't collide once the LLVM modules are linked together.
    let qualified_name = format!("{}.{}", ctx.module_name(), proc.name);

    // Append hidden by-reference parameters for any enclosing-scope variables
    // this (nested) procedure captures. Call sites pass their addresses. An
    // open-array capture also carries its HIGH companion, like a real param.
    if let Some(caps) = ctx.captures.get(&qualified_name) {
        let card_ty = ctx.sema.types.builtin(newm2_sema::types::Builtin::Cardinal);
        for cap in caps {
            params.push(IrParam { name: cap.name.clone(), ty: cap.ty, is_var: true });
            if is_open_array_ty(ctx.sema, cap.ty) {
                params.push(IrParam {
                    name: open_array_high_name(&cap.name),
                    ty: card_ty,
                    is_var: false,
                });
            }
        }
    }

    // A procedure body with EXCEPT/FINALLY is outlined like a module body, but
    // its params/locals must be shared with the outlined protected function
    // through a heap exception frame (module bodies don't need this — their
    // variables are module-level statics).
    if !proc_body.body.except.is_empty() || proc_body.body.finally.is_some() {
        return Some(lower_protected_proc(
            ctx,
            ir,
            scope,
            &qualified_name,
            params,
            ret_ty,
            proc_body,
            None,
        ));
    }

    let mut fl = FuncLower::new(ctx, ir, scope, &qualified_name, params, ret_ty);

    // Pre-alloca local variable declarations in the procedure body.
    for local_decl in &proc_body.decls {
        fl.pre_alloca_decl(local_decl);
    }

    fl.lower_block(&proc_body.body);
    Some(fl.finish())
}

/// Lower the method bodies of a class declaration. Each non-abstract method is
/// emitted as a function `{ClassName}.{MethodName}` (matching the vtable slot
/// naming) whose first parameter is the hidden `SELF` receiver.
fn lower_class_method_bodies(ctx: &mut ModCtx<'_, '_>, ir: &mut IrModule, decl: &ast::Decl) {
    let ast::Decl::Class(cd) = decl else {
        return;
    };
    let Some(cid) = ctx.sema.classes.lookup(&cd.name) else {
        return;
    };
    for member in &cd.members {
        if let ast::ClassMember::Method(m) = member {
            if m.body.is_some() {
                if let Some(f) = lower_method(ctx, ir, cid, m) {
                    ir.funcs.push(f);
                }
            }
        }
    }
}

/// Lower one class method. `SELF` is stored in a class-typed local (so
/// `SELF.field` works like any class reference) and pushed onto the WITH stack
/// (so bare field names resolve to `SELF`'s fields).
fn lower_method(
    ctx: &mut ModCtx<'_, '_>,
    ir: &mut IrModule,
    cid: newm2_sema::ClassSymbolId,
    m: &ast::MethodDecl,
) -> Option<Func> {
    let body = m.body.as_ref()?;
    let class_name = ctx.sema.classes.get(cid).name.clone();
    let class_ty = ctx.sema.classes.get(cid).type_id;
    let object_record = ctx.sema.classes.get(cid).object_record;
    let method_name = format!("{class_name}.{}", m.name);
    let scope = ctx
        .sema
        .proc_scopes
        .get(&(ctx.mid, method_name.clone()))
        .copied()
        .unwrap_or(ctx.mod_scope);

    let sig = ctx
        .sema
        .classes
        .get(cid)
        .own_methods
        .iter()
        .find(|mm| mm.name == m.name)
        .map(|mm| mm.sig.clone());
    let ret_ty = sig.as_ref().and_then(|s| s.return_ty);
    let card_ty = ctx.sema.types.builtin(Builtin::Cardinal);
    let mut params = vec![IrParam { name: "SELF".into(), ty: class_ty, is_var: false }];
    if let Some(s) = &sig {
        for p in &s.params {
            let name = p.name.clone().unwrap_or_default();
            let open = is_open_array_ty(ctx.sema, p.ty);
            params.push(IrParam {
                name: name.clone(),
                ty: p.ty,
                is_var: p.mode == newm2_sema::types::ParamMode::Var,
            });
            if open {
                params.push(IrParam {
                    name: open_array_high_name(&name),
                    ty: card_ty,
                    is_var: false,
                });
            }
        }
    }

    // A method body with EXCEPT/FINALLY is outlined like a protected procedure,
    // threading SELF + params through the heap exception frame. `object_record`
    // re-establishes the implicit WITH SELF in both wrapper and protected fn.
    if !body.body.except.is_empty() || body.body.finally.is_some() {
        return Some(lower_protected_proc(
            ctx,
            ir,
            scope,
            &method_name,
            params,
            ret_ty,
            body,
            object_record,
        ));
    }

    let mut fl = FuncLower::new(ctx, ir, scope, &method_name, params, ret_ty);
    for local_decl in &body.decls {
        fl.pre_alloca_decl(local_decl);
    }
    // Implicit WITH SELF: bare field names resolve against the receiver. Load
    // the object pointer from the SELF slot once and push it.
    if let Some(or) = object_record {
        if let Some(binding) = fl.locals.get("SELF").copied() {
            let self_slot = fl.local_ptr(binding);
            let obj = fl.fresh();
            fl.push(Inst::Load { dst: obj, ptr: self_slot });
            // Annotate the object pointer with the object-record layout so a
            // bare-field GEP indexes the struct, not the i64 fallback.
            let obj_typed = fl.fresh();
            fl.push(Inst::TypedPtr { dst: obj_typed, src: obj, ty: or });
            fl.with_stack.push((obj_typed, or));
        }
    }
    fl.lower_block(&body.body);
    Some(fl.finish())
}

/// Lower a procedure whose body has an EXCEPT/FINALLY part. The protected
/// statements are outlined into `<name>$protected`, which the wrapper runs
/// under `nm2_run_protected`. Because the protected function is a separate
/// frame, it reaches the procedure's params/locals through a heap "exception
/// frame" of pointers the wrapper fills with the addresses of its allocas; the
/// protected function reconstructs typed bindings from it. The handler and
/// FINALLY run in the wrapper and so see the wrapper's allocas directly (the
/// same storage the protected function mutated through the frame).
fn lower_protected_proc(
    ctx: &mut ModCtx<'_, '_>,
    ir: &mut IrModule,
    scope: ScopeId,
    qualified_name: &str,
    params: Vec<IrParam>,
    ret_ty: Option<newm2_sema::types::TypeId>,
    proc_body: &ast::ProcBody,
    // For a class method routed through here: the object-record layout for the
    // receiver. When `Some`, both the wrapper and the protected function set up
    // the implicit `WITH SELF` so bare field names resolve against the receiver
    // (matching the non-protected method path in `lower_method`).
    object_record: Option<newm2_sema::types::TypeId>,
) -> Func {
    let protected_name = format!("{qualified_name}$protected");
    let addr_ty = ctx.addr_ty();
    let card_ty = ctx.sema.types.builtin(Builtin::Cardinal);

    // Each shared slot: (name, type). The frame holds the *effective address*
    // of each local — `local_ptr` of its binding, i.e. the address a read/write
    // ultimately targets: an alloca for a value local, the target object for a
    // VAR param, the data pointer for an open array. The protected function can
    // therefore treat every shared slot as a Direct pointer to `type`. The
    // index into this list is the frame slot index.
    let shared: Vec<(String, newm2_sema::types::TypeId)>;
    let result_slot_index: Option<usize>;

    let wrapper = {
        let mut w = FuncLower::new(ctx, ir, scope, qualified_name, params, ret_ty);
        for local_decl in &proc_body.decls {
            w.pre_alloca_decl(local_decl);
        }

        // Deterministic order so the wrapper and protected function agree on
        // frame indices.
        let mut names: Vec<String> = w.locals.keys().cloned().collect();
        names.sort();
        let mut snap: Vec<(String, newm2_sema::types::TypeId)> = Vec::new();
        let mut addrs: Vec<ValueId> = Vec::new();
        for name in &names {
            let b = w.locals.get(name).copied().expect("snapshotted local");
            let addr = w.local_ptr(b);
            addrs.push(addr);
            snap.push((name.clone(), b.ty));
        }

        // Result slot for functions: an extra wrapper alloca shared through the
        // frame; the protected body RETURNs into it, the wrapper returns it.
        let wrapper_result = ret_ty.map(|rty| {
            let slot = w.fresh();
            w.push(Inst::Alloca { dst: slot, ty: rty });
            addrs.push(slot);
            snap.push(("$result".to_string(), rty));
            slot
        });
        result_slot_index = wrapper_result.map(|_| snap.len() - 1);

        let n = snap.len();
        // Allocate the frame once (before the RETRY loop) and publish each
        // local's effective address into it.
        let size = w.fresh();
        w.push(Inst::Const { dst: size, val: ConstVal::Int((n as i128) * 8) });
        let frame = w
            .call_runtime(
                "nm2_alloc",
                vec![IrParam { name: "size".into(), ty: card_ty, is_var: false }],
                Some(addr_ty),
                vec![size],
            )
            .expect("nm2_alloc returns a pointer");
        for (idx, addr) in addrs.iter().enumerate() {
            let i = w.fresh();
            w.push(Inst::Const { dst: i, val: ConstVal::Int(idx as i128) });
            let slot = w.fresh();
            w.push(Inst::IndexPtr { dst: slot, base: frame, index: i, elem_ty: addr_ty });
            w.push(Inst::Store { ptr: slot, val: *addr });
        }

        // Implicit WITH SELF for the handler / FINALLY part (which run in the
        // wrapper frame). Bare field names there resolve against the receiver.
        if let Some(or) = object_record {
            if let Some(binding) = w.locals.get("SELF").copied() {
                let self_slot = w.local_ptr(binding);
                let obj = w.fresh();
                w.push(Inst::Load { dst: obj, ptr: self_slot });
                let obj_typed = w.fresh();
                w.push(Inst::TypedPtr { dst: obj_typed, src: obj, ty: or });
                w.with_stack.push((obj_typed, or));
            }
        }

        w.frame_to_free = Some(frame);
        w.lower_protected_wrapper(&proc_body.body, &protected_name, frame, wrapper_result);
        shared = snap;
        w.finish()
    };
    ir.funcs.push(wrapper);

    // The protected function: reconstruct each shared local from the frame,
    // then lower the protected statements.
    let mut p = FuncLower::new(
        ctx,
        ir,
        scope,
        &protected_name,
        vec![IrParam { name: "$state".into(), ty: addr_ty, is_var: false }],
        None,
    );
    let frame = {
        let b = p.locals.get("$state").copied().expect("state param");
        let ptr = p.local_ptr(b);
        let dst = p.fresh();
        p.push(Inst::Load { dst, ptr });
        dst
    };
    let mut result_storage: Option<ValueId> = None;
    for (idx, (name, ty)) in shared.iter().enumerate() {
        let i = p.fresh();
        p.push(Inst::Const { dst: i, val: ConstVal::Int(idx as i128) });
        let slot = p.fresh();
        p.push(Inst::IndexPtr { dst: slot, base: frame, index: i, elem_ty: addr_ty });
        let raw = p.fresh();
        p.push(Inst::Load { dst: raw, ptr: slot });
        // The frame holds the effective address, so every shared local is a
        // Direct pointer to its value type.
        let typed = p.fresh();
        p.push(Inst::TypedPtr { dst: typed, src: raw, ty: *ty });
        p.locals.insert(name.clone(), Binding { storage: typed, ty: *ty, kind: BindingKind::Direct });
        if Some(idx) == result_slot_index {
            result_storage = Some(typed);
        }
    }
    p.result_slot = result_storage;
    // Implicit WITH SELF for the protected statements: reconstruct the receiver
    // pointer from the (already reconstructed) SELF binding and push it.
    if let Some(or) = object_record {
        if let Some(binding) = p.locals.get("SELF").copied() {
            let self_slot = p.local_ptr(binding);
            let obj = p.fresh();
            p.push(Inst::Load { dst: obj, ptr: self_slot });
            let obj_typed = p.fresh();
            p.push(Inst::TypedPtr { dst: obj_typed, src: obj, ty: or });
            p.with_stack.push((obj_typed, or));
        }
    }
    p.lower_stmts(&proc_body.body.stmts);
    p.finish()
}

fn lower_asm_proc(ctx: &ModCtx<'_, '_>, proc: &ast::ProcDecl, body: &str) -> new_asm::AsmProc {
    // Map Modula-2 parameter types to AsmType via sema when available.
    let mut params: Vec<new_asm::AsmParam> = Vec::new();
    if let Some(sym) = ctx.sema.scopes.lookup(ctx.mod_scope, &proc.name) {
        if let SymbolKind::Proc(sig) = &sym.kind {
            for param in &sig.params {
                let ty = asm_type_from_type_id(ctx, param.ty);
                params.push(new_asm::AsmParam {
                    name: param.name.clone().unwrap_or_default(),
                    ty,
                });
            }
        }
    }
    if params.is_empty() {
        // Fallback: derive names from AST, treat everything as Word.
        for ast_param in &proc.params {
            for name in &ast_param.names {
                params.push(new_asm::AsmParam { name: name.clone(), ty: new_asm::AsmType::Word });
            }
        }
    }
    let return_type = if proc.return_ty.is_some() {
        new_asm::AsmRetType::Word
    } else {
        new_asm::AsmRetType::Void
    };
    // Emit under the qualified Module.Proc symbol so the `.globl` label + the
    // `declare` match the call site (defined M2 procs use qualified LLVM symbols).
    let qname = format!("{}.{}", ctx.module_name(), proc.name);
    new_asm::AsmProc { name: qname, params, return_type, body: body.to_string() }
}

fn asm_type_from_type_id(ctx: &ModCtx<'_, '_>, ty: newm2_sema::types::TypeId) -> new_asm::AsmType {
    use newm2_sema::types::Builtin;
    match ctx.sema.types.get(ty) {
        TypeKind::Builtin(
            Builtin::Real | Builtin::LongReal | Builtin::Real32 | Builtin::Real16,
        ) => new_asm::AsmType::Float,
        _ => new_asm::AsmType::Word,
    }
}

fn lower_block_as_func(
    ctx: &mut ModCtx<'_, '_>,
    ir: &mut IrModule,
    name: &str,
    block: &ast::Block,
) -> Func {
    lower_block_as_func_with_prologue(ctx, ir, name, block, &[])
}

/// Like [`lower_block_as_func`], but first calls each named (void, no-arg)
/// function — used to run LOCAL MODULE initializers before a module's `BEGIN`.
fn lower_block_as_func_with_prologue(
    ctx: &mut ModCtx<'_, '_>,
    ir: &mut IrModule,
    name: &str,
    block: &ast::Block,
    prologue_calls: &[String],
) -> Func {
    let mut fl = FuncLower::new(ctx, ir, ctx.mod_scope, name, vec![], None);
    fl.emit_void_calls(prologue_calls);
    fl.lower_block(block);
    fl.finish()
}

#[derive(Debug, Clone, Copy)]
enum BindingKind {
    Direct,
    Indirect,
}

#[derive(Debug, Clone, Copy)]
struct Binding {
    storage: ValueId,
    ty: newm2_sema::types::TypeId,
    kind: BindingKind,
}

// ---- Per-function lowering state -----------------------------------------

struct FuncLower<'c, 'g, 's> {
    ctx: &'c mut ModCtx<'g, 's>,
    ir: &'c mut IrModule,
    builder: FuncBuilder,
    scope: ScopeId,
    /// Maps variable name → lowering storage binding.
    locals: HashMap<String, Binding>,
    /// WITH-stack: each frame is `(base_ptr, record_type_id)`.
    /// Records the designator type of each active WITH so field accesses
    /// inside the WITH body resolve against it.
    with_stack: Vec<(ValueId, newm2_sema::types::TypeId)>,
    /// Block to jump to for a `RETRY` statement (set while lowering an EXCEPT
    /// handler; re-runs the protected region).
    retry_target: Option<crate::inst::BlockId>,
    /// When set (the outlined protected body of a *function* with EXCEPT), a
    /// `RETURN expr` stores into this slot and returns void; the wrapper reads
    /// it back after `nm2_run_protected` completes normally.
    result_slot: Option<ValueId>,
    /// Heap exception frame to free on every exit path of a protected
    /// procedure wrapper. Only ever set on the wrapper — never the outlined
    /// protected body, which RETRY re-runs and so must not free it.
    frame_to_free: Option<ValueId>,
}

impl<'c, 'g, 's> FuncLower<'c, 'g, 's> {
    fn new(
        ctx: &'c mut ModCtx<'g, 's>,
        ir: &'c mut IrModule,
        scope: ScopeId,
        name: &str,
        params: Vec<IrParam>,
        return_ty: Option<newm2_sema::types::TypeId>,
    ) -> Self {
        let mode = ctx.mode;
        // Collect param names before moving into the builder.
        let param_info: Vec<(String, newm2_sema::types::TypeId, bool)> =
            params.iter().map(|p| (p.name.clone(), p.ty, p.is_var)).collect();

        let builder = FuncBuilder::new(name, params, return_ty, mode);
        let mut fl = Self {
            ctx,
            ir,
            builder,
            scope,
            locals: HashMap::new(),
            with_stack: Vec::new(),
            retry_target: None,
            result_slot: None,
            frame_to_free: None,
        };

        // Pre-alloca one stack slot per parameter so that body code can
        // always read/write params via Load/Store. An open-array param's
        // slot holds a *pointer to the array data* (the caller passes that
        // pointer), so it is Indirect just like a VAR param — indexing /
        // HIGH load the slot first to get the data base.
        for (pname, ty, is_var) in param_info {
            let indirect = is_var || is_open_array_ty(fl.ctx.sema, ty);
            let ptr = fl.builder.fresh_reg();
            let slot_ty = if indirect { fl.ctx.addr_ty() } else { ty };
            fl.builder.push(Inst::Alloca { dst: ptr, ty: slot_ty });
            fl.locals.insert(
                pname,
                Binding {
                    storage: ptr,
                    ty,
                    kind: if indirect { BindingKind::Indirect } else { BindingKind::Direct },
                },
            );
        }

        fl
    }

    // ---- Helpers ---------------------------------------------------------

    fn fresh(&mut self) -> ValueId {
        self.builder.fresh_reg()
    }

    fn push(&mut self, inst: Inst) {
        self.builder.push(inst);
    }

    fn terminate(&mut self, term: Terminator) {
        self.builder.terminate(term);
    }

    fn mode(&self) -> MemoryMode {
        self.ctx.mode
    }

    fn scope_lookup(&self, name: &str) -> Option<&newm2_sema::scope::Symbol> {
        self.ctx.sema.scopes.lookup(self.scope, name)
    }

    fn module_static_name(&self, module_name: &str, name: &str) -> String {
        format!("{module_name}.{name}")
    }

    fn emit_global_ref(&mut self, name: String, ty: newm2_sema::types::TypeId) -> ValueId {
        let dst = self.fresh();
        self.push(Inst::Const { dst, val: ConstVal::GlobalRef { name, ty } });
        dst
    }

    /// Emit a no-arg void call to each named function (LOCAL MODULE initializers
    /// run before the enclosing module's BEGIN part).
    fn emit_void_calls(&mut self, names: &[String]) {
        for name in names {
            let callee = self.fresh();
            self.push(Inst::Const { dst: callee, val: ConstVal::FuncRef(name.clone()) });
            self.push(Inst::Call { dst: None, callee, args: vec![] });
        }
    }

    fn lookup_module_static(&mut self, name: &ast::QualName) -> Option<ValueId> {
        match name.segments.as_slice() {
            [ident] => {
                if self.locals.contains_key(ident) {
                    return None;
                }
                // Walk the scope chain: a VAR declared in a Module or LOCAL
                // MODULE scope is a persistent static (emitted under the
                // enclosing module's name); a VAR in a Procedure/Block scope is
                // a genuine local (an alloca, handled elsewhere). This lets a
                // local module's variable resolve to its static from inside the
                // local module's procedures.
                use newm2_sema::scope::ScopeKind;
                let mut sid = Some(self.scope);
                while let Some(s) = sid {
                    let scope_ref = self.ctx.sema.scopes.get(s);
                    if let Some(sym) = scope_ref.get(ident) {
                        let is_static_scope =
                            matches!(scope_ref.kind, ScopeKind::Module | ScopeKind::LocalModule);
                        let ty = match sym.kind {
                            SymbolKind::Var { ty, .. } if is_static_scope => ty,
                            _ => return None,
                        };
                        // An imported variable's storage lives in its *defining*
                        // module; a locally-declared one under the current
                        // module. Qualify the static name accordingly.
                        let (module, member) = match &sym.provenance {
                            SymbolProvenance::Imported {
                                from_module_name,
                                original_module_name,
                                original_name,
                                ..
                            } => (
                                original_module_name
                                    .clone()
                                    .unwrap_or_else(|| from_module_name.clone()),
                                original_name.clone(),
                            ),
                            _ => (self.ir.name.clone(), ident.clone()),
                        };
                        return Some(
                            self.emit_global_ref(self.module_static_name(&module, &member), ty),
                        );
                    }
                    sid = scope_ref.parent;
                }
                None
            }
            [module_name, member] => match self.ctx.sema.resolved_name(self.ctx.mid, name.span)? {
                SymbolKind::Var { ty, .. } => Some(
                    self.emit_global_ref(self.module_static_name(module_name, member), *ty),
                ),
                _ => None,
            },
            _ => None,
        }
    }

    fn annotated_name_type(&self, name: &ast::QualName) -> Option<newm2_sema::TypeId> {
        match self.ctx.sema.resolved_name(self.ctx.mid, name.span)? {
            SymbolKind::Var { ty, .. }
            | SymbolKind::Const { ty, .. }
            | SymbolKind::Type(ty)
            | SymbolKind::EnumMember { ty, .. } => Some(*ty),
            SymbolKind::Proc(sig) => sig.return_ty,
            _ => None,
        }
    }

    fn annotated_proc_signature(&self, name: &ast::QualName) -> Option<ResolvedExternSig> {
        let SymbolKind::Proc(sig) = self.ctx.sema.resolved_name(self.ctx.mid, name.span)? else {
            return None;
        };

        let params = sig
            .params
            .iter()
            .map(|param| IrParam {
                name: param.name.clone().unwrap_or_default(),
                ty: param.ty,
                is_var: param.mode == newm2_sema::types::ParamMode::Var,
            })
            .collect();
        Some(ResolvedExternSig {
            params,
            return_ty: sig.return_ty,
            import_name: sig.external_linkage.as_ref().map(|linkage| linkage.link_name.clone()),
            dll_name: sig.external_linkage.as_ref().and_then(|linkage| linkage.dll_name.clone()),
            is_variadic: sig.attrs.contains(&newm2_sema::scope::ProcAttrKind::Varargs),
        })
    }

    fn local_ptr(&mut self, binding: Binding) -> ValueId {
        match binding.kind {
            BindingKind::Direct => binding.storage,
            BindingKind::Indirect => {
                // The slot holds a reference (VAR param) or a data base (open
                // array). Load it to get the address we actually work through.
                let dst = self.fresh();
                self.push(Inst::Load { dst, ptr: binding.storage });
                // For a VAR param, annotate the reference's pointee type so a
                // following Load/Store/FieldPtr uses the parameter's real LLVM
                // type rather than codegen's conservative i64 fallback (needed
                // for pointer/CHAR/REAL/record VAR params). Open-array data
                // bases stay untyped — indexing supplies the element type.
                if is_open_array_ty(self.ctx.sema, binding.ty) {
                    dst
                } else {
                    let typed = self.fresh();
                    self.push(Inst::TypedPtr { dst: typed, src: dst, ty: binding.ty });
                    typed
                }
            }
        }
    }

    /// Emit a placeholder NIL constant (used for unresolvable expressions).
    fn emit_nil(&mut self) -> ValueId {
        let r = self.fresh();
        self.push(Inst::Const { dst: r, val: ConstVal::Nil });
        r
    }

    /// Return the sema `TypeId` for the variable named by designator `d`
    /// (base name only, no selectors).  Used to type NEW(p) allocations.
    fn sema_var_type(&self, d: &ast::Designator) -> Option<newm2_sema::TypeId> {
        if let Some(ty) = self.ctx.sema.designator_type(self.ctx.mid, d.span) {
            return Some(ty);
        }
        if !d.selectors.is_empty() { return None; }
        if let [name] = d.base.segments.as_slice() {
            if let Some(binding) = self.locals.get(name) {
                return Some(binding.ty);
            }
            let sym = self.scope_lookup(name)?;
            if let SymbolKind::Var { ty, .. } = sym.kind { return Some(ty); }
        }
        None
    }

    fn resolve_name_type(&self, name: &ast::QualName) -> Option<newm2_sema::TypeId> {
        if let Some(ty) = self.annotated_name_type(name) {
            return Some(ty);
        }
        match name.segments.as_slice() {
            [ident] => {
                if let Some(binding) = self.locals.get(ident) {
                    return Some(binding.ty);
                }
                let sym = self.scope_lookup(ident)?;
                match &sym.kind {
                    SymbolKind::Var { ty, .. } => Some(*ty),
                    SymbolKind::Const { ty, .. } => Some(*ty),
                    SymbolKind::Type(ty) => Some(*ty),
                    SymbolKind::EnumMember { ty, .. } => Some(*ty),
                    SymbolKind::Proc(sig) => sig.return_ty,
                    _ => None,
                }
            }
            _ => None,
        }
    }

    /// Find an existing `ARRAY remaining OF base` type in the arena, matching by
    /// structure. Used for partial multi-dimensional indexing, where sema has
    /// already allocated the lower-rank sub-array type but lowering (holding the
    /// arena by shared reference) cannot allocate a fresh one.
    fn find_array_type(
        &self,
        remaining: &[newm2_sema::TypeId],
        base: newm2_sema::TypeId,
    ) -> Option<newm2_sema::TypeId> {
        (0..self.ctx.sema.types.len() as u32)
            .map(newm2_sema::TypeId)
            .find(|&id| {
                matches!(
                    self.ctx.sema.types.get(id),
                    TypeKind::Array { indices, base: b }
                        if indices.as_slice() == remaining && *b == base
                )
            })
    }

    fn selector_result_type(
        &self,
        base_ty: newm2_sema::TypeId,
        sel: &ast::Selector,
    ) -> Option<newm2_sema::TypeId> {
        match sel {
            ast::Selector::Deref(_) => match self.ctx.sema.types.get(base_ty) {
                TypeKind::Pointer { base } => Some(*base),
                _ => None,
            },
            ast::Selector::Field(field_name, span) => self
                .ctx
                .sema
                .selector_binding(self.ctx.mid, *span)
                .map(|binding| match binding {
                    SelectorBinding::Field { ty, .. } => ty,
                    SelectorBinding::Method { ty, .. } => ty,
                })
                .or_else(|| match self.ctx.sema.types.get(base_ty) {
                    TypeKind::Record(layout) => layout
                        .fields
                        .iter()
                        .find(|slot| slot.name == *field_name)
                        .map(|slot| slot.ty),
                    _ => None,
                }),
            ast::Selector::Index(indices, _) => match self.ctx.sema.types.get(base_ty) {
                TypeKind::Array { indices: dims, base } => {
                    let take = indices.len().min(dims.len());
                    if take < dims.len() {
                        // Partial indexing yields a lower-rank sub-array of the
                        // remaining dimensions; sema allocated that array type, so
                        // find it by structure (lowering cannot allocate types).
                        let remaining = dims[take..].to_vec();
                        let b = *base;
                        self.find_array_type(&remaining, b)
                    } else {
                        Some(*base)
                    }
                }
                TypeKind::OpenArray { base } => Some(*base),
                _ => None,
            },
            ast::Selector::TypeGuard(_, _) => Some(base_ty),
        }
    }

    fn resolve_field_index(
        &self,
        base_ty: newm2_sema::TypeId,
        field_name: &str,
    ) -> Option<u32> {
        match self.ctx.sema.types.get(base_ty) {
            TypeKind::Pointer { base } => self.resolve_field_index(*base, field_name),
            TypeKind::Record(layout) => layout
                .flatten_fields()
                .iter()
                .position(|(n, _)| n == field_name)
                .map(|idx| idx as u32),
            _ => None,
        }
    }

    /// Pre-alloca a declaration that introduces local variables.
    fn pre_alloca_decl(&mut self, decl: &ast::Decl) {
        if let ast::Decl::Var(v) = decl {
            for name in &v.names {
                if !self.locals.contains_key(name) {
                    let ty = match &v.ty {
                        ast::TypeExpr::Named(qname) => self
                            .resolve_name_type(qname)
                            .or_else(|| {
                                self.ctx
                                    .sema
                                    .scopes
                                    .lookup(self.scope, name)
                                    .and_then(|sym| match sym.kind {
                                        SymbolKind::Var { ty, .. } => Some(ty),
                                        _ => None,
                                    })
                            })
                            .unwrap_or_else(|| self.ctx.int_ty()),
                        _ => self
                            .ctx
                            .sema
                            .scopes
                            .lookup(self.scope, name)
                            .and_then(|sym| match sym.kind {
                                SymbolKind::Var { ty, .. } => Some(ty),
                                _ => None,
                            })
                            .unwrap_or_else(|| self.ctx.int_ty()),
                    };
                    let ptr = self.fresh();
                    self.push(Inst::Alloca { dst: ptr, ty });
                    self.locals.insert(
                        name.clone(),
                        Binding { storage: ptr, ty, kind: BindingKind::Direct },
                    );
                }
            }
        }
        // Nested LOCAL MODULEs and nested PROCs are ignored here.
    }

    // ---- Block / statement lowering --------------------------------------

    fn lower_block(&mut self, block: &ast::Block) {
        self.lower_stmts(&block.stmts);
        // EXCEPT/FINALLY structural skeleton.
        if let Some(fin) = &block.finally {
            if !self.builder.is_terminated() {
                self.lower_stmts(fin);
            }
        }
    }

    /// Declare (idempotently) and call a runtime helper by its raw symbol name
    /// with an explicit signature. Returns the result value when `ret_ty` is set.
    fn call_runtime(
        &mut self,
        name: &str,
        params: Vec<IrParam>,
        ret_ty: Option<newm2_sema::types::TypeId>,
        args: Vec<ValueId>,
    ) -> Option<ValueId> {
        self.ctx.get_or_add_extern(self.ir, name, None, None, Some(params), ret_ty, false);
        let callee = self.fresh();
        self.push(Inst::Const { dst: callee, val: ConstVal::FuncRef(name.to_string()) });
        let dst = ret_ty.map(|_| self.fresh());
        self.push(Inst::Call { dst, callee, args });
        dst
    }

    /// Lower the wrapper around a protected region. `protected_name` is the
    /// outlined function holding the protected statements; this wrapper runs it
    /// under `nm2_run_protected`, dispatches the EXCEPT handler / FINALLY part,
    /// and re-raises an unhandled exception. `state` is the opaque pointer
    /// passed to the protected function (NIL for module bodies whose variables
    /// are module-level statics).
    /// Free this wrapper's heap exception frame, if it has one. No-op for
    /// module-body wrappers (no frame) and outlined protected bodies.
    fn free_exception_frame(&mut self) {
        if let Some(frame) = self.frame_to_free {
            let addr_ty = self.ctx.addr_ty();
            self.call_runtime(
                "nm2_free",
                vec![IrParam { name: "p".into(), ty: addr_ty, is_var: false }],
                None,
                vec![frame],
            );
        }
    }

    /// Emit a return from a protected wrapper: free the exception frame, then
    /// load the function result slot when present (the protected body / handler
    /// stored into it), else void.
    fn emit_protected_return(&mut self, result_slot: Option<ValueId>) {
        self.free_exception_frame();
        match result_slot {
            Some(slot) => {
                let v = self.fresh();
                self.push(Inst::Load { dst: v, ptr: slot });
                self.terminate(Terminator::Return(Some(v)));
            }
            None => self.terminate(Terminator::Return(None)),
        }
    }

    fn lower_protected_wrapper(
        &mut self,
        block: &ast::Block,
        protected_name: &str,
        state: ValueId,
        result_slot: Option<ValueId>,
    ) {
        let addr_ty = self.ctx.addr_ty();
        let card_ty = self.ctx.sema.types.builtin(Builtin::Cardinal);
        let run_params = || {
            vec![
                IrParam { name: "body".into(), ty: addr_ty, is_var: false },
                IrParam { name: "state".into(), ty: addr_ty, is_var: false },
            ]
        };

        // RETRY loops back here to re-run the protected region.
        let header = self.builder.new_block("protect_run");
        self.terminate(Terminator::Goto(header));
        self.builder.switch_to(header);

        let protected_ref = self.fresh();
        self.push(Inst::Const {
            dst: protected_ref,
            val: ConstVal::FuncRef(protected_name.to_string()),
        });
        let raised = self
            .call_runtime("nm2_run_protected", run_params(), Some(card_ty), vec![protected_ref, state])
            .expect("nm2_run_protected returns a value");

        let zero = self.fresh();
        self.push(Inst::Const { dst: zero, val: ConstVal::Int(0) });
        let is_normal = self.fresh();
        self.push(Inst::Binary { dst: is_normal, op: BinOp::Eq, lhs: raised, rhs: zero });

        if !block.except.is_empty() {
            // EXCEPT present: handler runs on an exception; FINALLY (if any) and
            // a normal return follow whether or not we caught one.
            let handler = self.builder.new_block("protect_handler");
            let join = self.builder.new_block("protect_join");
            self.terminate(Terminator::CondBr { cond: is_normal, t_block: join, f_block: handler });

            self.builder.switch_to(handler);
            let prev_retry = self.retry_target.replace(header);
            for arm in &block.except {
                if self.builder.is_terminated() {
                    break;
                }
                self.lower_stmts(&arm.body);
            }
            self.retry_target = prev_retry;
            if !self.builder.is_terminated() {
                // Handler completed normally ⇒ the exception is handled.
                self.call_runtime("nm2_exception_handled", vec![], None, vec![]);
                self.terminate(Terminator::Goto(join));
            }

            self.builder.switch_to(join);
            if let Some(fin) = &block.finally {
                self.lower_stmts(fin);
            }
            if !self.builder.is_terminated() {
                self.emit_protected_return(result_slot);
            }
        } else {
            // FINALLY-only: the finalizer runs on both paths, then an
            // unhandled exception is re-raised.
            if let Some(fin) = &block.finally {
                self.lower_stmts(fin);
            }
            if !self.builder.is_terminated() {
                let normal = self.builder.new_block("protect_normal");
                let reraise = self.builder.new_block("protect_reraise");
                self.terminate(Terminator::CondBr { cond: is_normal, t_block: normal, f_block: reraise });

                self.builder.switch_to(reraise);
                self.free_exception_frame();
                self.call_runtime("nm2_reraise", vec![], None, vec![]);
                // nm2_reraise never returns; the block is unreachable past it
                // (a void Return would mistype a function wrapper).
                self.terminate(Terminator::Unreachable);

                self.builder.switch_to(normal);
                self.emit_protected_return(result_slot);
            }
        }
    }

    fn lower_stmts(&mut self, stmts: &[ast::Stmt]) {
        for stmt in stmts {
            if self.builder.is_terminated() {
                break; // dead code after EXIT / RETURN
            }
            self.lower_stmt(stmt);
        }
    }

    fn lower_stmt(&mut self, stmt: &ast::Stmt) {
        match stmt {
            ast::Stmt::Empty(_) => {}

            ast::Stmt::Assign { target, value, .. } => {
                // `arr := "literal"` / `arr := stringConst` where `arr` is a
                // fixed ARRAY OF (wide) CHAR: a string r-value evaluates to a
                // *pointer* to its data, so a plain Store would write the
                // pointer's bits into the array. Copy the characters instead.
                // (Array-to-array assignment loads a value and is unaffected.)
                if let Some(count) = self.wide_char_array_count(target)
                    && self.is_string_rvalue(value)
                {
                    let src = self.eval_expr(value);
                    let dst = self.eval_lvalue(target);
                    let cap = self.fresh();
                    self.push(Inst::Const { dst: cap, val: ConstVal::Int(count) });
                    let addr = self.ctx.addr_ty();
                    let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
                    let params = vec![
                        IrParam { name: "src".into(), ty: addr, is_var: false },
                        IrParam { name: "dst".into(), ty: addr, is_var: false },
                        IrParam { name: "cap".into(), ty: card, is_var: false },
                    ];
                    self.call_runtime("NM2Str.WCopy", params, None, vec![src, dst, cap]);
                    return;
                }
                // Same hazard for a NARROW `ARRAY OF ACHAR`: the string r-value is
                // a pointer into the (UTF-16) literal, so copy the characters,
                // truncating each code unit to its low byte (ASCII/ANSI content).
                if let Some(count) = self.narrow_char_array_count(target)
                    && self.is_string_rvalue(value)
                {
                    let src = self.eval_expr(value);
                    let dst = self.eval_lvalue(target);
                    let cap = self.fresh();
                    self.push(Inst::Const { dst: cap, val: ConstVal::Int(count) });
                    let addr = self.ctx.addr_ty();
                    let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
                    let params = vec![
                        IrParam { name: "src".into(), ty: addr, is_var: false },
                        IrParam { name: "dst".into(), ty: addr, is_var: false },
                        IrParam { name: "cap".into(), ty: card, is_var: false },
                    ];
                    self.call_runtime("NM2Str.WNCopy", params, None, vec![src, dst, cap]);
                    return;
                }
                // `v[i] := x` SIMD lane write: read-modify-write the whole vector
                // (insertelement) since a lane has no independent address.
                if self.try_vector_lane_write(target, value) {
                    return;
                }
                // Whole-aggregate (RECORD / closed ARRAY) lvalue<-lvalue copy of a
                // LARGE aggregate: memmove by address (Inst::MemCopy) instead of an
                // SSA by-value load+store — LLVM's SelectionDAG segfaults legalising
                // a >64K-element by-value aggregate. Small aggregates keep the proven
                // load/store path (threshold-gated, so existing codegen is unchanged).
                if let ast::Expr::Designator(src_d) = value
                    && let Some(tty) = self.ctx.sema.designator_type(self.ctx.mid, target.span)
                    && is_aggregate_xfer(&self.ctx.sema.types, tty)
                    && type_byte_size(&self.ctx.sema.types, tty)
                        .is_some_and(|n| n >= AGGREGATE_MEMCOPY_THRESHOLD)
                {
                    let dst = self.eval_lvalue(target);
                    let src = self.eval_lvalue(src_d);
                    self.push(Inst::MemCopy { dst, src, ty: tty });
                    return;
                }
                let val = self.eval_expr(value);
                let ptr = self.eval_lvalue(target);
                self.push(Inst::Store { ptr, val });
            }

            ast::Stmt::Call(expr, _) => {
                // Intercept NEW(p) — emit Inst::Allocate (GC-aware allocation)
                // followed by a Store back into p.  Under --no-gc the Allocate
                // lowers to malloc(sizeof(*p)); under GC mode it calls
                // nm2_new_rec(TypeDesc*).
                if let ast::Expr::Call(callee, args, _) = expr {
                    if is_new_builtin(callee) {
                        if let [arg] = args.as_slice() {
                            if let ast::Expr::Designator(d) = arg {
                                // Class instance: allocate the object record and
                                // install the vtable pointer.
                                if let Some((obj_rec, name, has_vt)) = self.class_instance_info(d) {
                                    self.lower_class_new(d, obj_rec, &name, has_vt);
                                    return;
                                }
                                if let Some(ptr_ty) = self.sema_var_type(d) {
                                    let new_val = self.fresh();
                                    self.push(Inst::Allocate { dst: new_val, ty: ptr_ty });
                                    let lval = self.eval_lvalue(d);
                                    self.push(Inst::Store { ptr: lval, val: new_val });
                                    return;
                                }
                            }
                        }
                    }
                    // INC / DEC / DISPOSE are pervasive in-place builtins, not
                    // ordinary procedure calls.
                    if self.lower_inc_dec_dispose(callee, args) {
                        return;
                    }
                    // ASSERT(cond) / HALT — pervasive control builtins.
                    if self.lower_assert_halt(callee, args) {
                        return;
                    }
                }

                // Modula-2 allows bare statement calls for parameterless
                // procedures: `WriteLn;` is equivalent to `WriteLn()`.
                // Preserve function-reference semantics in expression context
                // and only synthesize a zero-arg call for statement position.
                if let ast::Expr::Designator(_) = expr {
                    // Bare `HALT` (no parens) is a statement, not a proc call.
                    if self.lower_assert_halt(expr, &[]) {
                        return;
                    }
                    // Bare parameterless method call: `obj.M;` (no parens).
                    if self.try_method_dispatch(expr, &[]).is_some() {
                        return;
                    }
                }
                if let ast::Expr::Designator(d) = expr {
                    if let Some(proc_name) = self.designator_proc_name(d) {
                        let callee = self.resolve_name_as_value(&proc_name);
                        // Hidden capture arguments for a parameterless capturing
                        // nested procedure called as a bare statement.
                        let mut args = Vec::new();
                        let qn = proc_name.segments.join(".");
                        if let Some(caps) = self.ctx.captures.get(&qn).cloned() {
                            for cap in &caps {
                                args.push(self.capture_address(&cap.name));
                                if is_open_array_ty(self.ctx.sema, cap.ty) {
                                    args.push(self.capture_high(&cap.name));
                                }
                            }
                        }
                        let dst = self.fresh();
                        self.push(Inst::Call { dst: Some(dst), callee, args });
                        return;
                    }
                }

                self.eval_expr(expr); // side effects; discard result value
            }

            ast::Stmt::If { arms, else_arm, .. } => {
                self.lower_if(arms, else_arm.as_deref());
            }

            ast::Stmt::While(cond, body, _) => {
                self.lower_while(cond, body);
            }

            ast::Stmt::Repeat(body, cond, _) => {
                self.lower_repeat(body, cond);
            }

            ast::Stmt::For { var, start, end, step, body, .. } => {
                self.lower_for(var, start, end, step.as_ref(), body);
            }

            ast::Stmt::Loop(body, _) => {
                self.lower_loop(body);
            }

            ast::Stmt::Exit(_) => {
                if let Some(frame) = self.builder.current_loop().cloned() {
                    self.terminate(Terminator::Goto(frame.exit_block));
                }
                // No loop context ⇒ already diagnosed by sema.
            }

            ast::Stmt::Return(expr, _) => {
                let val = expr.as_ref().map(|e| {
                    // `RETURN "literal"` from a function whose result type is a
                    // fixed ARRAY OF (wide) CHAR: a string r-value is a pointer,
                    // so copy its characters into an array-valued result slot and
                    // return the loaded array, not the pointer's bits.
                    if let Some(ret_ty) = self.builder.return_ty()
                        && let Some(count) = self.array_char_count(ret_ty)
                        && self.is_string_rvalue(e)
                    {
                        let src = self.eval_expr(e);
                        let slot = self.fresh();
                        self.push(Inst::Alloca { dst: slot, ty: ret_ty });
                        let cap = self.fresh();
                        self.push(Inst::Const { dst: cap, val: ConstVal::Int(count) });
                        let addr = self.ctx.addr_ty();
                        let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
                        let params = vec![
                            IrParam { name: "src".into(), ty: addr, is_var: false },
                            IrParam { name: "dst".into(), ty: addr, is_var: false },
                            IrParam { name: "cap".into(), ty: card, is_var: false },
                        ];
                        self.call_runtime("NM2Str.WCopy", params, None, vec![src, slot, cap]);
                        let out = self.fresh();
                        self.push(Inst::Load { dst: out, ptr: slot });
                        return out;
                    }
                    self.eval_expr(e)
                });
                // A handler/FINALLY RETURN exits the protected wrapper — free
                // its exception frame first (no-op elsewhere).
                self.free_exception_frame();
                // In an outlined protected function, the value is returned to
                // the wrapper through the shared result slot, not directly.
                match (self.result_slot, val) {
                    (Some(slot), Some(v)) => {
                        self.push(Inst::Store { ptr: slot, val: v });
                        self.terminate(Terminator::Return(None));
                    }
                    (Some(_), None) => self.terminate(Terminator::Return(None)),
                    (None, val) => self.terminate(Terminator::Return(val)),
                }
            }

            ast::Stmt::Raise(expr, _) => match expr {
                // Bare `RAISE` (no operand) re-raises the current exception,
                // ISO-style. The target dialect (PIM4 + ISO core) has no RAISE
                // statement — raises go through `EXCEPTIONS.RAISE` — so this
                // arm is defensive, but lowering it correctly keeps the IR
                // sound if a front end ever produces the node.
                None => {
                    self.call_runtime("nm2_reraise", vec![], None, vec![]);
                    self.terminate(Terminator::Unreachable);
                }
                Some(e) => {
                    let val = self.eval_expr(e);
                    self.terminate(Terminator::Raise(val));
                }
            },

            ast::Stmt::Retry(_) => {
                // Re-run the protected region of the enclosing EXCEPT handler.
                // Clear the current exception first — retrying discards it.
                if let Some(target) = self.retry_target {
                    self.call_runtime("nm2_exception_handled", vec![], None, vec![]);
                    self.terminate(Terminator::Goto(target));
                }
                // Outside a handler RETRY is a no-op (diagnosed by sema).
            }

            ast::Stmt::Case { scrutinee, arms, else_arm, .. } => {
                self.lower_case(scrutinee, arms, else_arm.as_deref());
            }

            ast::Stmt::Guard { selector, arms, else_arm, .. } => {
                self.lower_guard(selector, arms, else_arm.as_deref());
            }

            ast::Stmt::With(d, body, _) => {
                self.lower_with(d, body);
            }

            ast::Stmt::Block(b) => {
                self.lower_block(b);
            }
        }
    }

    // ---- Control flow patterns -------------------------------------------

    /// IF arm[0] THEN … ELSIF arm[1] THEN … ELSE … END
    fn lower_if(&mut self, arms: &[(ast::Expr, Vec<ast::Stmt>)], else_arm: Option<&[ast::Stmt]>) {
        let join = self.builder.new_block("if_join");

        for (i, (cond, body)) in arms.iter().enumerate() {
            let then_block = self.builder.new_block(format!("if_then.{i}"));
            let false_block = if i + 1 < arms.len() {
                self.builder.new_block(format!("if_cond.{}", i + 1))
            } else if else_arm.is_some() {
                self.builder.new_block("if_else")
            } else {
                join
            };

            let cond_val = self.eval_expr(cond);
            self.terminate(Terminator::CondBr { cond: cond_val, t_block: then_block, f_block: false_block });

            self.builder.switch_to(then_block);
            self.lower_stmts(body);
            if !self.builder.is_terminated() {
                self.terminate(Terminator::Goto(join));
            }

            self.builder.switch_to(false_block);
        }

        if let Some(else_stmts) = else_arm {
            self.lower_stmts(else_stmts);
            if !self.builder.is_terminated() {
                self.terminate(Terminator::Goto(join));
            }
            self.builder.switch_to(join);
        }
        // If no else arm, the active block is already `join` (or the last
        // false_block which equals join).
    }

    /// WHILE cond DO body END
    fn lower_while(&mut self, cond: &ast::Expr, body: &[ast::Stmt]) {
        let header = self.builder.new_block("while_cond");
        let body_block = self.builder.new_block("while_body");
        let exit_block = self.builder.new_block("while_exit");

        self.terminate(Terminator::Goto(header));

        self.builder.switch_to(header);
        let cond_val = self.eval_expr(cond);
        self.terminate(Terminator::CondBr { cond: cond_val, t_block: body_block, f_block: exit_block });

        self.builder.switch_to(body_block);
        self.builder.push_loop(LoopFrame { exit_block, continue_block: header });
        self.lower_stmts(body);
        self.builder.pop_loop();
        if self.mode() == MemoryMode::Gc {
            self.push(Inst::GcSafePoint);
        }
        if !self.builder.is_terminated() {
            self.terminate(Terminator::Goto(header)); // back edge
        }

        self.builder.switch_to(exit_block);
    }

    /// REPEAT body UNTIL cond
    fn lower_repeat(&mut self, body: &[ast::Stmt], cond: &ast::Expr) {
        let body_block = self.builder.new_block("repeat_body");
        let exit_block = self.builder.new_block("repeat_exit");

        self.terminate(Terminator::Goto(body_block));

        self.builder.switch_to(body_block);
        self.builder.push_loop(LoopFrame { exit_block, continue_block: body_block });
        self.lower_stmts(body);
        self.builder.pop_loop();

        if !self.builder.is_terminated() {
            let cond_val = self.eval_expr(cond);
            // Exit when condition is TRUE (REPEAT…UNTIL semantics).
            self.terminate(Terminator::CondBr { cond: cond_val, t_block: exit_block, f_block: body_block });
        }

        self.builder.switch_to(exit_block);
    }

    /// FOR var := start TO end [BY step] DO body END
    fn lower_for(
        &mut self,
        var: &str,
        start: &ast::Expr,
        end: &ast::Expr,
        step: Option<&ast::Expr>,
        body: &[ast::Stmt],
    ) {
        let int_ty = self.ctx.int_ty();

        // Alloca the loop variable (or reuse an existing slot).
        let ptr = if let Some(binding) = self.locals.get(var).copied() {
            self.local_ptr(binding)
        } else {
            let p = self.fresh();
            self.push(Inst::Alloca { dst: p, ty: int_ty });
            self.locals.insert(
                var.to_string(),
                Binding { storage: p, ty: int_ty, kind: BindingKind::Direct },
            );
            p
        };

        let start_val = self.eval_expr(start);
        self.push(Inst::Store { ptr, val: start_val });

        // Evaluate end/step in the pre-loop block (they're invariant).
        let end_val = self.eval_expr(end);
        let step_val = step.map(|s| self.eval_expr(s)).unwrap_or_else(|| {
            let r = self.fresh();
            self.push(Inst::Const { dst: r, val: ConstVal::Int(1) });
            r
        });
        // The step's sign (loop-invariant) selects the termination test: an
        // ascending loop runs while `cur <= end`, a descending one while
        // `cur >= end`. M2 requires a constant step, but a runtime sign works
        // too with this branchless form.
        let zero = self.fresh();
        self.push(Inst::Const { dst: zero, val: ConstVal::Int(0) });
        let step_nonneg = self.fresh();
        self.push(Inst::Binary { dst: step_nonneg, op: BinOp::Ge, lhs: step_val, rhs: zero });

        let header = self.builder.new_block("for_cond");
        let body_block = self.builder.new_block("for_body");
        let step_block = self.builder.new_block("for_step");
        let exit_block = self.builder.new_block("for_exit");

        self.terminate(Terminator::Goto(header));

        // Header: ascending → `cur <= end`; descending → `cur >= end`. Selected
        // by step sign without a branch:
        //   cond = (step>=0 & cur<=end) | (step<0 & cur>=end)
        self.builder.switch_to(header);
        let cur = self.fresh();
        self.push(Inst::Load { dst: cur, ptr });
        let le = self.fresh();
        self.push(Inst::Binary { dst: le, op: BinOp::Le, lhs: cur, rhs: end_val });
        let ge = self.fresh();
        self.push(Inst::Binary { dst: ge, op: BinOp::Ge, lhs: cur, rhs: end_val });
        let step_neg = self.fresh();
        self.push(Inst::Unary { dst: step_neg, op: UnaryOp::Not, val: step_nonneg });
        let asc = self.fresh();
        self.push(Inst::Binary { dst: asc, op: BinOp::And, lhs: step_nonneg, rhs: le });
        let desc = self.fresh();
        self.push(Inst::Binary { dst: desc, op: BinOp::And, lhs: step_neg, rhs: ge });
        let cond = self.fresh();
        self.push(Inst::Binary { dst: cond, op: BinOp::Or, lhs: asc, rhs: desc });
        self.terminate(Terminator::CondBr { cond, t_block: body_block, f_block: exit_block });

        // Body.
        self.builder.switch_to(body_block);
        self.builder.push_loop(LoopFrame { exit_block, continue_block: step_block });
        self.lower_stmts(body);
        self.builder.pop_loop();
        if !self.builder.is_terminated() {
            self.terminate(Terminator::Goto(step_block));
        }

        // Step: advance only if another whole step stays in range, so after the
        // loop the control variable is left at its LAST in-range value (per the
        // ISO spec), not the overshoot value. Overflow-safe: compare the remaining
        // distance to `end` against the step magnitude rather than forming
        // `cur + step` and testing that against `end` (which can overflow).
        self.builder.switch_to(step_block);
        let cur2 = self.fresh();
        self.push(Inst::Load { dst: cur2, ptr });
        // Ascending room = end - cur2 (>= 0 here); descending room = cur2 - end.
        let room_asc = self.fresh();
        self.push(Inst::Binary { dst: room_asc, op: BinOp::Sub, lhs: end_val, rhs: cur2 });
        let room_desc = self.fresh();
        self.push(Inst::Binary { dst: room_desc, op: BinOp::Sub, lhs: cur2, rhs: end_val });
        let neg_step = self.fresh();
        self.push(Inst::Binary { dst: neg_step, op: BinOp::Sub, lhs: zero, rhs: step_val });
        let step_neg2 = self.fresh();
        self.push(Inst::Unary { dst: step_neg2, op: UnaryOp::Not, val: step_nonneg });
        // Another step fits?  ascending: room_asc >= step;  descending:
        // room_desc >= |step|.  Branchless, selected by the step sign.
        let fits_asc0 = self.fresh();
        self.push(Inst::Binary { dst: fits_asc0, op: BinOp::Ge, lhs: room_asc, rhs: step_val });
        let fits_asc = self.fresh();
        self.push(Inst::Binary { dst: fits_asc, op: BinOp::And, lhs: step_nonneg, rhs: fits_asc0 });
        let fits_desc0 = self.fresh();
        self.push(Inst::Binary { dst: fits_desc0, op: BinOp::Ge, lhs: room_desc, rhs: neg_step });
        let fits_desc = self.fresh();
        self.push(Inst::Binary { dst: fits_desc, op: BinOp::And, lhs: step_neg2, rhs: fits_desc0 });
        let fits = self.fresh();
        self.push(Inst::Binary { dst: fits, op: BinOp::Or, lhs: fits_asc, rhs: fits_desc });
        let advance = self.builder.new_block("for_advance");
        self.terminate(Terminator::CondBr { cond: fits, t_block: advance, f_block: exit_block });

        // Advance: another iteration fits — store cur2 + step and re-enter.
        self.builder.switch_to(advance);
        let next = self.fresh();
        self.push(Inst::Binary { dst: next, op: BinOp::Add, lhs: cur2, rhs: step_val });
        self.push(Inst::Store { ptr, val: next });
        self.terminate(Terminator::Goto(header));

        self.builder.switch_to(exit_block);
    }

    /// LOOP body END  (infinite loop; exited via EXIT)
    fn lower_loop(&mut self, body: &[ast::Stmt]) {
        let loop_block = self.builder.new_block("loop");
        let exit_block = self.builder.new_block("loop_exit");

        self.terminate(Terminator::Goto(loop_block));

        self.builder.switch_to(loop_block);
        self.builder.push_loop(LoopFrame { exit_block, continue_block: loop_block });
        self.lower_stmts(body);
        self.builder.pop_loop();

        if !self.builder.is_terminated() {
            if self.mode() == MemoryMode::Gc {
                self.push(Inst::GcSafePoint);
            }
            self.terminate(Terminator::Goto(loop_block)); // back edge
        }

        self.builder.switch_to(exit_block);
    }

    /// CASE scrutinee OF arms … [ELSE …] END
    /// Resolve a CASE label to its ordinal value: an integer/char literal, or
    /// a designator naming an enumeration member or an integer/char CONST.
    fn case_label_int(&self, e: &ast::Expr) -> Option<i128> {
        if let Some(n) = const_int(e) {
            return Some(n);
        }
        // Fold constant integer arithmetic over operands we can already resolve,
        // so a high-bit constant *expression* (e.g. `0FFF...F0H - 16`) is
        // recognised as the non-negative unsigned value it denotes. Without this
        // a `cardinalVar > <constExpr>` test sees an unresolved RHS, fails
        // `unsigned_compatible`, and wrongly takes the SIGNED path — treating the
        // constant as negative and inverting the comparison. (Also lets CASE
        // labels be constant expressions.)
        if let ast::Expr::Binary(op, lhs, rhs, _) = e {
            if let (Some(a), Some(b)) = (self.case_label_int(lhs), self.case_label_int(rhs)) {
                use ast::BinaryOp::*;
                return match op {
                    Add => a.checked_add(b),
                    Sub => a.checked_sub(b),
                    Mul => a.checked_mul(b),
                    Band => Some(a & b),
                    Bor => Some(a | b),
                    Bxor => Some(a ^ b),
                    _ => None,
                };
            }
            return None;
        }
        let ast::Expr::Designator(d) = e else { return None };
        let kind = if d.selectors.is_empty() && d.base.segments.len() == 1 {
            self.ctx.sema.scopes.lookup(self.scope, &d.base.segments[0]).map(|s| s.kind.clone())
        } else {
            self.designator_module_member(d)
                .and_then(|(_, _, k, consumed)| (consumed == d.selectors.len()).then_some(k))
        }?;
        match kind {
            SymbolKind::EnumMember { ord, .. } => Some(ord),
            SymbolKind::Const { value: newm2_sema::ConstValue::Int(n), .. } => Some(n),
            SymbolKind::Const { value: newm2_sema::ConstValue::Char(c), .. } => Some(c as i128),
            _ => None,
        }
    }

    fn lower_case(
        &mut self,
        scrutinee: &ast::Expr,
        arms: &[ast::CaseArm],
        else_arm: Option<&[ast::Stmt]>,
    ) {
        let val = self.eval_expr(scrutinee);
        let join = self.builder.new_block("case_join");
        let default_block = self.builder.new_block("case_else");

        // Pre-allocate one block per arm.
        let arm_blocks: Vec<BlockId> = (0..arms.len())
            .map(|i| self.builder.new_block(format!("case_arm.{i}")))
            .collect();

        // Partition labels: single values drive a dense switch; ranges become
        // explicit `lo <= val <= hi` checks (no 256-entry truncation, so wide
        // ranges like `0..1000` match every value).
        let mut singles: Vec<(i128, BlockId)> = Vec::new();
        let mut ranges: Vec<(i128, i128, BlockId)> = Vec::new();
        for (arm, &ab) in arms.iter().zip(&arm_blocks) {
            for label in &arm.labels {
                match label {
                    ast::CaseLabel::Single(e) => {
                        if let Some(n) = self.case_label_int(e) {
                            singles.push((n, ab));
                        }
                    }
                    ast::CaseLabel::Range(lo, hi) => {
                        if let (Some(l), Some(h)) =
                            (self.case_label_int(lo), self.case_label_int(hi))
                        {
                            ranges.push((l, h, ab));
                        }
                    }
                }
            }
        }

        // Range checks first, each chaining to the next; the tail emits the
        // single-value switch with the else/no-match block as its default.
        for (lo, hi, ab) in ranges {
            let next = self.builder.new_block("case_range");
            let lo_c = self.fresh();
            self.push(Inst::Const { dst: lo_c, val: ConstVal::Int(lo) });
            let hi_c = self.fresh();
            self.push(Inst::Const { dst: hi_c, val: ConstVal::Int(hi) });
            let ge = self.fresh();
            self.push(Inst::Binary { dst: ge, op: BinOp::Ge, lhs: val, rhs: lo_c });
            let le = self.fresh();
            self.push(Inst::Binary { dst: le, op: BinOp::Le, lhs: val, rhs: hi_c });
            let inr = self.fresh();
            self.push(Inst::Binary { dst: inr, op: BinOp::And, lhs: ge, rhs: le });
            self.terminate(Terminator::CondBr { cond: inr, t_block: ab, f_block: next });
            self.builder.switch_to(next);
        }

        self.terminate(Terminator::Switch { val, arms: singles, default: default_block });

        // Lower each arm body.
        for (arm, &ab) in arms.iter().zip(&arm_blocks) {
            self.builder.switch_to(ab);
            self.lower_stmts(&arm.body);
            if !self.builder.is_terminated() {
                self.terminate(Terminator::Goto(join));
            }
        }

        // Lower else / no-match block. With an ELSE the arm runs; without one,
        // ISO requires a CASE selector that matches no label to raise
        // M2EXCEPTION.caseSelectException (a catchable exception, not a silent
        // fall-through).
        self.builder.switch_to(default_block);
        if let Some(else_stmts) = else_arm {
            self.lower_stmts(else_stmts);
            if !self.builder.is_terminated() {
                self.terminate(Terminator::Goto(join));
            }
        } else if !self.builder.is_terminated() {
            self.raise_m2_exception(2); // caseSelectException
        }

        self.builder.switch_to(join);
    }

    /// Lower `GUARD selector AS [x:]T DO … {| …} [ELSE …] END`. Evaluate the
    /// selector once, take its typeinfo (null-safe: a NIL/EMPTY selector yields
    /// null and matches no arm → ELSE/raise), then test each arm with
    /// `nm2_rtti_isa` as an if-else ladder. A matched arm may bind a read-only
    /// narrowed view of the selector. No match + no ELSE raises guardException.
    fn lower_guard(
        &mut self,
        selector: &ast::Expr,
        arms: &[ast::GuardArm],
        else_arm: Option<&[ast::Stmt]>,
    ) {
        let sel = self.eval_expr(selector);
        let addr = self.ctx.sema.types.builtin(Builtin::Address);
        let bool_ty = self.ctx.sema.types.builtin(Builtin::Boolean);
        // The selector's typeinfo, computed ONCE (null-safe).
        let cand_ti = self
            .call_runtime(
                "nm2_typeinfo_of",
                vec![IrParam { name: "obj".into(), ty: addr, is_var: false }],
                Some(addr),
                vec![sel],
            )
            .expect("nm2_typeinfo_of returns a value");

        let join = self.builder.new_block("guard_join");
        let default_block = self.builder.new_block("guard_else");
        let arm_blocks: Vec<BlockId> = (0..arms.len())
            .map(|i| self.builder.new_block(format!("guard_arm.{i}")))
            .collect();

        if arms.is_empty() {
            self.terminate(Terminator::Goto(default_block));
        }
        // Test ladder: arm i runs iff nm2_rtti_isa(cand, &{Ti}.typeinfo); else the
        // next test, and after the last the default (ELSE / raise).
        for (i, arm) in arms.iter().enumerate() {
            let target_ti = match self.guard_arm_class(&arm.guarded_type) {
                Some(cid) => {
                    let name = self.ctx.sema.classes.get(cid).name.clone();
                    self.emit_global_ref(format!("{name}.typeinfo"), addr)
                }
                None => self.emit_nil(), // unresolved type — sema already errored
            };
            let matched = self
                .call_runtime(
                    "nm2_rtti_isa",
                    vec![
                        IrParam { name: "cand".into(), ty: addr, is_var: false },
                        IrParam { name: "target".into(), ty: addr, is_var: false },
                    ],
                    Some(bool_ty),
                    vec![cand_ti, target_ti],
                )
                .expect("nm2_rtti_isa returns a value");
            let next = if i + 1 < arms.len() {
                self.builder.new_block("guard_test")
            } else {
                default_block
            };
            self.terminate(Terminator::CondBr {
                cond: matched,
                t_block: arm_blocks[i],
                f_block: next,
            });
            self.builder.switch_to(next);
        }

        // Arm bodies, each optionally binding the read-only narrowed denoter to
        // the (already RTTI-verified) selector pointer.
        for (i, arm) in arms.iter().enumerate() {
            self.builder.switch_to(arm_blocks[i]);
            let saved = if let Some(dn) = &arm.denoter {
                let arm_ty = self
                    .guard_arm_class(&arm.guarded_type)
                    .map(|cid| self.ctx.sema.classes.get(cid).type_id)
                    .unwrap_or(addr);
                let slot = self.fresh();
                self.push(Inst::Alloca { dst: slot, ty: arm_ty });
                self.push(Inst::Store { ptr: slot, val: sel });
                let prev = self.locals.insert(
                    dn.clone(),
                    Binding { storage: slot, ty: arm_ty, kind: BindingKind::Direct },
                );
                Some((dn.clone(), prev))
            } else {
                None
            };
            self.lower_stmts(&arm.body);
            if !self.builder.is_terminated() {
                self.terminate(Terminator::Goto(join));
            }
            // Restore any shadowed outer binding of the denoter name.
            if let Some((dn, prev)) = saved {
                match prev {
                    Some(p) => {
                        self.locals.insert(dn, p);
                    }
                    None => {
                        self.locals.remove(&dn);
                    }
                }
            }
        }

        // No-match: run ELSE if present, else raise guardException.
        self.builder.switch_to(default_block);
        if let Some(else_stmts) = else_arm {
            self.lower_stmts(else_stmts);
            if !self.builder.is_terminated() {
                self.terminate(Terminator::Goto(join));
            }
        } else if !self.builder.is_terminated() {
            self.raise_guard_exception();
        }

        self.builder.switch_to(join);
    }

    /// Resolve a GUARD arm's guarded type name to its class id, via sema's
    /// recorded resolution at the type name's span. Returns None for an interface
    /// (no typeinfo — sema already errors; this prevents a dangling typeinfo ref).
    fn guard_arm_class(&self, qn: &ast::QualName) -> Option<ClassSymbolId> {
        let cid = match self.ctx.sema.resolved_name(self.ctx.mid, qn.span)? {
            SymbolKind::Type(ty) => match self.ctx.sema.types.get(*ty) {
                TypeKind::Class { symbol } => ClassSymbolId(*symbol),
                _ => return None,
            },
            SymbolKind::Class(cid) => *cid,
            _ => return None,
        };
        if self.ctx.sema.classes.get(cid).is_interface {
            None
        } else {
            Some(cid)
        }
    }

    /// Raise the NewM2 GUARD no-match exception; the block becomes unreachable.
    fn raise_guard_exception(&mut self) {
        self.call_runtime("nm2_raise_guard", vec![], None, vec![]);
        self.terminate(Terminator::Unreachable);
    }

    /// Raise an ISO `M2EXCEPTION` language exception via the runtime and mark
    /// the current block unreachable. `number` is the `M2Exceptions` ordinal
    /// (e.g. 0 = indexException, 2 = caseSelectException).
    fn raise_m2_exception(&mut self, number: i128) {
        let n = self.fresh();
        self.push(Inst::Const { dst: n, val: ConstVal::Int(number) });
        let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
        let params = vec![IrParam { name: "n".into(), ty: card, is_var: false }];
        self.call_runtime("nm2_raise_m2", params, None, vec![n]);
        self.terminate(Terminator::Unreachable);
    }

    /// Emit an array index bounds check: if the 0-based index `adj` is not in
    /// `[0, count)` raise `indexException`. The unsigned compare also catches a
    /// negative index (it wraps to a large value).
    fn emit_index_bounds_check(&mut self, adj: ValueId, count: i128) {
        let count_c = self.fresh();
        self.push(Inst::Const { dst: count_c, val: ConstVal::Int(count) });
        let oob = self.fresh();
        self.push(Inst::Binary { dst: oob, op: BinOp::UGe, lhs: adj, rhs: count_c });
        let fail = self.builder.new_block("idx_oob");
        let cont = self.builder.new_block("idx_ok");
        self.terminate(Terminator::CondBr { cond: oob, t_block: fail, f_block: cont });
        self.builder.switch_to(fail);
        self.raise_m2_exception(0); // indexException
        self.builder.switch_to(cont);
    }

    /// Emit a whole-number division-by-zero check: if `divisor` is 0 raise
    /// `wholeDivException`.
    fn emit_div_zero_check(&mut self, divisor: ValueId) {
        let zero = self.fresh();
        self.push(Inst::Const { dst: zero, val: ConstVal::Int(0) });
        let is_zero = self.fresh();
        self.push(Inst::Binary { dst: is_zero, op: BinOp::Eq, lhs: divisor, rhs: zero });
        let fail = self.builder.new_block("div0");
        let cont = self.builder.new_block("div_ok");
        self.terminate(Terminator::CondBr { cond: is_zero, t_block: fail, f_block: cont });
        self.builder.switch_to(fail);
        self.raise_m2_exception(6); // wholeDivException
        self.builder.switch_to(cont);
    }

    /// Emit a NIL-pointer dereference check: if the loaded pointer `ptr` is NIL
    /// raise `invalidLocation`. The pointer is cast to an integer and compared
    /// to 0 (NIL) so the check does not depend on pointer-typed `icmp`.
    fn emit_nil_check(&mut self, ptr: ValueId) {
        let int_ty = self.ctx.int_ty();
        let pi = self.fresh();
        self.push(Inst::Cast { dst: pi, kind: CastKind::PtrToInt, val: ptr, ty: int_ty });
        let zero = self.fresh();
        self.push(Inst::Const { dst: zero, val: ConstVal::Int(0) });
        let is_nil = self.fresh();
        self.push(Inst::Binary { dst: is_nil, op: BinOp::Eq, lhs: pi, rhs: zero });
        let fail = self.builder.new_block("nil_deref");
        let cont = self.builder.new_block("nil_ok");
        self.terminate(Terminator::CondBr { cond: is_nil, t_block: fail, f_block: cont });
        self.builder.switch_to(fail);
        self.raise_m2_exception(3); // invalidLocation
        self.builder.switch_to(cont);
    }

    /// WITH designator DO body END — capture the record's address once and
    /// push it so bare field names inside the body resolve against it.
    fn lower_with(&mut self, d: &ast::Designator, body: &[ast::Stmt]) {
        // Classify the WITH designator's type (releasing the type-arena borrow
        // before we emit any instructions).
        let kind = self
            .ctx
            .sema
            .designator_type(self.ctx.mid, d.span)
            .map(|t| match self.ctx.sema.types.get(t) {
                TypeKind::Record(_) => (t, false),
                TypeKind::Pointer { base }
                    if matches!(self.ctx.sema.types.get(*base), TypeKind::Record(_)) =>
                {
                    (*base, true)
                }
                _ => (t, false),
            });
        let (ptr, rec_ty) = match kind {
            // `WITH p DO` where p : POINTER TO record — the record is `p^`.
            Some((rec, true)) => (self.eval_designator_val(d), rec),
            // `WITH rec DO` / `WITH p^ DO` — the designator is the record.
            Some((rec, false)) => (self.eval_lvalue(d), rec),
            None => (self.eval_lvalue(d), self.ctx.int_ty()),
        };
        self.with_stack.push((ptr, rec_ty));
        self.lower_stmts(body);
        self.with_stack.pop();
    }

    /// If `d` is a bare name (with optional trailing selectors) that names a
    /// field of an active `WITH` record — and is not an ordinary binding —
    /// return its lvalue address GEP'd off the captured WITH base.
    fn with_field_ptr(&mut self, d: &ast::Designator) -> Option<ValueId> {
        if self.with_stack.is_empty() {
            return None;
        }
        let [name] = d.base.segments.as_slice() else {
            return None;
        };
        // Defer to ordinary resolution when the name is a local or any symbol
        // in scope (mirrors sema's check-on-miss WITH-field rule).
        if self.locals.contains_key(name.as_str())
            || self.ctx.sema.scopes.lookup(self.scope, name).is_some()
        {
            return None;
        }
        // Innermost WITH record that has this field.
        let stack: Vec<(ValueId, newm2_sema::TypeId)> =
            self.with_stack.iter().rev().copied().collect();
        let (with_ptr, rec_ty) = stack
            .into_iter()
            .find(|(_, rec)| self.resolve_field_index(*rec, name).is_some())?;
        let field_sel = ast::Selector::Field(name.clone(), d.base.span);
        let mut ptr = self.apply_selector(with_ptr, Some(rec_ty), &field_sel);
        let mut cur = self.selector_result_type(rec_ty, &field_sel);
        for sel in &d.selectors {
            ptr = self.apply_selector(ptr, cur, sel);
            cur = cur.and_then(|t| self.selector_result_type(t, sel));
        }
        Some(ptr)
    }

    // ---- Expression evaluation -------------------------------------------

    /// Evaluate an expression, returning the ValueId holding the result.
    fn eval_expr(&mut self, expr: &ast::Expr) -> ValueId {
        match expr {
            ast::Expr::Integer(n, _) => {
                let dst = self.fresh();
                self.push(Inst::Const { dst, val: ConstVal::Int(*n as i128) });
                dst
            }
            ast::Expr::Real(f, _) => {
                let dst = self.fresh();
                self.push(Inst::Const { dst, val: ConstVal::Real(*f) });
                dst
            }
            ast::Expr::Char(c, _) => {
                let dst = self.fresh();
                self.push(Inst::Const { dst, val: ConstVal::Char(c.value) });
                dst
            }
            ast::Expr::String(s, _) => {
                self.ctx.get_or_add_string(self.ir, &s.value);
                let dst = self.fresh();
                self.push(Inst::Const { dst, val: ConstVal::Str(s.value.clone()) });
                dst
            }
            ast::Expr::Nil(_) => self.emit_nil(),
            ast::Expr::Designator(d) => self.eval_designator_val(d),
            ast::Expr::Call(callee, args, span) => self.eval_call(callee, args, *span),
            ast::Expr::Binary(op, lhs, rhs, _) => self.eval_binary(*op, lhs, rhs),
            ast::Expr::Unary(op, val, _) => self.eval_unary(*op, val),
            ast::Expr::Set { elements, span, .. } => {
                let set_ty = self
                    .ctx
                    .sema
                    .expr_type(self.ctx.mid, *span)
                    .unwrap_or_else(|| self.ctx.sema.types.builtin(Builtin::Bitset));
                // `T{...}` where T is RECORD or ARRAY is a structured aggregate
                // constructor: materialise a slot and store each positional
                // value into its field / element, then load the value.
                match self.ctx.sema.types.get(set_ty) {
                    TypeKind::Record(_) | TypeKind::Array { .. } | TypeKind::OpenArray { .. } => {
                        return self.lower_aggregate_constructor(set_ty, elements);
                    }
                    // `REAL32X4{e0, e1, e2, e3}` (or `{x}` broadcast) builds a
                    // SIMD lane vector from per-lane values.
                    TypeKind::Vector { .. } => {
                        let lanes: Vec<ValueId> = elements
                            .iter()
                            .filter_map(|e| match e {
                                ast::SetElem::Single(v) => Some(self.eval_expr(v)),
                                ast::SetElem::Range(..) => None,
                            })
                            .collect();
                        let dst = self.fresh();
                        self.push(Inst::VecBuild { dst, lanes, ty: set_ty });
                        return dst;
                    }
                    _ => {}
                }
                // SET constructor `T{ e1, lo..hi, ... }` lowered to a 256-bit
                // value: OR a `1 << elem` mask per single element, and a
                // poison-free range mask `(~0 << lo) & (~0 >> (255-hi))` per
                // range. The set type is i256 in codegen.
                let widen = |this: &mut Self, raw: ValueId| -> ValueId {
                    let d = this.fresh();
                    this.push(Inst::Cast { dst: d, kind: CastKind::IntZeroExt, val: raw, ty: set_ty });
                    d
                };
                let set_const = |this: &mut Self, n: i128, kind: CastKind| -> ValueId {
                    let c = this.fresh();
                    this.push(Inst::Const { dst: c, val: ConstVal::Int(n) });
                    let d = this.fresh();
                    this.push(Inst::Cast { dst: d, kind, val: c, ty: set_ty });
                    d
                };
                let mut acc = set_const(self, 0, CastKind::IntZeroExt);
                for elem in elements {
                    match elem {
                        ast::SetElem::Single(value) => {
                            let raw = self.eval_expr(value);
                            let bit = widen(self, raw);
                            let one = set_const(self, 1, CastKind::IntZeroExt);
                            let mask = self.fresh();
                            self.push(Inst::Binary { dst: mask, op: BinOp::Shl, lhs: one, rhs: bit });
                            let next = self.fresh();
                            self.push(Inst::Binary { dst: next, op: BinOp::BitOr, lhs: acc, rhs: mask });
                            acc = next;
                        }
                        ast::SetElem::Range(lo, hi) => {
                            let lo_raw = self.eval_expr(lo);
                            let hi_raw = self.eval_expr(hi);
                            let lo_w = widen(self, lo_raw);
                            let hi_w = widen(self, hi_raw);
                            // all-ones (i256) = sign-extend(-1)
                            let ones = set_const(self, -1, CastKind::IntSignExt);
                            // lowpart = ~0 << lo  (bits lo..255)
                            let lowp = self.fresh();
                            self.push(Inst::Binary { dst: lowp, op: BinOp::Shl, lhs: ones, rhs: lo_w });
                            // highpart = ~0 >>logical (255 - hi)  (bits 0..hi)
                            let c255 = set_const(self, 255, CastKind::IntZeroExt);
                            let shr = self.fresh();
                            self.push(Inst::Binary { dst: shr, op: BinOp::Sub, lhs: c255, rhs: hi_w });
                            let highp = self.fresh();
                            self.push(Inst::Binary { dst: highp, op: BinOp::Shr, lhs: ones, rhs: shr });
                            let rmask = self.fresh();
                            self.push(Inst::Binary { dst: rmask, op: BinOp::BitAnd, lhs: lowp, rhs: highp });
                            let next = self.fresh();
                            self.push(Inst::Binary { dst: next, op: BinOp::BitOr, lhs: acc, rhs: rmask });
                            acc = next;
                        }
                    }
                }
                acc
            }
        }
    }

    /// Emit a named constant of type `ty`. A RECORD/ARRAY aggregate is carried
    /// to codegen as a typed `ConstVal::Aggregate` (materialised as an LLVM
    /// constant struct/array); everything else goes through `emit_sema_const`.
    fn emit_const_value(
        &mut self,
        value: &newm2_sema::ConstValue,
        ty: newm2_sema::types::TypeId,
    ) -> ValueId {
        if matches!(value, newm2_sema::ConstValue::Aggregate(_)) {
            let dst = self.fresh();
            self.push(Inst::Const {
                dst,
                val: ConstVal::Aggregate { value: value.clone(), ty },
            });
            return dst;
        }
        self.emit_sema_const(value)
    }

    /// Emit a sema constant as an IR value. Scalars become a single `Const`;
    /// a `Set` is materialised as an i256 bitmask (`OR (1 << m)` per member),
    /// matching the representation used for runtime `Expr::Set` constructors.
    fn emit_sema_const(&mut self, value: &newm2_sema::ConstValue) -> ValueId {
        if let newm2_sema::ConstValue::Set(members) = value {
            let set_ty = self.ctx.sema.types.builtin(Builtin::Bitset);
            let set_const = |this: &mut Self, n: i128| -> ValueId {
                let c = this.fresh();
                this.push(Inst::Const { dst: c, val: ConstVal::Int(n) });
                let d = this.fresh();
                this.push(Inst::Cast { dst: d, kind: CastKind::IntZeroExt, val: c, ty: set_ty });
                d
            };
            let mut acc = set_const(self, 0);
            for &m in members {
                let one = set_const(self, 1);
                let bitpos = set_const(self, m);
                let mask = self.fresh();
                self.push(Inst::Binary { dst: mask, op: BinOp::Shl, lhs: one, rhs: bitpos });
                let next = self.fresh();
                self.push(Inst::Binary { dst: next, op: BinOp::BitOr, lhs: acc, rhs: mask });
                acc = next;
            }
            return acc;
        }
        if let newm2_sema::ConstValue::Complex(re, im) = value {
            let cty = self.ctx.sema.types.builtin(Builtin::Complex);
            return self.build_complex(cty, *re, *im);
        }
        let dst = self.fresh();
        self.push(Inst::Const { dst, val: sema_const_to_ir(value) });
        dst
    }

    /// Materialise a COMPLEX value `{re, im}` in a fresh slot and return it as
    /// a loaded struct value. Used for CMPLX(...) and complex constants.
    fn build_complex_vals(
        &mut self,
        cty: newm2_sema::types::TypeId,
        re: ValueId,
        im: ValueId,
    ) -> ValueId {
        let tmp = self.fresh();
        self.push(Inst::Alloca { dst: tmp, ty: cty });
        let f0 = self.fresh();
        self.push(Inst::FieldPtr { dst: f0, base: tmp, field: 0 });
        self.push(Inst::Store { ptr: f0, val: re });
        let f1 = self.fresh();
        self.push(Inst::FieldPtr { dst: f1, base: tmp, field: 1 });
        self.push(Inst::Store { ptr: f1, val: im });
        let dst = self.fresh();
        self.push(Inst::Load { dst, ptr: tmp });
        dst
    }

    /// Lower a structured aggregate constructor `T{ v0, v1, ... }` (RECORD or
    /// ARRAY) into a fresh slot of type `ty`: store each positional value into
    /// its field (records) or element index (arrays), then load and return the
    /// composed value. Ranges are not meaningful here and are ignored.
    fn lower_aggregate_constructor(
        &mut self,
        ty: newm2_sema::types::TypeId,
        elements: &[ast::SetElem],
    ) -> ValueId {
        let elem_ty = match self.ctx.sema.types.get(ty) {
            TypeKind::Array { base, .. } | TypeKind::OpenArray { base } => Some(*base),
            _ => None,
        };
        // Record field types in member order (empty for an array constructor).
        let field_tys: Vec<newm2_sema::types::TypeId> = match self.ctx.sema.types.get(ty) {
            TypeKind::Record(layout) => {
                layout.flatten_fields().into_iter().map(|(_, t)| t).collect()
            }
            _ => Vec::new(),
        };
        let slot = self.fresh();
        self.push(Inst::Alloca { dst: slot, ty });
        let mut field: u32 = 0;
        for elem in elements {
            let ast::SetElem::Single(value) = elem else { continue };
            let dst = self.fresh();
            if let Some(et) = elem_ty {
                let idx = self.fresh();
                self.push(Inst::Const { dst: idx, val: ConstVal::Int(field as i128) });
                self.push(Inst::IndexPtr { dst, base: slot, index: idx, elem_ty: et });
            } else {
                self.push(Inst::FieldPtr { dst, base: slot, field });
            }
            // The slot's element/field type. A string r-value going into a fixed
            // ARRAY OF CHAR slot must be *copied* (its pointer's bits are not the
            // characters); everything else is a plain store of the value.
            let slot_ty = elem_ty.or_else(|| field_tys.get(field as usize).copied());
            if let Some(st) = slot_ty
                && let Some(count) = self.array_char_count(st)
                && self.is_string_rvalue(value)
            {
                let src = self.eval_expr(value);
                let cap = self.fresh();
                self.push(Inst::Const { dst: cap, val: ConstVal::Int(count) });
                let addr = self.ctx.addr_ty();
                let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
                let params = vec![
                    IrParam { name: "src".into(), ty: addr, is_var: false },
                    IrParam { name: "dst".into(), ty: addr, is_var: false },
                    IrParam { name: "cap".into(), ty: card, is_var: false },
                ];
                self.call_runtime("NM2Str.WCopy", params, None, vec![src, dst, cap]);
            } else {
                let v = self.eval_expr(value);
                self.push(Inst::Store { ptr: dst, val: v });
            }
            field += 1;
        }
        let out = self.fresh();
        self.push(Inst::Load { dst: out, ptr: slot });
        out
    }

    fn build_complex(&mut self, cty: newm2_sema::types::TypeId, re: f64, im: f64) -> ValueId {
        let r = self.fresh();
        self.push(Inst::Const { dst: r, val: ConstVal::Real(re) });
        let i = self.fresh();
        self.push(Inst::Const { dst: i, val: ConstVal::Real(im) });
        self.build_complex_vals(cty, r, i)
    }

    fn complex_ty_of(&self, e: &ast::Expr) -> newm2_sema::types::TypeId {
        self.ctx
            .sema
            .expr_type(self.ctx.mid, expr_span(e))
            .unwrap_or_else(|| self.ctx.sema.types.builtin(Builtin::Complex))
    }

    fn is_complex_expr(&self, e: &ast::Expr) -> bool {
        matches!(
            self.ctx.sema.expr_type(self.ctx.mid, expr_span(e)).map(|t| self.ctx.sema.types.get(t)),
            Some(TypeKind::Builtin(Builtin::Complex | Builtin::LongComplex))
        )
    }

    /// Project field `field` (0 = RE, 1 = IM) out of a COMPLEX-valued
    /// expression by materialising it to a slot and loading the component.
    fn complex_component(&mut self, e: &ast::Expr, field: u32) -> ValueId {
        let v = self.eval_expr(e);
        let cty = self.complex_ty_of(e);
        let tmp = self.fresh();
        self.push(Inst::Alloca { dst: tmp, ty: cty });
        self.push(Inst::Store { ptr: tmp, val: v });
        let fp = self.fresh();
        self.push(Inst::FieldPtr { dst: fp, base: tmp, field });
        let dst = self.fresh();
        self.push(Inst::Load { dst, ptr: fp });
        dst
    }

    /// `CMPLX(re, im)` — build a COMPLEX/LONGCOMPLEX struct value.
    fn lower_cmplx_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
        call_span: Span,
    ) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        if !d.selectors.is_empty() || d.base.segments.len() != 1 {
            return None;
        }
        if d.base.segments[0] != "CMPLX" || args.len() != 2 {
            return None;
        }
        let cty = self
            .ctx
            .sema
            .expr_type(self.ctx.mid, call_span)
            .unwrap_or_else(|| self.ctx.sema.types.builtin(Builtin::Complex));
        let re = self.eval_expr(&args[0]);
        let im = self.eval_expr(&args[1]);
        Some(self.build_complex_vals(cty, re, im))
    }

    /// `RE(z)` / `IM(z)` — extract the real / imaginary component.
    fn lower_re_im_builtin(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        if !d.selectors.is_empty() || d.base.segments.len() != 1 || args.len() != 1 {
            return None;
        }
        let field = match d.base.segments[0].as_str() {
            "RE" => 0,
            "IM" => 1,
            _ => return None,
        };
        Some(self.complex_component(&args[0], field))
    }

    /// Equality / inequality of two COMPLEX values: compare both components.
    fn lower_complex_eq(&mut self, op: ast::BinaryOp, lhs: &ast::Expr, rhs: &ast::Expr) -> ValueId {
        let lre = self.complex_component(lhs, 0);
        let rre = self.complex_component(rhs, 0);
        let re_eq = self.fresh();
        self.push(Inst::Binary { dst: re_eq, op: BinOp::Eq, lhs: lre, rhs: rre });
        let lim = self.complex_component(lhs, 1);
        let rim = self.complex_component(rhs, 1);
        let im_eq = self.fresh();
        self.push(Inst::Binary { dst: im_eq, op: BinOp::Eq, lhs: lim, rhs: rim });
        let both = self.fresh();
        self.push(Inst::Binary { dst: both, op: BinOp::And, lhs: re_eq, rhs: im_eq });
        if matches!(op, ast::BinaryOp::Ne) {
            let dst = self.fresh();
            self.push(Inst::Unary { dst, op: UnaryOp::Not, val: both });
            dst
        } else {
            both
        }
    }

    /// Evaluate a COMPLEX/scalar expression into its `(re, im)` components,
    /// evaluating the operand exactly once. A non-complex (real/scalar) operand
    /// promotes to `(value, 0)` so mixed `z + r` arithmetic works.
    fn complex_parts(&mut self, e: &ast::Expr) -> (ValueId, ValueId) {
        let v = self.eval_expr(e);
        if self.is_complex_expr(e) {
            let cty = self.complex_ty_of(e);
            let tmp = self.fresh();
            self.push(Inst::Alloca { dst: tmp, ty: cty });
            self.push(Inst::Store { ptr: tmp, val: v });
            let f0 = self.fresh();
            self.push(Inst::FieldPtr { dst: f0, base: tmp, field: 0 });
            let re = self.fresh();
            self.push(Inst::Load { dst: re, ptr: f0 });
            let f1 = self.fresh();
            self.push(Inst::FieldPtr { dst: f1, base: tmp, field: 1 });
            let im = self.fresh();
            self.push(Inst::Load { dst: im, ptr: f1 });
            (re, im)
        } else {
            let zero = self.fresh();
            self.push(Inst::Const { dst: zero, val: ConstVal::Real(0.0) });
            (v, zero)
        }
    }

    fn fbin(&mut self, op: BinOp, l: ValueId, r: ValueId) -> ValueId {
        let dst = self.fresh();
        self.push(Inst::Binary { dst, op, lhs: l, rhs: r });
        dst
    }

    /// COMPLEX arithmetic: `+ - * /` on COMPLEX/LONGCOMPLEX operands, with the
    /// standard component formulas. `(a+bi)·(c+di) = (ac−bd) + (ad+bc)i`;
    /// division by `(c²+d²)`.
    fn lower_complex_arith(
        &mut self,
        op: ast::BinaryOp,
        lhs: &ast::Expr,
        rhs: &ast::Expr,
    ) -> ValueId {
        let cty = if self.is_complex_expr(lhs) {
            self.complex_ty_of(lhs)
        } else {
            self.complex_ty_of(rhs)
        };
        let (a, b) = self.complex_parts(lhs);
        let (c, d) = self.complex_parts(rhs);
        let (re, im) = match op {
            ast::BinaryOp::Add => (self.fbin(BinOp::FAdd, a, c), self.fbin(BinOp::FAdd, b, d)),
            ast::BinaryOp::Sub => (self.fbin(BinOp::FSub, a, c), self.fbin(BinOp::FSub, b, d)),
            ast::BinaryOp::Mul => {
                let ac = self.fbin(BinOp::FMul, a, c);
                let bd = self.fbin(BinOp::FMul, b, d);
                let ad = self.fbin(BinOp::FMul, a, d);
                let bc = self.fbin(BinOp::FMul, b, c);
                (self.fbin(BinOp::FSub, ac, bd), self.fbin(BinOp::FAdd, ad, bc))
            }
            ast::BinaryOp::Div => {
                let cc = self.fbin(BinOp::FMul, c, c);
                let dd = self.fbin(BinOp::FMul, d, d);
                let denom = self.fbin(BinOp::FAdd, cc, dd);
                let ac = self.fbin(BinOp::FMul, a, c);
                let bd = self.fbin(BinOp::FMul, b, d);
                let bc = self.fbin(BinOp::FMul, b, c);
                let ad = self.fbin(BinOp::FMul, a, d);
                let re_num = self.fbin(BinOp::FAdd, ac, bd);
                let im_num = self.fbin(BinOp::FSub, bc, ad);
                (self.fbin(BinOp::FDiv, re_num, denom), self.fbin(BinOp::FDiv, im_num, denom))
            }
            _ => unreachable!("non-arithmetic op routed to lower_complex_arith"),
        };
        self.build_complex_vals(cty, re, im)
    }

    /// Short-circuit `lhs AND rhs` / `lhs OR rhs`. The rhs is evaluated only
    /// when the lhs does not already determine the result. The two paths' values
    /// merge through a boolean stack slot (the IR has no SSA phi; cross-block
    /// values go through memory, as for any local).
    fn eval_short_circuit(&mut self, op: ast::BinaryOp, lhs: &ast::Expr, rhs: &ast::Expr) -> ValueId {
        let bool_ty = self.ctx.sema.types.builtin(Builtin::Boolean);
        let slot = self.fresh();
        self.push(Inst::Alloca { dst: slot, ty: bool_ty });

        let l = self.eval_expr(lhs);
        self.push(Inst::Store { ptr: slot, val: l }); // result defaults to the lhs value

        let rhs_block = self.builder.new_block("sc_rhs");
        let join = self.builder.new_block("sc_join");
        // AND: evaluate rhs only when lhs is TRUE; OR: only when lhs is FALSE.
        let (t_block, f_block) = match op {
            ast::BinaryOp::And => (rhs_block, join),
            ast::BinaryOp::Or => (join, rhs_block),
            _ => unreachable!("eval_short_circuit called with {op:?}"),
        };
        self.terminate(Terminator::CondBr { cond: l, t_block, f_block });

        self.builder.switch_to(rhs_block);
        let r = self.eval_expr(rhs);
        self.push(Inst::Store { ptr: slot, val: r });
        self.terminate(Terminator::Goto(join));

        self.builder.switch_to(join);
        let dst = self.fresh();
        self.push(Inst::Load { dst, ptr: slot });
        dst
    }

    fn eval_binary(&mut self, op: ast::BinaryOp, lhs: &ast::Expr, rhs: &ast::Expr) -> ValueId {
        // COMPLEX equality/inequality compares both components.
        if matches!(op, ast::BinaryOp::Eq | ast::BinaryOp::Ne)
            && (self.is_complex_expr(lhs) || self.is_complex_expr(rhs))
        {
            return self.lower_complex_eq(op, lhs, rhs);
        }
        // COMPLEX arithmetic (+ - * /) by component.
        if matches!(
            op,
            ast::BinaryOp::Add | ast::BinaryOp::Sub | ast::BinaryOp::Mul | ast::BinaryOp::Div
        ) && (self.is_complex_expr(lhs) || self.is_complex_expr(rhs))
        {
            return self.lower_complex_arith(op, lhs, rhs);
        }

        // Constant string/char concatenation: `'a' + 'b'`, `015C + 012C`,
        // `"Hello " + name` where every operand is a char/string constant. `+`
        // is never arithmetic on characters in Modula-2, so fold the chain to a
        // single string literal rather than emitting an integer add.
        if matches!(op, ast::BinaryOp::Add)
            && let Some(mut s) = self.fold_string_concat(lhs)
            && let Some(rs) = self.fold_string_concat(rhs)
        {
            s.push_str(&rs);
            self.ctx.get_or_add_string(self.ir, &s);
            let dst = self.fresh();
            self.push(Inst::Const { dst, val: ConstVal::Str(s) });
            return dst;
        }

        // Short-circuit boolean AND/OR (& / OR). Modula-2 mandates conditional
        // (left-to-right, short-circuit) evaluation: `FALSE AND f()` must NOT
        // call f(), and `TRUE OR f()` must NOT call f(). Lower as control flow,
        // evaluating the rhs only when the lhs doesn't already decide the result
        // — NOT as an eager bitwise BinOp::And/Or over two pre-computed operands.
        if matches!(op, ast::BinaryOp::And | ast::BinaryOp::Or) {
            return self.eval_short_circuit(op, lhs, rhs);
        }

        let mut l = self.eval_expr(lhs);
        let mut r = self.eval_expr(rhs);
        let dst = self.fresh();

        match op {
            ast::BinaryOp::In => {
                self.push(Inst::SetOp { dst, op: SetOpKind::Member, lhs: l, rhs: r });
                return dst;
            }
            // Set arithmetic: + - * / on set-typed operands are union /
            // difference / intersection / symmetric-difference, NOT integer
            // arithmetic on the underlying bitmask.
            ast::BinaryOp::Add | ast::BinaryOp::Sub | ast::BinaryOp::Mul | ast::BinaryOp::Div
                if self.expr_is_set(lhs) || self.expr_is_set(rhs) =>
            {
                let sop = match op {
                    ast::BinaryOp::Add => SetOpKind::Union,
                    ast::BinaryOp::Sub => SetOpKind::Difference,
                    ast::BinaryOp::Mul => SetOpKind::Intersection,
                    ast::BinaryOp::Div => SetOpKind::SymDiff,
                    _ => unreachable!(),
                };
                self.push(Inst::SetOp { dst, op: sop, lhs: l, rhs: r });
                return dst;
            }
            _ => {}
        }

        // Sign-extend narrow *signed* operands (INTEGER8/16/32) to the canonical
        // 64-bit width before integer arithmetic, so e.g. an i8 holding -5 is
        // not zero-extended to 251. Unsigned narrow types stay narrow and are
        // zero-extended correctly by codegen. Skip when either side is REAL (the
        // float path converts operands itself).
        if !self.expr_is_float(lhs) && !self.expr_is_float(rhs) {
            l = self.widen_if_signed_narrow(l, lhs);
            r = self.widen_if_signed_narrow(r, rhs);
        }

        // ISO whole-number division by zero check (on by default). DIV/MOD/REM
        // are integer-only; `/` is checked only on integer operands.
        let is_int_div = matches!(
            op,
            ast::BinaryOp::DivKw | ast::BinaryOp::Mod | ast::BinaryOp::Rem
        ) || (matches!(op, ast::BinaryOp::Div)
            && !self.expr_is_float(lhs)
            && !self.expr_is_float(rhs));
        if self.ctx.runtime_checks && is_int_div {
            self.emit_div_zero_check(r);
        }

        let ir_op = match op {
            ast::BinaryOp::Add => BinOp::Add,
            ast::BinaryOp::Sub => BinOp::Sub,
            ast::BinaryOp::Mul => BinOp::Mul,
            ast::BinaryOp::Div => BinOp::Quot, // `/` for reals / CARDINAL
            ast::BinaryOp::DivKw => BinOp::Div, // `DIV` keyword = Wirth floored
            ast::BinaryOp::Mod => BinOp::Mod,
            ast::BinaryOp::Rem => BinOp::Rem,
            ast::BinaryOp::Eq => BinOp::Eq,
            ast::BinaryOp::Ne => BinOp::Ne,
            ast::BinaryOp::Lt => BinOp::Lt,
            ast::BinaryOp::Le => BinOp::Le,
            ast::BinaryOp::Gt => BinOp::Gt,
            ast::BinaryOp::Ge => BinOp::Ge,
            ast::BinaryOp::And => BinOp::And,
            ast::BinaryOp::Or => BinOp::Or,
            ast::BinaryOp::Bor => BinOp::BitOr,
            ast::BinaryOp::Band => BinOp::BitAnd,
            ast::BinaryOp::Bxor => BinOp::BitXor,
            ast::BinaryOp::Shl => BinOp::Shl,
            ast::BinaryOp::Shr => BinOp::Shr,
            ast::BinaryOp::In => unreachable!(),
        };
        // SIMD scalar broadcast: in `v * 2.0` one operand is a lane vector and
        // the other a real scalar — splat the scalar across all lanes (VecBuild
        // narrows it to the lane element type) so the packed op has matching
        // operand types.
        match (self.expr_vector_type(lhs), self.expr_vector_type(rhs)) {
            (Some(_), None) => {
                let b = self.fresh();
                let ty = self.expr_vector_type(lhs).unwrap();
                self.push(Inst::VecBuild { dst: b, lanes: vec![r], ty });
                r = b;
            }
            (None, Some(ty)) => {
                let b = self.fresh();
                self.push(Inst::VecBuild { dst: b, lanes: vec![l], ty });
                l = b;
            }
            _ => {}
        }

        // Real operands use the floating-point instruction variants.
        // Comparisons keep their shared opcode — codegen dispatches those
        // on the LLVM operand representation. When only one operand is REAL
        // (e.g. `realVar + 1` or `y < MAX(INTEGER)` in a float context), the
        // integer operand is converted to float so both sides match.
        let lf = self.expr_is_float(lhs);
        let rf = self.expr_is_float(rhs);
        let ir_op = if lf || rf {
            let float_ty = self.ctx.sema.types.builtin(Builtin::LongReal);
            if !lf {
                let c = self.fresh();
                self.push(Inst::Cast { dst: c, kind: CastKind::IntToFloat, val: l, ty: float_ty });
                l = c;
            }
            if !rf {
                let c = self.fresh();
                self.push(Inst::Cast { dst: c, kind: CastKind::IntToFloat, val: r, ty: float_ty });
                r = c;
            }
            match ir_op {
                BinOp::Add => BinOp::FAdd,
                BinOp::Sub => BinOp::FSub,
                BinOp::Mul => BinOp::FMul,
                BinOp::Quot => BinOp::FDiv, // `/` on REAL / LONGREAL
                other => other,
            }
        } else if (self.expr_is_unsigned(lhs) || self.expr_is_unsigned(rhs))
            && self.unsigned_compatible(lhs)
            && self.unsigned_compatible(rhs)
        {
            // CARDINAL / ADDRESS / CHAR … are unsigned: use unsigned compare
            // and division so e.g. MAX(CARDINAL) (all-ones) compares as a large
            // positive value, not -1. A non-negative integer literal adapts to
            // the unsigned operand (`c > 100`, `c DIV 2`) rather than forcing
            // the signed path.
            match ir_op {
                BinOp::Lt => BinOp::ULt,
                BinOp::Le => BinOp::ULe,
                BinOp::Gt => BinOp::UGt,
                BinOp::Ge => BinOp::UGe,
                BinOp::Div => BinOp::Quot, // DIV on CARDINAL is unsigned
                BinOp::Mod => BinOp::Rem,  // MOD on CARDINAL is unsigned
                other => other,
            }
        } else {
            // Signed (or mixed) path: ISO REM follows the sign of the dividend,
            // so use a signed remainder rather than the unsigned default.
            match ir_op {
                BinOp::Rem => BinOp::SRem,
                other => other,
            }
        };
        self.push(Inst::Binary { dst, op: ir_op, lhs: l, rhs: r });
        dst
    }

    /// True when sema typed this expression as an unsigned ordinal type
    /// (CARDINAL family, ADDRESS, CHAR, BYTE/WORD/…). Used to select unsigned
    /// comparison/division.
    fn expr_is_unsigned(&self, expr: &ast::Expr) -> bool {
        use Builtin::*;
        let Some(ty) = self.ctx.sema.expr_type(self.ctx.mid, expr_span(expr)) else {
            return false;
        };
        let ty = match self.ctx.sema.types.get(ty) {
            TypeKind::Subrange { host, lo, .. } => {
                // A subrange is unsigned only if its lower bound is non-negative.
                if *lo < 0 {
                    return false;
                }
                *host
            }
            _ => ty,
        };
        matches!(
            self.ctx.sema.types.get(ty),
            TypeKind::Builtin(
                Cardinal | LongCard | Cardinal8 | Cardinal16 | Cardinal32 | Cardinal64
                    | Byte | Word | Dword | Qword | Address | Adrcard | Char | Achar
            )
        )
    }

    /// True when `expr` can participate in an unsigned operation: it is either
    /// an unsigned-typed value or a non-negative compile-time constant (literal,
    /// named CONST, or enum member). The constant adapts to the unsigned operand
    /// exactly like a literal, so `cardinalVal DIV Scale` (Scale a CONST = 10000,
    /// typed INTEGER) stays on the UNSIGNED division path — otherwise a dividend
    /// with bit 63 set is wrongly divided as a negative signed value. Negative
    /// literals are written `-(literal)` (a unary op) and correctly fall through
    /// to the signed path. The unsigned branch still requires at least one
    /// operand to be unsigned-*typed*, so `intVal DIV Scale` stays signed.
    fn unsigned_compatible(&self, expr: &ast::Expr) -> bool {
        self.expr_is_unsigned(expr) || self.case_label_int(expr).is_some_and(|n| n >= 0)
    }

    /// If `expr` is a narrow *signed* integer (INTEGER8/16/32, or a subrange
    /// with a negative lower bound on such a host), sign-extend its lowered
    /// value `val` to the canonical 64-bit width and return the new ValueId;
    /// otherwise return `val` unchanged.
    fn widen_if_signed_narrow(&mut self, val: ValueId, expr: &ast::Expr) -> ValueId {
        use Builtin::*;
        let Some(ty) = self.ctx.sema.expr_type(self.ctx.mid, expr_span(expr)) else {
            return val;
        };
        let base = match self.ctx.sema.types.get(ty) {
            TypeKind::Subrange { host, lo, .. } => {
                if *lo >= 0 {
                    return val; // non-negative subrange is unsigned
                }
                *host
            }
            _ => ty,
        };
        if matches!(
            self.ctx.sema.types.get(base),
            TypeKind::Builtin(Integer8 | Integer16 | Integer32)
        ) {
            let i64ty = self.ctx.sema.types.builtin(Integer);
            let dst = self.fresh();
            self.push(Inst::Cast { dst, kind: CastKind::IntSignExt, val, ty: i64ty });
            dst
        } else {
            val
        }
    }

    /// True when sema typed this expression as a SET / BITSET.
    fn expr_is_set(&self, expr: &ast::Expr) -> bool {
        self.ctx
            .sema
            .expr_type(self.ctx.mid, expr_span(expr))
            .map(|ty| {
                matches!(
                    self.ctx.sema.types.get(ty),
                    TypeKind::Set { .. } | TypeKind::Builtin(Builtin::Bitset)
                )
            })
            .unwrap_or(false)
    }

    /// True when sema typed this expression as a float — REAL/LONGREAL/REAL32/
    /// REAL16, or a SIMD vector of float lanes (so `+` lowers to a vector FAdd).
    fn expr_is_float(&self, expr: &ast::Expr) -> bool {
        self.ctx
            .sema
            .expr_type(self.ctx.mid, expr_span(expr))
            .map(|ty| self.type_is_float(ty))
            .unwrap_or(false)
    }

    /// The vector type of an expression, if sema typed it as a SIMD vector.
    fn expr_vector_type(&self, e: &ast::Expr) -> Option<newm2_sema::types::TypeId> {
        let ty = self.ctx.sema.expr_type(self.ctx.mid, expr_span(e))?;
        matches!(self.ctx.sema.types.get(ty), TypeKind::Vector { .. }).then_some(ty)
    }

    fn type_is_float(&self, ty: newm2_sema::types::TypeId) -> bool {
        match self.ctx.sema.types.get(ty) {
            TypeKind::Builtin(
                Builtin::Real | Builtin::LongReal | Builtin::Real32 | Builtin::Real16,
            ) => true,
            TypeKind::Vector { base, .. } => self.type_is_float(*base),
            _ => false,
        }
    }

    fn eval_unary(&mut self, op: ast::UnaryOp, val: &ast::Expr) -> ValueId {
        // -(a+bi) = (-a) + (-b)i — negate each COMPLEX component.
        if matches!(op, ast::UnaryOp::Neg) && self.is_complex_expr(val) {
            let cty = self.complex_ty_of(val);
            let (a, b) = self.complex_parts(val);
            let nre = self.fresh();
            self.push(Inst::Unary { dst: nre, op: UnaryOp::FNeg, val: a });
            let nim = self.fresh();
            self.push(Inst::Unary { dst: nim, op: UnaryOp::FNeg, val: b });
            return self.build_complex_vals(cty, nre, nim);
        }
        let v = self.eval_expr(val);
        match op {
            ast::UnaryOp::Pos => v, // no-op
            ast::UnaryOp::Neg => {
                let dst = self.fresh();
                let uop = if self.expr_is_float(val) { UnaryOp::FNeg } else { UnaryOp::Neg };
                self.push(Inst::Unary { dst, op: uop, val: v });
                dst
            }
            ast::UnaryOp::Not => {
                let dst = self.fresh();
                self.push(Inst::Unary { dst, op: UnaryOp::Not, val: v });
                dst
            }
        }
    }

    fn lower_transfer_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
        call_span: Span,
    ) -> Option<ValueId> {
        let ast::Expr::Designator(designator) = callee else {
            return None;
        };

        let builtin_name = match designator.base.segments.as_slice() {
            [name] if designator.selectors.is_empty() => name.as_str(),
            [module, name] if designator.selectors.is_empty() && module == "SYSTEM" => name.as_str(),
            [module]
                if module == "SYSTEM"
                    && matches!(designator.selectors.as_slice(), [ast::Selector::Field(_, _)]) =>
            {
                match &designator.selectors[0] {
                    ast::Selector::Field(name, _) => name.as_str(),
                    _ => unreachable!(),
                }
            }
            _ => return None,
        };

        if !matches!(builtin_name, "VAL" | "CAST") || args.len() != 2 {
            return None;
        }

        let target_ty = self.ctx.sema.expr_type(self.ctx.mid, call_span)?;
        let source_ty = self.ctx.sema.expr_type(self.ctx.mid, expr_span(&args[1]))?;
        let kind =
            classify_transfer_cast(self.ctx.sema, source_ty, target_ty, builtin_name == "CAST")?;
        let value = self.eval_expr(&args[1]);
        let dst = self.fresh();
        self.push(Inst::Cast {
            dst,
            kind,
            val: value,
            ty: target_ty,
        });
        Some(dst)
    }

    /// Resolve a designator that *names a type* to its `TypeId` (e.g. the
    /// callee of `ADDRESS(x)` or `SYSTEM.ADDRESS(x)`). Returns `None` for
    /// designators that name a value, procedure, etc.
    /// The declared type of a plain variable `name` (local or module-scope).
    fn plain_var_type(&self, name: &str) -> Option<newm2_sema::types::TypeId> {
        if let Some(b) = self.locals.get(name) {
            return Some(b.ty);
        }
        match &self.ctx.sema.scopes.lookup(self.scope, name)?.kind {
            SymbolKind::Var { ty, .. } => Some(*ty),
            _ => None,
        }
    }

    /// Field type of a record by field name (flattened, so variant arms too).
    fn record_field_type(
        &self,
        record_ty: newm2_sema::types::TypeId,
        name: &str,
    ) -> Option<newm2_sema::types::TypeId> {
        match self.ctx.sema.types.get(record_ty) {
            TypeKind::Record(layout) => layout
                .flatten_fields()
                .into_iter()
                .find(|(n, _)| n == name)
                .map(|(_, t)| t),
            _ => None,
        }
    }

    /// The type produced by applying `selectors` to `base` — a designator
    /// type-walk used to recognise a SIMD lane access whose container is a
    /// vector reached through fields/indices (`rec.v[i]`, `grid[k][i]`).
    fn walk_designator_type(
        &self,
        base: &ast::QualName,
        selectors: &[ast::Selector],
    ) -> Option<newm2_sema::types::TypeId> {
        let mut ty = self.resolve_name_type(base)?;
        for sel in selectors {
            ty = match sel {
                ast::Selector::Field(fname, _) => self.record_field_type(ty, fname)?,
                ast::Selector::Index(ixs, _) => match self.ctx.sema.types.get(ty) {
                    TypeKind::Array { indices, base } => {
                        if ixs.len() >= indices.len() {
                            *base
                        } else {
                            return None; // partial sub-array — not a lane access
                        }
                    }
                    TypeKind::OpenArray { base } | TypeKind::Vector { base, .. } => *base,
                    _ => return None,
                },
                ast::Selector::Deref(_) => match self.ctx.sema.types.get(ty) {
                    TypeKind::Pointer { base } => *base,
                    _ => return None,
                },
                ast::Selector::TypeGuard(_, _) => return None,
            };
        }
        Some(ty)
    }

    /// `<base>[i]` SIMD lane read → load the whole (addressable) vector and
    /// extractelement. `<base>` may be a variable, a record field, or an array
    /// element (anything with an lvalue), e.g. `v[i]`, `rec.v[i]`, `grid[k][i]`.
    fn try_vector_lane_read(&mut self, d: &ast::Designator) -> Option<ValueId> {
        let (last, rest) = d.selectors.split_last()?;
        let ast::Selector::Index(indices, _) = last else {
            return None;
        };
        if indices.len() != 1 {
            return None;
        }
        let base_ty = self.walk_designator_type(&d.base, rest)?;
        if !matches!(self.ctx.sema.types.get(base_ty), TypeKind::Vector { .. }) {
            return None;
        }
        let base = ast::Designator { base: d.base.clone(), selectors: rest.to_vec(), span: d.span };
        let ptr = self.eval_lvalue(&base);
        let vec = self.fresh();
        self.push(Inst::Load { dst: vec, ptr });
        let lane = self.eval_expr(&indices[0]);
        let dst = self.fresh();
        self.push(Inst::VecExtract { dst, vec, lane });
        Some(dst)
    }

    /// `<base>[i] := x` SIMD lane write → load the addressable vector,
    /// insertelement, store it back. Handles variable / field / array-element
    /// bases. Returns true if handled.
    fn try_vector_lane_write(&mut self, target: &ast::Designator, value: &ast::Expr) -> bool {
        let Some((last, rest)) = target.selectors.split_last() else {
            return false;
        };
        let ast::Selector::Index(indices, _) = last else {
            return false;
        };
        if indices.len() != 1 {
            return false;
        }
        let Some(base_ty) = self.walk_designator_type(&target.base, rest) else {
            return false;
        };
        if !matches!(self.ctx.sema.types.get(base_ty), TypeKind::Vector { .. }) {
            return false;
        }
        let base =
            ast::Designator { base: target.base.clone(), selectors: rest.to_vec(), span: target.span };
        let ptr = self.eval_lvalue(&base);
        let cur = self.fresh();
        self.push(Inst::Load { dst: cur, ptr });
        let lane = self.eval_expr(&indices[0]);
        let x = self.eval_expr(value);
        let nv = self.fresh();
        self.push(Inst::VecInsert { dst: nv, vec: cur, lane, val: x });
        self.push(Inst::Store { ptr, val: nv });
        true
    }

    fn designator_names_type(&self, d: &ast::Designator) -> Option<newm2_sema::types::TypeId> {
        if !d.selectors.is_empty() {
            return None;
        }
        match d.base.segments.as_slice() {
            [name] => match &self.ctx.sema.scopes.lookup(self.scope, name)?.kind {
                SymbolKind::Type(ty) => Some(*ty),
                _ => None,
            },
            [module, member] => {
                let SymbolKind::Module(_, mscope) =
                    &self.ctx.sema.scopes.lookup(self.scope, module)?.kind
                else {
                    return None;
                };
                match &self.ctx.sema.scopes.get(*mscope).get(member)?.kind {
                    SymbolKind::Type(ty) => Some(*ty),
                    _ => None,
                }
            }
            _ => None,
        }
    }

    /// Lower `T(x)` where T names a scalar type as a value conversion
    /// (equivalent to `VAL(T, x)`) — an IR cast, not a call to a function `@T`.
    fn lower_type_conversion(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
        call_span: Span,
    ) -> Option<ValueId> {
        if args.len() != 1 {
            return None;
        }
        let ast::Expr::Designator(d) = callee else {
            return None;
        };
        let target_ty = self.designator_names_type(d)?;
        let source_ty = self.ctx.sema.expr_type(self.ctx.mid, expr_span(&args[0]))?;
        // VAL semantics (arithmetic value conversion). `classify_transfer_cast`
        // returns None for a non-scalar target, in which case this is not a
        // conversion we can lower — fall back to the generic path.
        let kind = classify_transfer_cast(self.ctx.sema, source_ty, target_ty, false)?;
        let value = self.eval_expr(&args[0]);
        let dst = self.fresh();
        self.push(Inst::Cast { dst, kind, val: value, ty: target_ty });
        Some(dst)
    }

    /// Lower the pervasive ordinal/character conversions `ORD(x)` and `CHR(n)`
    /// as ordinal casts (width-adjusting) rather than procedure calls.
    fn lower_ord_chr_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
        call_span: Span,
    ) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        if !d.selectors.is_empty() || d.base.segments.len() != 1 || args.len() != 1 {
            return None;
        }
        // CAP upper-cases a CHAR — a conditional transform, not a cast.
        if d.base.segments[0] == "CAP" {
            let value = self.eval_expr(&args[0]);
            let dst = self.fresh();
            self.push(Inst::Unary { dst, op: UnaryOp::Cap, val: value });
            return Some(dst);
        }
        let (kind, default_ty) = match d.base.segments[0].as_str() {
            "ORD" => (CastKind::CharToOrd, self.ctx.sema.types.builtin(Builtin::Cardinal)),
            "CHR" => (CastKind::OrdToChar, self.ctx.sema.types.builtin(Builtin::Char)),
            _ => return None,
        };
        let target_ty = self.ctx.sema.expr_type(self.ctx.mid, call_span).unwrap_or(default_ty);
        let value = self.eval_expr(&args[0]);
        let dst = self.fresh();
        self.push(Inst::Cast { dst, kind, val: value, ty: target_ty });
        Some(dst)
    }

    /// `ODD(x)` — true when the whole value `x` is odd. Lowered inline as the
    /// low bit `(x AND 1) # 0` (correct for signed two's-complement too).
    fn lower_odd_builtin(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        if !d.selectors.is_empty() || d.base.segments.len() != 1 || args.len() != 1 {
            return None;
        }
        if d.base.segments[0] != "ODD" {
            return None;
        }
        let v = self.eval_expr(&args[0]);
        let one = self.fresh();
        self.push(Inst::Const { dst: one, val: ConstVal::Int(1) });
        let masked = self.fresh();
        self.push(Inst::Binary { dst: masked, op: BinOp::BitAnd, lhs: v, rhs: one });
        let zero = self.fresh();
        self.push(Inst::Const { dst: zero, val: ConstVal::Int(0) });
        let dst = self.fresh();
        self.push(Inst::Binary { dst, op: BinOp::Ne, lhs: masked, rhs: zero });
        Some(dst)
    }

    /// `ISMEMBER(p1, p2): BOOLEAN` — TRUE iff p1's (dynamic-or-static) class is a
    /// subclass-of-or-equal to p2. Each operand is a class TYPE name or an object
    /// VALUE. (TYPE, TYPE) folds at compile time; the others compute each
    /// operand's `{Class}.typeinfo` pointer (a global ref for a type; the
    /// null-safe `nm2_typeinfo_of` for a value) and call `nm2_rtti_isa`.
    fn lower_ismember_builtin(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        if !d.selectors.is_empty()
            || d.base.segments.len() != 1
            || d.base.segments[0] != "ISMEMBER"
            || args.len() != 2
        {
            return None;
        }
        let (is_ty0, cid0, obj0) = self.ismember_class_of(&args[0])?;
        let (is_ty1, cid1, obj1) = self.ismember_class_of(&args[1])?;

        // (TYPE, TYPE): fold the static subclass relation.
        if is_ty0 && is_ty1 {
            let val = self.class_is_a(cid0, cid1);
            let dst = self.fresh();
            self.push(Inst::Const { dst, val: ConstVal::Bool(val) });
            return Some(dst);
        }

        let addr = self.ctx.sema.types.builtin(Builtin::Address);
        let bool_ty = self.ctx.sema.types.builtin(Builtin::Boolean);
        let ti0 = self.ismember_typeinfo(is_ty0, cid0, obj0, addr);
        let ti1 = self.ismember_typeinfo(is_ty1, cid1, obj1, addr);
        self.call_runtime(
            "nm2_rtti_isa",
            vec![
                IrParam { name: "cand".into(), ty: addr, is_var: false },
                IrParam { name: "target".into(), ty: addr, is_var: false },
            ],
            Some(bool_ty),
            vec![ti0, ti1],
        )
    }

    /// Classify an ISMEMBER operand: `(is_type, class id, object value)`. A type
    /// name (resolved to a Type-of-class or a Class symbol) carries no object; a
    /// value operand is evaluated to its object pointer. `None` if not a class.
    fn ismember_class_of(
        &mut self,
        arg: &ast::Expr,
    ) -> Option<(bool, ClassSymbolId, Option<ValueId>)> {
        if let ast::Expr::Designator(d) = arg {
            if d.selectors.is_empty() && d.base.segments.len() == 1 {
                match self.ctx.sema.resolved_name(self.ctx.mid, d.span) {
                    Some(SymbolKind::Type(ty)) => {
                        if let TypeKind::Class { symbol } = self.ctx.sema.types.get(*ty) {
                            return Some((true, ClassSymbolId(*symbol), None));
                        }
                    }
                    Some(SymbolKind::Class(cid)) => return Some((true, *cid, None)),
                    _ => {}
                }
            }
        }
        // A value operand: its class comes from its (designator) type.
        let ty = match arg {
            ast::Expr::Designator(d) => self.ctx.sema.designator_type(self.ctx.mid, d.span)?,
            _ => return None,
        };
        if let TypeKind::Class { symbol } = self.ctx.sema.types.get(ty) {
            let cid = ClassSymbolId(*symbol);
            let obj = self.eval_expr(arg);
            Some((false, cid, Some(obj)))
        } else {
            None
        }
    }

    /// The `{Class}.typeinfo` pointer for an ISMEMBER operand: a global ref for a
    /// type operand, or the null-safe `nm2_typeinfo_of(obj)` for a value operand.
    fn ismember_typeinfo(
        &mut self,
        is_type: bool,
        cid: ClassSymbolId,
        obj: Option<ValueId>,
        addr: newm2_sema::types::TypeId,
    ) -> ValueId {
        if is_type {
            let name = self.ctx.sema.classes.get(cid).name.clone();
            self.emit_global_ref(format!("{name}.typeinfo"), addr)
        } else {
            let o = obj.expect("value ISMEMBER operand has an object value");
            self.call_runtime(
                "nm2_typeinfo_of",
                vec![IrParam { name: "obj".into(), ty: addr, is_var: false }],
                Some(addr),
                vec![o],
            )
            .expect("nm2_typeinfo_of returns a value")
        }
    }

    /// Static subclass-of-or-equal: walk `a`'s single-inheritance base chain.
    fn class_is_a(&self, a: ClassSymbolId, b: ClassSymbolId) -> bool {
        let mut cur = Some(a);
        while let Some(c) = cur {
            if c == b {
                return true;
            }
            cur = self.ctx.sema.classes.get(c).base;
        }
        false
    }

    /// `SUCCEEDED(h)` / `FAILED(h)` — the COM HRESULT severity-bit test.
    /// `FAILED(h) = (h AND 80000000H) # 0` (severity bit set); `SUCCEEDED` is its
    /// negation. Bit 31 carries the HRESULT severity regardless of the holding
    /// width, so masking 80000000H is correct whether `h` is a 32- or 64-bit
    /// value carrying an HRESULT. This is the single definition of the test that
    /// retires the hand-written `hr < 0` / `(hr BAND 80000000H) # 0` idioms.
    fn lower_hresult_test_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
    ) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        if !d.selectors.is_empty() || d.base.segments.len() != 1 || args.len() != 1 {
            return None;
        }
        let failed = match d.base.segments[0].as_str() {
            "FAILED" => true,
            "SUCCEEDED" => false,
            _ => return None,
        };
        let v = self.eval_expr(&args[0]);
        let mask = self.fresh();
        self.push(Inst::Const { dst: mask, val: ConstVal::Int(0x8000_0000) });
        let masked = self.fresh();
        self.push(Inst::Binary { dst: masked, op: BinOp::BitAnd, lhs: v, rhs: mask });
        let zero = self.fresh();
        self.push(Inst::Const { dst: zero, val: ConstVal::Int(0) });
        let dst = self.fresh();
        let op = if failed { BinOp::Ne } else { BinOp::Eq };
        self.push(Inst::Binary { dst, op, lhs: masked, rhs: zero });
        Some(dst)
    }

    /// `ABS(x)` (absolute value) and `INT(x)` / `ENTIER(x)` (to INTEGER).
    fn lower_abs_int_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
        call_span: Span,
    ) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        // Single-argument builtins (ABS/TRUNC/…) plus the 2/3-arg SIMD reductions
        // (DOT, FMA). Each match arm validates its own arity.
        if !d.selectors.is_empty() || d.base.segments.len() != 1 || args.is_empty() || args.len() > 3
        {
            return None;
        }
        let name = d.base.segments[0].as_str();
        let arg_is_float = self.expr_is_float(&args[0]);
        match name {
            "ABS" => {
                let v = self.eval_expr(&args[0]);
                // ABS of a SIMD vector is lane-wise (llvm.fabs).
                if let Some(vty) = self.expr_vector_type(&args[0]) {
                    let dst = self.fresh();
                    self.push(Inst::VecIntrinsic { dst, op: VecIntrin::Fabs, args: vec![v], ty: vty });
                    return Some(dst);
                }
                let dst = self.fresh();
                self.push(Inst::Unary { dst, op: UnaryOp::Abs, val: v });
                Some(dst)
            }
            // SIMD reductions / fused multiply-add.
            "SUM" => {
                let v = self.eval_expr(&args[0]);
                let vty = self.expr_vector_type(&args[0])?;
                let dst = self.fresh();
                self.push(Inst::VecIntrinsic { dst, op: VecIntrin::ReduceAdd, args: vec![v], ty: vty });
                Some(dst)
            }
            "DOT" => {
                let a = self.eval_expr(&args[0]);
                let b = self.eval_expr(&args[1]);
                let vty = self.expr_vector_type(&args[0])?;
                let prod = self.fresh();
                self.push(Inst::Binary { dst: prod, op: BinOp::FMul, lhs: a, rhs: b });
                let dst = self.fresh();
                self.push(Inst::VecIntrinsic { dst, op: VecIntrin::ReduceAdd, args: vec![prod], ty: vty });
                Some(dst)
            }
            "FMA" => {
                let a = self.eval_expr(&args[0]);
                let b = self.eval_expr(&args[1]);
                let c = self.eval_expr(&args[2]);
                let vty = self.expr_vector_type(&args[0])?;
                let dst = self.fresh();
                self.push(Inst::VecIntrinsic { dst, op: VecIntrin::Fma, args: vec![a, b, c], ty: vty });
                Some(dst)
            }
            // Float → integer. A no-op when the argument is already integral.
            "INT" | "ENTIER" | "TRUNC" => {
                let v = self.eval_expr(&args[0]);
                if !arg_is_float {
                    return Some(v);
                }
                let ty = self
                    .ctx
                    .sema
                    .expr_type(self.ctx.mid, call_span)
                    .unwrap_or_else(|| self.ctx.int_ty());
                let dst = self.fresh();
                self.push(Inst::Cast { dst, kind: CastKind::FloatToInt, val: v, ty });
                Some(dst)
            }
            // Integer → float. A no-op when the argument is already real
            // (REAL and LONGREAL are both f64 in this build).
            "FLOAT" | "LFLOAT" => {
                let v = self.eval_expr(&args[0]);
                if arg_is_float {
                    return Some(v);
                }
                let default = if name == "FLOAT" { Builtin::Real } else { Builtin::LongReal };
                let ty = self
                    .ctx
                    .sema
                    .expr_type(self.ctx.mid, call_span)
                    .unwrap_or_else(|| self.ctx.sema.types.builtin(default));
                let dst = self.fresh();
                self.push(Inst::Cast { dst, kind: CastKind::IntToFloat, val: v, ty });
                Some(dst)
            }
            _ => None,
        }
    }

    /// Ordinal bounds of a type, as (min, max).
    fn type_min_max(&self, ty: newm2_sema::types::TypeId) -> (i128, i128) {
        use Builtin::*;
        match self.ctx.sema.types.get(ty) {
            TypeKind::Builtin(b) => match b {
                Integer | LongInt | Integer64 | Adrint => (i64::MIN as i128, i64::MAX as i128),
                Integer8 => (i8::MIN as i128, i8::MAX as i128),
                Integer16 => (i16::MIN as i128, i16::MAX as i128),
                Integer32 => (i32::MIN as i128, i32::MAX as i128),
                Cardinal | LongCard | Cardinal64 | Qword | Adrcard => (0, u64::MAX as i128),
                Cardinal8 | Byte => (0, u8::MAX as i128),
                Cardinal16 | Word => (0, u16::MAX as i128),
                Cardinal32 | Dword => (0, u32::MAX as i128),
                Char => (0, 0xFFFF),
                Achar => (0, 0xFF),
                Boolean => (0, 1),
                // BITSET is the i256 bitmask: elements 0..255.
                Bitset | SysBitset => (0, 255),
                _ => (i64::MIN as i128, i64::MAX as i128),
            },
            TypeKind::Subrange { lo, hi, .. } => (*lo, *hi),
            TypeKind::Enum { values, .. } => {
                let lo = values.iter().copied().min().unwrap_or(0);
                let hi = values.iter().copied().max().unwrap_or(0);
                (lo, hi)
            }
            // MIN/MAX of a SET type range over its element (base) type.
            TypeKind::Set { base, .. } => self.type_min_max(*base),
            _ => (i64::MIN as i128, i64::MAX as i128),
        }
    }

    /// `MIN(T)` / `MAX(T)` for an ordinal type or variable — a compile-time
    /// bound, not a runtime call.
    fn lower_min_max_builtin(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        if !d.selectors.is_empty() || d.base.segments.len() != 1 || args.len() != 1 {
            return None;
        }
        let is_max = match d.base.segments[0].as_str() {
            "MAX" => true,
            "MIN" => false,
            _ => return None,
        };
        let ast::Expr::Designator(arg_d) = &args[0] else { return None };
        let ty = match self.ctx.sema.resolved_name(self.ctx.mid, arg_d.span) {
            Some(SymbolKind::Type(t)) => *t,
            _ => self.ctx.sema.designator_type(self.ctx.mid, arg_d.span)?,
        };
        // REAL / LONGREAL bounds are float constants (the largest finite
        // magnitude), not integer ordinal bounds.
        if matches!(
            self.ctx.sema.types.get(ty),
            TypeKind::Builtin(Builtin::Real | Builtin::LongReal)
        ) {
            let v = if is_max { f64::MAX } else { f64::MIN };
            let dst = self.fresh();
            self.push(Inst::Const { dst, val: ConstVal::Real(v) });
            return Some(dst);
        }
        let (lo, hi) = self.type_min_max(ty);
        let dst = self.fresh();
        self.push(Inst::Const { dst, val: ConstVal::Int(if is_max { hi } else { lo }) });
        Some(dst)
    }

    /// Signature of a procedure-typed value (procedure pointer), derived from
    /// its PROCEDURE type, so an indirect call passes VAR params by reference.
    fn proc_pointer_sig(&self, callee: &ast::Expr) -> Option<ResolvedExternSig> {
        let ty = self.ctx.sema.expr_type(self.ctx.mid, expr_span(callee))?;
        let TypeKind::Proc { params, return_ty } = self.ctx.sema.types.get(ty) else {
            return None;
        };
        let params = params
            .iter()
            .map(|p| IrParam {
                name: String::new(),
                ty: p.ty,
                is_var: p.mode == newm2_sema::types::ParamMode::Var,
            })
            .collect();
        Some(ResolvedExternSig { params, return_ty: *return_ty, import_name: None, dll_name: None, is_variadic: false })
    }

    /// `SYSTEM.ADR(x)` / `ADR(x)` — the address of a designator.
    fn lower_adr_builtin(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        let name = match d.selectors.last() {
            Some(ast::Selector::Field(n, _)) => n.as_str(),
            None => d.base.segments.last()?.as_str(),
            _ => return None,
        };
        if name != "ADR" || args.len() != 1 {
            return None;
        }
        if let ast::Expr::Designator(arg) = &args[0] {
            return Some(self.eval_lvalue(arg));
        }
        // ADR of a non-lvalue. A string literal already lowers to a pointer to
        // its interned (null-terminated) data — exactly the address ADR yields.
        // Any other rvalue is spilled to a fresh slot and its slot pointer taken.
        match &args[0] {
            ast::Expr::String(s, _) => {
                let dst = self.fresh();
                self.push(Inst::Const { dst, val: ConstVal::Str(s.value.clone()) });
                Some(dst)
            }
            ast::Expr::Char(c, _) => {
                let dst = self.fresh();
                self.push(Inst::Const { dst, val: ConstVal::Str(c.value.to_string()) });
                Some(dst)
            }
            other => {
                let ty = self
                    .ctx
                    .sema
                    .expr_type(self.ctx.mid, expr_span(other))?;
                let v = self.eval_expr(other);
                let slot = self.fresh();
                self.push(Inst::Alloca { dst: slot, ty });
                self.push(Inst::Store { ptr: slot, val: v });
                Some(slot)
            }
        }
    }

    /// `SYSTEM.THROW(i)` — raise an `M2EXCEPTION` with number `i`, catchable by
    /// an enclosing `EXCEPT`. Marked `noreturn`; a fresh dead block follows so
    /// the value-returning dispatch path stays well-formed.
    fn lower_throw_builtin(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        let name = match d.selectors.last() {
            Some(ast::Selector::Field(n, _)) => n.as_str(),
            None => d.base.segments.last()?.as_str(),
            _ => return None,
        };
        if name != "THROW" || args.len() != 1 {
            return None;
        }
        let n = self.eval_expr(&args[0]);
        let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
        let params = vec![IrParam { name: "n".into(), ty: card, is_var: false }];
        self.call_runtime("nm2_raise_m2", params, None, vec![n]);
        self.terminate(Terminator::Unreachable);
        let after = self.builder.new_block("after_throw");
        self.builder.switch_to(after);
        Some(self.emit_nil())
    }

    /// SYSTEM address arithmetic. ADDRESS is an LLVM pointer, so these convert
    /// to an integer, do the arithmetic, and convert back:
    ///   ADDADR(a,n)=a+n, SUBADR(a,n)=a-n  -> ADDRESS
    ///   DIFADR(a,b)=a-b (byte difference) -> ADRINT
    ///   MAKEADR(v,…)=v as ADDRESS
    fn lower_system_addr_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
    ) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        let name = match d.selectors.last() {
            Some(ast::Selector::Field(n, _)) => n.as_str(),
            None => d.base.segments.last()?.as_str(),
            _ => return None,
        };
        // Intermediate must be a real integer type (ADRINT/ADDRESS lower to LLVM
        // pointers); INTEGER is i64 in this build.
        let int_ty = self.ctx.sema.types.builtin(Builtin::Integer);
        let address = self.ctx.sema.types.builtin(Builtin::Address);
        match name {
            "ADDADR" | "SUBADR" if args.len() == 2 => {
                let a = self.eval_expr(&args[0]);
                let n = self.eval_expr(&args[1]);
                let ai = self.fresh();
                self.push(Inst::Cast { dst: ai, kind: CastKind::PtrToInt, val: a, ty: int_ty });
                let op = if name == "ADDADR" { BinOp::Add } else { BinOp::Sub };
                let sum = self.fresh();
                self.push(Inst::Binary { dst: sum, op, lhs: ai, rhs: n });
                let res = self.fresh();
                self.push(Inst::Cast { dst: res, kind: CastKind::IntToPtr, val: sum, ty: address });
                Some(res)
            }
            "DIFADR" if args.len() == 2 => {
                let a = self.eval_expr(&args[0]);
                let b = self.eval_expr(&args[1]);
                let ai = self.fresh();
                self.push(Inst::Cast { dst: ai, kind: CastKind::PtrToInt, val: a, ty: int_ty });
                let bi = self.fresh();
                self.push(Inst::Cast { dst: bi, kind: CastKind::PtrToInt, val: b, ty: int_ty });
                let dst = self.fresh();
                self.push(Inst::Binary { dst, op: BinOp::Sub, lhs: ai, rhs: bi });
                Some(dst)
            }
            "MAKEADR" if !args.is_empty() => {
                let v = self.eval_expr(&args[0]);
                let dst = self.fresh();
                self.push(Inst::Cast { dst, kind: CastKind::IntToPtr, val: v, ty: address });
                Some(dst)
            }
            _ => None,
        }
    }

    /// `SYSTEM.TSIZE(T)` / `SIZE(x)` — the byte size of a type or variable;
    /// `SYSTEM.TBITSIZE(T)` — its size in bits (bytes × BITSPERLOC).
    fn lower_size_builtin(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        let name = match d.selectors.last() {
            Some(ast::Selector::Field(n, _)) => n.as_str(),
            None => d.base.segments.last()?.as_str(),
            _ => return None,
        };
        if (name != "SIZE" && name != "TSIZE" && name != "TBITSIZE") || args.len() != 1 {
            return None;
        }
        let ast::Expr::Designator(arg_d) = &args[0] else { return None };
        let ty = self.resolve_size_type(arg_d)?;
        let sz = self.fresh();
        self.push(Inst::Const { dst: sz, val: ConstVal::SizeOf(ty) });
        if name == "TBITSIZE" {
            let eight = self.fresh();
            self.push(Inst::Const { dst: eight, val: ConstVal::Int(8) });
            let bits = self.fresh();
            self.push(Inst::Binary { dst: bits, op: BinOp::Mul, lhs: sz, rhs: eight });
            return Some(bits);
        }
        Some(sz)
    }

    /// Resolve the type whose size `SIZE`/`TSIZE` is asking for: either a type
    /// name (qualified or in scope) or, failing that, a value designator.
    fn resolve_size_type(&self, d: &ast::Designator) -> Option<newm2_sema::types::TypeId> {
        if let Some(SymbolKind::Type(t)) = self.ctx.sema.resolved_name(self.ctx.mid, d.span) {
            return Some(*t);
        }
        if d.selectors.is_empty()
            && d.base.segments.len() == 1
            && let Some(sym) = self.ctx.sema.scopes.lookup(self.scope, &d.base.segments[0]).cloned()
            && let SymbolKind::Type(t) = sym.kind
        {
            return Some(t);
        }
        self.ctx.sema.designator_type(self.ctx.mid, d.span)
    }

    /// Bit width of an integer/word value type, for SHIFT/ROTATE.
    fn int_bit_width(&self, ty: newm2_sema::types::TypeId) -> u32 {
        use Builtin::*;
        let ty = match self.ctx.sema.types.get(ty) {
            TypeKind::Subrange { host, .. } => *host,
            _ => ty,
        };
        match self.ctx.sema.types.get(ty) {
            TypeKind::Builtin(b) => match b {
                Byte | SysByte | Achar | Integer8 | Cardinal8 => 8,
                Char | Uchar | Integer16 | Cardinal16 | Word => 16,
                Integer32 | Cardinal32 | Dword => 32,
                _ => 64,
            },
            _ => 64,
        }
    }

    /// `SYSTEM.SHIFT(v, n)` / `SYSTEM.ROTATE(v, n)` — lowered to a runtime call
    /// carrying the value, the signed count, and the operand's bit width.
    fn lower_shift_rotate_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
    ) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        let name = match d.selectors.last() {
            Some(ast::Selector::Field(n, _)) => n.as_str(),
            None => d.base.segments.last()?.as_str(),
            _ => return None,
        };
        let rt = match name {
            "SHIFT" => "nm2_shift",
            "ROTATE" => "nm2_rotate",
            _ => return None,
        };
        if args.len() != 2 {
            return None;
        }
        let val_ty = self
            .ctx
            .sema
            .expr_type(self.ctx.mid, expr_span(&args[0]))
            .unwrap_or_else(|| self.ctx.sema.types.builtin(Builtin::Word));
        let width = self.int_bit_width(val_ty);
        let val = self.eval_expr(&args[0]);
        let count = self.eval_expr(&args[1]);
        let width_v = self.fresh();
        self.push(Inst::Const { dst: width_v, val: ConstVal::Int(width as i128) });
        let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
        let int = self.ctx.sema.types.builtin(Builtin::Integer);
        let params = vec![
            IrParam { name: "v".into(), ty: card, is_var: false },
            IrParam { name: "n".into(), ty: int, is_var: false },
            IrParam { name: "w".into(), ty: card, is_var: false },
        ];
        // A SET operand is an i256 bitmask, but the runtime helper works on an
        // i64. Request an i64 result and widen it back to the set
        // representation; the value param is likewise an i64 view of the set's
        // low bits (valid for BITSET-width sets). For an ordinary integer/word
        // operand the result type is just `val_ty`.
        let is_set = matches!(
            self.ctx.sema.types.get(val_ty),
            TypeKind::Set { .. } | TypeKind::Builtin(Builtin::Bitset | Builtin::SysBitset)
        );
        if is_set {
            let r = self.call_runtime(rt, params, Some(card), vec![val, count, width_v])?;
            let widened = self.fresh();
            self.push(Inst::Cast { dst: widened, kind: CastKind::IntZeroExt, val: r, ty: val_ty });
            return Some(widened);
        }
        // Result is masked to `width` by the runtime; the value type is `val_ty`
        // and the store coerces the i64 result to the destination width.
        self.call_runtime(rt, params, Some(val_ty), vec![val, count, width_v])
    }

    /// `SYSTEM.NEWPROCESS(P, ws, size, VAR cor)` / `SYSTEM.TRANSFER(VAR from, to)`
    /// — coroutine primitives, lowered to the fiber runtime. The PIM workspace
    /// pointer is evaluated (for side effects) but ignored; the OS manages the
    /// fiber stack.
    fn lower_coroutine_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
    ) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        let name = match d.selectors.last() {
            Some(ast::Selector::Field(n, _)) => n.as_str(),
            None => d.base.segments.last()?.as_str(),
            _ => return None,
        };
        let addr = self.ctx.sema.types.builtin(Builtin::Address);
        let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
        match name {
            // SYSTEM.NEWPROCESS(P, ws, size, VAR cor) and
            // COROUTINES.NEWCOROUTINE(P, ws, size, VAR cor [, protection]).
            "NEWPROCESS" | "NEWCOROUTINE" if args.len() == 4 || args.len() == 5 => {
                let body = self.eval_expr(&args[0]); // procedure pointer
                let _ws = self.eval_expr(&args[1]); // workspace (ignored)
                let size = self.eval_expr(&args[2]);
                let params = vec![
                    IrParam { name: "p".into(), ty: addr, is_var: false },
                    IrParam { name: "n".into(), ty: card, is_var: false },
                ];
                let handle =
                    self.call_runtime("nm2_coroutine_new", params, Some(addr), vec![body, size])?;
                if let ast::Expr::Designator(cor) = &args[3] {
                    let lval = self.eval_lvalue(cor);
                    self.push(Inst::Store { ptr: lval, val: handle });
                }
                Some(self.emit_nil())
            }
            "CURRENT" if args.is_empty() => {
                self.call_runtime("nm2_coroutine_current", vec![], Some(addr), vec![])
            }
            "TRANSFER" if args.len() == 2 => {
                let ast::Expr::Designator(fd) = &args[0] else { return None };
                let from_ptr = self.eval_lvalue(fd);
                let to = self.eval_expr(&args[1]);
                let params = vec![
                    IrParam { name: "from".into(), ty: addr, is_var: false },
                    IrParam { name: "to".into(), ty: addr, is_var: false },
                ];
                self.call_runtime("nm2_coroutine_transfer", params, None, vec![from_ptr, to]);
                Some(self.emit_nil())
            }
            _ => None,
        }
    }

    /// Virtual method dispatch: `obj.M(args)` where sema tagged `M` with a
    /// Method binding. Loads the object's vtable pointer (field 0), loads the
    /// method slot, and emits an indirect call with `obj` (SELF) prepended.
    fn try_method_dispatch(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> Option<ValueId> {
        let ast::Expr::Designator(d) = callee else { return None };
        let ast::Selector::Field(_, mspan) = d.selectors.last()? else {
            return None;
        };
        let SelectorBinding::Method { vtable_index, class, .. } =
            self.ctx.sema.selector_binding(self.ctx.mid, *mspan)?
        else {
            return None;
        };
        let (call_sig, object_record, sig) = {
            let cls = self.ctx.sema.classes.get(class);
            let slot = &cls.vtable[vtable_index as usize];
            (slot.call_sig, cls.object_record, slot.sig.clone())
        };
        let call_sig = call_sig?;
        // Receiver = the designator without its final method selector.
        let recv = ast::Designator {
            base: d.base.clone(),
            selectors: d.selectors[..d.selectors.len() - 1].to_vec(),
            span: d.span,
        };
        let obj = self.eval_designator_val(&recv);
        // Type the object pointer as the object record so field 0 (vtable) GEPs.
        let obj_typed = match object_record {
            Some(or) => {
                let t = self.fresh();
                self.push(Inst::TypedPtr { dst: t, src: obj, ty: or });
                t
            }
            None => obj,
        };
        let vptr_slot = self.fresh();
        self.push(Inst::FieldPtr { dst: vptr_slot, base: obj_typed, field: 0 });
        let vtable = self.fresh();
        self.push(Inst::Load { dst: vtable, ptr: vptr_slot });
        // Load the method function pointer from vtable[vtable_index]. The object's
        // field-0 vtable pointer points at the FIRST METHOD (for our native objects
        // the {Class}.typeinfo pointer sits one slot before it, at vtable[-1]; for
        // foreign COM objects field 0 is the COM vtable directly) — so method
        // dispatch is a plain [vtable_index] for both, unchanged.
        let addr = self.ctx.sema.types.builtin(Builtin::Address);
        let idx = self.fresh();
        self.push(Inst::Const { dst: idx, val: ConstVal::Int(vtable_index as i128) });
        let slot_addr = self.fresh();
        self.push(Inst::IndexPtr { dst: slot_addr, base: vtable, index: idx, elem_ty: addr });
        let fnptr = self.fresh();
        self.push(Inst::Load { dst: fnptr, ptr: slot_addr });
        // SELF first, then the declared arguments (VAR by reference).
        let mut arg_vals = vec![obj];
        for (i, a) in args.iter().enumerate() {
            let is_var = sig
                .params
                .get(i)
                .map(|p| p.mode == newm2_sema::types::ParamMode::Var)
                .unwrap_or(false);
            if is_var {
                if let ast::Expr::Designator(dd) = a {
                    arg_vals.push(self.eval_lvalue(dd));
                    continue;
                }
            }
            arg_vals.push(self.eval_expr(a));
        }
        let dst = self.fresh();
        self.push(Inst::IndCall { dst: Some(dst), callee: fnptr, sig: call_sig, args: arg_vals });
        Some(dst)
    }

    fn eval_call(&mut self, callee: &ast::Expr, args: &[ast::Expr], call_span: Span) -> ValueId {
        if let Some(dst) = self.try_method_dispatch(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_coroutine_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_size_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_shift_rotate_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_adr_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_system_addr_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_throw_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_transfer_builtin(callee, args, call_span) {
            return dst;
        }
        if let Some(dst) = self.lower_min_max_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_high_len_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_length_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_abs_int_builtin(callee, args, call_span) {
            return dst;
        }
        if let Some(dst) = self.lower_ord_chr_builtin(callee, args, call_span) {
            return dst;
        }
        if let Some(dst) = self.lower_odd_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_ismember_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_hresult_test_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_cmplx_builtin(callee, args, call_span) {
            return dst;
        }
        if let Some(dst) = self.lower_re_im_builtin(callee, args) {
            return dst;
        }
        if let Some(dst) = self.lower_type_conversion(callee, args, call_span) {
            return dst;
        }
        // Resolve the proc symbol's (defining-module-qualified) name once and
        // use it for both the callee reference and its signature, so the call
        // binds to the qualified definition (`Module.Proc`) rather than a bare,
        // unbound declaration.
        let proc_name = match callee {
            ast::Expr::Designator(d) => self.designator_proc_name(d),
            _ => None,
        };
        let sig = proc_name
            .as_ref()
            .and_then(|name| self.resolve_proc_signature(name))
            // Indirect call through a procedure-typed value (procedure pointer):
            // take the signature from the value's PROCEDURE type so VAR params
            // are passed by reference.
            .or_else(|| self.proc_pointer_sig(callee));
        let callee_val = match &proc_name {
            Some(name) => self.resolve_name_as_value(name),
            None => self.eval_expr(callee),
        };
        // Foreign C-ABI callees (EXTERNAL FROM "dll") take a bare pointer for
        // open-array params; native callees take a (ptr, HIGH) pair.
        let callee_is_dll = sig.as_ref().and_then(|s| s.dll_name.as_ref()).is_some();
        let mut arg_vals: Vec<ValueId> = Vec::with_capacity(args.len());
        for (index, arg) in args.iter().enumerate() {
            let formal = sig.as_ref().and_then(|s| s.params.get(index));
            let is_var = formal.map(|p| p.is_var).unwrap_or(false);
            let formal_open = formal
                .map(|p| is_open_array_ty(self.ctx.sema, p.ty))
                .unwrap_or(false);
            if formal_open {
                // A string CONST (e.g. `CONST msg = "..."`) passed where an
                // ARRAY OF CHAR is expected: materialise its interned data
                // pointer + static HIGH, since it has no lvalue address.
                if let ast::Expr::Designator(d) = arg
                    && let Some(s) = self.const_string_value(d)
                {
                    let ptr = self.fresh();
                    self.push(Inst::Const { dst: ptr, val: ConstVal::Str(s.clone()) });
                    arg_vals.push(ptr);
                    if !callee_is_dll {
                        let high = self.fresh();
                        let h = (s.chars().count() as i128 - 1).max(0);
                        self.push(Inst::Const { dst: high, val: ConstVal::Int(h) });
                        arg_vals.push(high);
                    }
                    continue;
                }
                // Pass the data pointer: a designator's address (eval_lvalue
                // gives &array[0] for a fixed array, and the data pointer for a
                // forwarded open-array param via its Indirect slot); a string
                // literal evaluates to its constant pointer.
                let ptr_arg = match arg {
                    ast::Expr::Designator(d) => self.eval_lvalue(d),
                    // A single-character literal passed where an ARRAY OF CHAR
                    // is expected is a length-1 string: materialise it as a
                    // (wide) string constant so the data-pointer ABI holds.
                    ast::Expr::Char(c, _) => {
                        let dst = self.fresh();
                        self.push(Inst::Const {
                            dst,
                            val: ConstVal::Str(c.value.to_string()),
                        });
                        dst
                    }
                    _ => {
                        let v = self.eval_expr(arg);
                        // An array *value* r-value — a function call returning a
                        // fixed ARRAY by value, or an aggregate constructor like
                        // `Vector{1.0, 2.0, 3.0}` — must be spilled to a slot so
                        // the open-array ABI receives a data pointer. String
                        // r-values already evaluate to a pointer and are excluded.
                        if !self.is_string_rvalue(arg)
                            && let Some(ty) = self.ctx.sema.expr_type(self.ctx.mid, expr_span(arg))
                            && matches!(self.ctx.sema.types.get(ty), TypeKind::Array { .. })
                        {
                            let slot = self.fresh();
                            self.push(Inst::Alloca { dst: slot, ty });
                            self.push(Inst::Store { ptr: slot, val: v });
                            slot
                        } else {
                            v
                        }
                    }
                };
                arg_vals.push(ptr_arg);
                if !callee_is_dll {
                    // A LOC-view formal (`ARRAY OF BYTE/WORD/LOC`) sizes the
                    // actual by its storage; everything else uses array HIGH.
                    let high = formal
                        .map(|p| p.ty)
                        .and_then(|t| self.byte_view_high(arg, t))
                        .unwrap_or_else(|| self.eval_actual_high(arg));
                    arg_vals.push(high);
                }
                continue;
            }
            if is_var {
                if let ast::Expr::Designator(d) = arg {
                    arg_vals.push(self.eval_lvalue(d));
                    continue;
                }
            }
            // A string/char literal passed by value to a *fixed* ARRAY OF CHAR
            // parameter: the formal is `[N x CHAR]` by value, so copy the
            // characters into an array-valued temporary and pass the loaded
            // array, not the string pointer's bits or a bare char (arraychar).
            if !is_var
                && let Some(fty) = formal.map(|p| p.ty)
                && let Some(count) = self.array_char_count(fty)
                && (self.is_string_rvalue(arg) || matches!(arg, ast::Expr::Char(..)))
            {
                let src = match arg {
                    ast::Expr::Char(c, _) => {
                        let dst = self.fresh();
                        self.push(Inst::Const {
                            dst,
                            val: ConstVal::Str(c.value.to_string()),
                        });
                        dst
                    }
                    _ => self.eval_expr(arg),
                };
                let slot = self.fresh();
                self.push(Inst::Alloca { dst: slot, ty: fty });
                let cap = self.fresh();
                self.push(Inst::Const { dst: cap, val: ConstVal::Int(count) });
                let addr = self.ctx.addr_ty();
                let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
                let params = vec![
                    IrParam { name: "src".into(), ty: addr, is_var: false },
                    IrParam { name: "dst".into(), ty: addr, is_var: false },
                    IrParam { name: "cap".into(), ty: card, is_var: false },
                ];
                self.call_runtime("NM2Str.WCopy", params, None, vec![src, slot, cap]);
                let out = self.fresh();
                self.push(Inst::Load { dst: out, ptr: slot });
                arg_vals.push(out);
                continue;
            }
            arg_vals.push(self.eval_expr(arg));
        }
        // Pass the addresses of any captured variables as hidden trailing
        // arguments when calling a capturing nested procedure.
        if let Some(name) = &proc_name {
            let qn = name.segments.join(".");
            if let Some(caps) = self.ctx.captures.get(&qn).cloned() {
                for cap in &caps {
                    let addr = self.capture_address(&cap.name);
                    arg_vals.push(addr);
                    if is_open_array_ty(self.ctx.sema, cap.ty) {
                        let high = self.capture_high(&cap.name);
                        arg_vals.push(high);
                    }
                }
            }
        }
        let dst = self.fresh();
        // An indirect call through a procedure-pointer value (no resolved proc
        // name) must carry the PROCEDURE type so codegen builds the correct
        // call ABI (VAR params by reference, open-array HIGH companions).
        if proc_name.is_none()
            && let Some(sig_ty) = self.ctx.sema.expr_type(self.ctx.mid, expr_span(callee))
            && matches!(self.ctx.sema.types.get(sig_ty), TypeKind::Proc { .. })
        {
            self.push(Inst::IndCall { dst: Some(dst), callee: callee_val, sig: sig_ty, args: arg_vals });
            return dst;
        }
        self.push(Inst::Call { dst: Some(dst), callee: callee_val, args: arg_vals });
        dst
    }

    /// HIGH companion of an open-array capture in the current frame: the value
    /// of its `{name}$high` slot.
    fn capture_high(&mut self, name: &str) -> ValueId {
        let hname = open_array_high_name(name);
        if let Some(b) = self.locals.get(hname.as_str()).copied() {
            let ptr = self.local_ptr(b);
            let dst = self.fresh();
            self.push(Inst::Load { dst, ptr });
            return dst;
        }
        let dst = self.fresh();
        self.push(Inst::Const { dst, val: ConstVal::Int(0) });
        dst
    }

    /// If `d`'s declared type is a fixed `ARRAY OF` *wide* `CHAR`
    /// (`CHAR`/`UCHAR`, not the narrow `ACHAR`/`BYTE` storage units), return its
    /// element count. Used to drive a character copy on `arr := "literal"`.
    fn wide_char_array_count(&self, d: &ast::Designator) -> Option<i128> {
        let ty = self.ctx.sema.designator_type(self.ctx.mid, d.span)?;
        self.array_char_count(ty)
    }

    /// Element count of a fixed single-dimension `ARRAY OF` wide `CHAR` type,
    /// else `None`.
    fn array_char_count(&self, ty: newm2_sema::types::TypeId) -> Option<i128> {
        match self.ctx.sema.types.get(ty) {
            TypeKind::Array { indices, base } if indices.len() == 1 => {
                match self.ctx.sema.types.get(*base) {
                    TypeKind::Builtin(Builtin::Char | Builtin::Uchar) => {
                        Some(self.dim_count(indices[0]))
                    }
                    _ => None,
                }
            }
            _ => None,
        }
    }

    /// Element count of a fixed single-dimension `ARRAY OF` narrow `ACHAR`
    /// (8-bit) type, else `None`. The mirror of [`array_char_count`] for the
    /// narrow string model.
    fn narrow_char_array_count(&self, d: &ast::Designator) -> Option<i128> {
        let ty = self.ctx.sema.designator_type(self.ctx.mid, d.span)?;
        match self.ctx.sema.types.get(ty) {
            TypeKind::Array { indices, base } if indices.len() == 1 => {
                match self.ctx.sema.types.get(*base) {
                    TypeKind::Builtin(Builtin::Achar) => Some(self.dim_count(indices[0])),
                    _ => None,
                }
            }
            _ => None,
        }
    }

    /// Fold a constant string/char concatenation expression to its string
    /// value: a char literal, a string literal, a string CONST, or an `Add`
    /// chain of those. Returns `None` for anything with a runtime operand.
    fn fold_string_concat(&self, e: &ast::Expr) -> Option<String> {
        match e {
            ast::Expr::Char(c, _) => Some(c.value.to_string()),
            ast::Expr::String(s, _) => Some(s.value.clone()),
            ast::Expr::Binary(ast::BinaryOp::Add, l, r, _) => {
                let mut s = self.fold_string_concat(l)?;
                s.push_str(&self.fold_string_concat(r)?);
                Some(s)
            }
            ast::Expr::Designator(d) => self.const_string_value(d),
            _ => None,
        }
    }

    /// True when `value` is a string r-value that lowers to a *pointer* to its
    /// data (a string literal or a string CONST) — as opposed to an array
    /// variable, which lowers to a loaded array value.
    fn is_string_rvalue(&self, value: &ast::Expr) -> bool {
        match value {
            ast::Expr::String(_, _) => true,
            ast::Expr::Designator(d) => self.const_string_value(d).is_some(),
            _ => false,
        }
    }

    /// If `d` names a string CONST (`CONST s = "..."`), return its value.
    fn const_string_value(&self, d: &ast::Designator) -> Option<String> {
        let kind = if d.selectors.is_empty() && d.base.segments.len() == 1 {
            self.ctx.sema.scopes.lookup(self.scope, &d.base.segments[0]).map(|s| s.kind.clone())
        } else {
            self.designator_module_member(d).and_then(|(_, _, kind, consumed)| {
                (consumed == d.selectors.len()).then_some(kind)
            })
        }?;
        match kind {
            SymbolKind::Const { value: newm2_sema::ConstValue::Str(s), .. } => Some(s),
            _ => None,
        }
    }

    /// Address of a captured variable in the *current* frame: a local's alloca,
    /// or the reference held by an inherited capture / VAR-param slot. A capture
    /// is, by construction, always an enclosing local — so it is in `locals`.
    fn capture_address(&mut self, name: &str) -> ValueId {
        if let Some(b) = self.locals.get(name).copied() {
            return self.local_ptr(b);
        }
        self.emit_nil()
    }

    /// Compute the HIGH bound to pass as an open-array argument's companion:
    /// string literal → len-1; forwarded open-array param → load its `$high`
    /// slot; fixed array → static upper bound; otherwise 0.
    /// HIGH for an actual passed to a LOC-view open array (`ARRAY OF
    /// BYTE/WORD/LOC`), which is a raw storage view: the actual occupies
    /// `SIZE(actual) / SIZE(element) - 1`. Returns `None` when the formal is
    /// not a LOC-view open array (use the ordinary `eval_actual_high`).
    fn byte_view_high(&mut self, arg: &ast::Expr, formal_ty: newm2_sema::types::TypeId) -> Option<ValueId> {
        let TypeKind::OpenArray { base } = self.ctx.sema.types.get(formal_ty) else {
            return None;
        };
        let base = *base;
        let is_loc = matches!(
            self.ctx.sema.types.get(base),
            TypeKind::Builtin(
                Builtin::Byte
                    | Builtin::SysByte
                    | Builtin::Word
                    | Builtin::SysWord
                    | Builtin::SysLoc
            )
        );
        if !is_loc {
            return None;
        }
        let actual_ty = self
            .ctx
            .sema
            .designator_type(self.ctx.mid, expr_span(arg))
            .or_else(|| self.ctx.sema.expr_type(self.ctx.mid, expr_span(arg)))?;
        let sz_a = self.fresh();
        self.push(Inst::Const { dst: sz_a, val: ConstVal::SizeOf(actual_ty) });
        let sz_e = self.fresh();
        self.push(Inst::Const { dst: sz_e, val: ConstVal::SizeOf(base) });
        let quot = self.fresh();
        self.push(Inst::Binary { dst: quot, op: BinOp::Quot, lhs: sz_a, rhs: sz_e });
        let one = self.fresh();
        self.push(Inst::Const { dst: one, val: ConstVal::Int(1) });
        let high = self.fresh();
        self.push(Inst::Binary { dst: high, op: BinOp::Sub, lhs: quot, rhs: one });
        Some(high)
    }

    fn eval_actual_high(&mut self, arg: &ast::Expr) -> ValueId {
        if let ast::Expr::String(lit, _) = arg {
            let high = (lit.value.chars().count() as i128 - 1).max(0);
            let dst = self.fresh();
            self.push(Inst::Const { dst, val: ConstVal::Int(high) });
            return dst;
        }
        if let ast::Expr::Designator(d) = arg {
            if d.selectors.is_empty() && d.base.segments.len() == 1 {
                let hname = open_array_high_name(&d.base.segments[0]);
                if let Some(binding) = self.locals.get(hname.as_str()).copied() {
                    let ptr = self.local_ptr(binding);
                    let dst = self.fresh();
                    self.push(Inst::Load { dst, ptr });
                    return dst;
                }
            }
            if let Some(bound) = self.fixed_array_high(d) {
                let dst = self.fresh();
                self.push(Inst::Const { dst, val: ConstVal::Int(bound) });
                return dst;
            }
        }
        // Any other expression typed as a fixed array (e.g. a function returning
        // ARRAY OF CHAR by value): HIGH is its element count − 1.
        if let Some(ty) = self.ctx.sema.expr_type(self.ctx.mid, expr_span(arg))
            && let TypeKind::Array { indices, .. } = self.ctx.sema.types.get(ty)
            && let Some(first) = indices.first()
        {
            let count = self.dim_count(*first);
            let dst = self.fresh();
            self.push(Inst::Const { dst, val: ConstVal::Int((count - 1).max(0)) });
            return dst;
        }
        // A constant char/string concatenation (`'a' + 'b'`, `015C + 012C`):
        // HIGH is the folded length − 1, matching the string the lowering emits.
        if let Some(s) = self.fold_string_concat(arg) {
            let high = (s.chars().count() as i128 - 1).max(0);
            let dst = self.fresh();
            self.push(Inst::Const { dst, val: ConstVal::Int(high) });
            return dst;
        }
        let dst = self.fresh();
        self.push(Inst::Const { dst, val: ConstVal::Int(0) });
        dst
    }

    /// Static HIGH (element-count − 1) of a fixed-array designator, if known.
    fn fixed_array_high(&self, d: &ast::Designator) -> Option<i128> {
        let ty = if d.selectors.is_empty() && d.base.segments.len() == 1 {
            self.locals.get(&d.base.segments[0]).map(|b| b.ty)
        } else {
            None
        }
        .or_else(|| self.ctx.sema.designator_type(self.ctx.mid, d.span))?;
        if let TypeKind::Array { indices, .. } = self.ctx.sema.types.get(ty) {
            if let Some(first) = indices.first() {
                if let TypeKind::Subrange { lo, hi, .. } = self.ctx.sema.types.get(*first) {
                    return Some((*hi - *lo) as i128);
                }
            }
        }
        None
    }

    /// Lower `HIGH(a)` / `LEN(a)` directly (reads the open-array `$high`
    /// companion or a fixed array's static bound). Returns None for any other
    /// call so normal call lowering proceeds.
    fn lower_high_len_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
    ) -> Option<ValueId> {
        let ast::Expr::Designator(c) = callee else { return None };
        if !c.selectors.is_empty() || c.base.segments.len() != 1 {
            return None;
        }
        let name = c.base.segments[0].as_str();
        if (name != "HIGH" && name != "LEN") || args.len() != 1 {
            return None;
        }
        if !matches!(&args[0], ast::Expr::Designator(_)) {
            return None;
        }
        let high = self.eval_actual_high(&args[0]);
        if name == "HIGH" {
            return Some(high);
        }
        // LEN = HIGH + 1
        let one = self.fresh();
        self.push(Inst::Const { dst: one, val: ConstVal::Int(1) });
        let dst = self.fresh();
        self.push(Inst::Binary { dst, op: BinOp::Add, lhs: high, rhs: one });
        Some(dst)
    }

    /// Lower the ISO pervasive `LENGTH(s)`: the count of characters in the
    /// string `s` up to (not including) the first NUL, bounded by the array's
    /// HIGH. Backed by a runtime scan (wide for CHAR, narrow for ACHAR/BYTE).
    fn lower_length_builtin(
        &mut self,
        callee: &ast::Expr,
        args: &[ast::Expr],
    ) -> Option<ValueId> {
        let ast::Expr::Designator(c) = callee else { return None };
        if !c.selectors.is_empty() || c.base.segments.len() != 1 {
            return None;
        }
        if c.base.segments[0] != "LENGTH" || args.len() != 1 {
            return None;
        }
        // A string literal's length is statically known.
        if let ast::Expr::String(lit, _) = &args[0] {
            let dst = self.fresh();
            self.push(Inst::Const { dst, val: ConstVal::Int(lit.value.chars().count() as i128) });
            return Some(dst);
        }
        let ptr = match &args[0] {
            ast::Expr::Designator(d) => self.eval_lvalue(d),
            other => self.eval_expr(other),
        };
        let high = self.eval_actual_high(&args[0]);
        let name = if self.length_elem_is_wide(&args[0]) {
            "NM2Str.WLength"
        } else {
            "NM2Str.Length"
        };
        let addr = self.ctx.addr_ty();
        let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
        let params = vec![
            IrParam { name: "p".into(), ty: addr, is_var: false },
            IrParam { name: "high".into(), ty: card, is_var: false },
        ];
        self.call_runtime(name, params, Some(card), vec![ptr, high])
    }

    /// True when the character element of a `LENGTH` argument is the wide
    /// `CHAR`/`UCHAR` cell (the default) rather than narrow `ACHAR`/`BYTE`.
    fn length_elem_is_wide(&self, arg: &ast::Expr) -> bool {
        let ty = match arg {
            ast::Expr::Designator(d) => {
                if d.selectors.is_empty() && d.base.segments.len() == 1 {
                    self.locals.get(&d.base.segments[0]).map(|b| b.ty)
                } else {
                    None
                }
                .or_else(|| self.ctx.sema.designator_type(self.ctx.mid, d.span))
            }
            _ => self.ctx.sema.expr_type(self.ctx.mid, expr_span(arg)),
        };
        let Some(ty) = ty else { return true };
        let elem = match self.ctx.sema.types.get(ty) {
            TypeKind::Array { base, .. } | TypeKind::OpenArray { base } => *base,
            _ => return true,
        };
        !matches!(
            self.ctx.sema.types.get(elem),
            TypeKind::Builtin(Builtin::Achar) | TypeKind::Builtin(Builtin::Byte)
        )
    }

    /// Lower the pervasive control builtins `ASSERT(cond[, code])` and `HALT`.
    /// Returns `true` when handled so statement lowering stops.
    fn lower_assert_halt(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> bool {
        let ast::Expr::Designator(d) = callee else { return false };
        if !d.selectors.is_empty() || d.base.segments.len() != 1 {
            return false;
        }
        match d.base.segments[0].as_str() {
            "ASSERT" if !args.is_empty() => {
                let cond = self.eval_expr(&args[0]);
                let fail = self.builder.new_block("assert_fail");
                let cont = self.builder.new_block("assert_cont");
                self.terminate(Terminator::CondBr { cond, t_block: cont, f_block: fail });
                self.builder.switch_to(fail);
                let msg = self.fresh();
                self.push(Inst::Const { dst: msg, val: ConstVal::Str(String::new()) });
                let high = self.fresh();
                self.push(Inst::Const { dst: high, val: ConstVal::Int(0) });
                let addr = self.ctx.addr_ty();
                let card = self.ctx.sema.types.builtin(Builtin::Cardinal);
                let params = vec![
                    IrParam { name: "m".into(), ty: addr, is_var: false },
                    IrParam { name: "h".into(), ty: card, is_var: false },
                ];
                self.call_runtime("nm2_assert_failed", params, None, vec![msg, high]);
                self.terminate(Terminator::Unreachable);
                self.builder.switch_to(cont);
                true
            }
            "HALT" => {
                // HALT records the halt and unwinds to the JIT entry boundary,
                // which runs module finalizers (TERMINATION.HasHalted/
                // IsTerminating observe it) then exits — not an abort. The
                // process exit status is HALT's optional argument; bare HALT is
                // abnormal termination and defaults to 1 (exit(1)).
                let code = match args.first() {
                    Some(arg) => self.eval_expr(arg),
                    None => {
                        let one = self.fresh();
                        self.push(Inst::Const { dst: one, val: ConstVal::Int(1) });
                        one
                    }
                };
                let int_ty = self.ctx.sema.types.builtin(Builtin::Integer);
                let params = vec![IrParam { name: "code".into(), ty: int_ty, is_var: false }];
                self.call_runtime("nm2_halt", params, None, vec![code]);
                self.terminate(Terminator::Unreachable);
                let after = self.builder.new_block("after_halt");
                self.builder.switch_to(after);
                true
            }
            _ => false,
        }
    }

    /// Lower the in-place pervasive builtins `INC(v[,n])`, `DEC(v[,n])` and
    /// `DISPOSE(p)`. Returns `true` when handled so statement lowering stops.
    fn lower_inc_dec_dispose(&mut self, callee: &ast::Expr, args: &[ast::Expr]) -> bool {
        let ast::Expr::Designator(c) = callee else { return false };
        if !c.selectors.is_empty() || c.base.segments.len() != 1 {
            return false;
        }
        let name = c.base.segments[0].as_str();
        match name {
            "INC" | "DEC" => {
                let Some(ast::Expr::Designator(target)) = args.first() else {
                    return false;
                };
                let ptr = self.eval_lvalue(target);
                let cur = self.fresh();
                self.push(Inst::Load { dst: cur, ptr });
                let mut delta = match args.get(1) {
                    Some(step) => self.eval_expr(step),
                    None => {
                        let one = self.fresh();
                        self.push(Inst::Const { dst: one, val: ConstVal::Int(1) });
                        one
                    }
                };
                // INC/DEC on a typed POINTER advances by whole elements: scale
                // the step by sizeof(pointee), matching C-style pointer
                // arithmetic. Untyped ADDRESS has no pointee and
                // advances byte-wise, unscaled.
                if let Some(pointee) = self
                    .ctx
                    .sema
                    .designator_type(self.ctx.mid, target.span)
                    .and_then(|ty| match self.ctx.sema.types.get(ty) {
                        TypeKind::Pointer { base } => Some(*base),
                        _ => None,
                    })
                {
                    let sz = self.fresh();
                    self.push(Inst::Const { dst: sz, val: ConstVal::SizeOf(pointee) });
                    let scaled = self.fresh();
                    self.push(Inst::Binary { dst: scaled, op: BinOp::Mul, lhs: delta, rhs: sz });
                    delta = scaled;
                }
                let op = if name == "INC" { BinOp::Add } else { BinOp::Sub };
                let res = self.fresh();
                self.push(Inst::Binary { dst: res, op, lhs: cur, rhs: delta });
                self.push(Inst::Store { ptr, val: res });
                true
            }
            "INCL" | "EXCL" => {
                // In-place set update: INCL(s, e) → s := s + {e};
                //                      EXCL(s, e) → s := s - {e}.
                let Some(ast::Expr::Designator(target)) = args.first() else {
                    return false;
                };
                let Some(elem_expr) = args.get(1) else {
                    return false;
                };
                let set_ty = self
                    .ctx
                    .sema
                    .designator_type(self.ctx.mid, target.span)
                    .unwrap_or_else(|| self.ctx.sema.types.builtin(Builtin::Bitset));
                let ptr = self.eval_lvalue(target);
                let cur = self.fresh();
                self.push(Inst::Load { dst: cur, ptr });
                // mask = 1 << elem, in the set's width.
                let widen = |this: &mut Self, raw: ValueId| -> ValueId {
                    let d = this.fresh();
                    this.push(Inst::Cast { dst: d, kind: CastKind::IntZeroExt, val: raw, ty: set_ty });
                    d
                };
                let elem_raw = self.eval_expr(elem_expr);
                let elem_w = widen(self, elem_raw);
                let one_c = self.fresh();
                self.push(Inst::Const { dst: one_c, val: ConstVal::Int(1) });
                let one_w = widen(self, one_c);
                let mask = self.fresh();
                self.push(Inst::Binary { dst: mask, op: BinOp::Shl, lhs: one_w, rhs: elem_w });
                let res = self.fresh();
                if name == "INCL" {
                    self.push(Inst::Binary { dst: res, op: BinOp::BitOr, lhs: cur, rhs: mask });
                } else {
                    // EXCL: cur AND NOT mask (NOT via XOR with all-ones).
                    let neg1 = self.fresh();
                    self.push(Inst::Const { dst: neg1, val: ConstVal::Int(-1) });
                    let ones = self.fresh();
                    self.push(Inst::Cast { dst: ones, kind: CastKind::IntSignExt, val: neg1, ty: set_ty });
                    let notmask = self.fresh();
                    self.push(Inst::Binary { dst: notmask, op: BinOp::BitXor, lhs: mask, rhs: ones });
                    self.push(Inst::Binary { dst: res, op: BinOp::BitAnd, lhs: cur, rhs: notmask });
                }
                self.push(Inst::Store { ptr, val: res });
                true
            }
            // DISPOSE(p) frees a pointer; DESTROY(obj) frees a class instance —
            // both deallocate the heap object and null the reference.
            "DISPOSE" | "DESTROY" => {
                let Some(ast::Expr::Designator(target)) = args.first() else {
                    return false;
                };
                let ptr = self.eval_designator_val(target);
                self.push(Inst::Deallocate { ptr });
                let lval = self.eval_lvalue(target);
                let nil = self.emit_nil();
                self.push(Inst::Store { ptr: lval, val: nil });
                true
            }
            _ => false,
        }
    }

    /// Evaluate a designator as a value (load from address if variable).
    fn eval_designator_val(&mut self, d: &ast::Designator) -> ValueId {
        // SIMD lane read `v[i]`: a vector is a register value, not per-lane
        // addressable, so load the whole vector and extractelement.
        if let Some(v) = self.try_vector_lane_read(d) {
            return v;
        }
        // WITH field read: GEP off the captured WITH base, then load.
        if let Some(ptr) = self.with_field_ptr(d) {
            let dst = self.fresh();
            self.push(Inst::Load { dst, ptr });
            return dst;
        }
        // Fast path for unqualified names with no selectors.
        if d.selectors.is_empty() {
            if let [n] = d.base.segments.as_slice() {
                // Built-in constants.
                match n.as_str() {
                    "TRUE" => {
                        let r = self.fresh();
                        self.push(Inst::Const { dst: r, val: ConstVal::Bool(true) });
                        return r;
                    }
                    "FALSE" => {
                        let r = self.fresh();
                        self.push(Inst::Const { dst: r, val: ConstVal::Bool(false) });
                        return r;
                    }
                    // NIL and EMPTY (the null class reference) are both null.
                    "NIL" | "EMPTY" => return self.emit_nil(),
                    _ => {}
                }
                // Local variable → load.
                if let Some(binding) = self.locals.get(n.as_str()).copied() {
                    let ptr = self.local_ptr(binding);
                    let dst = self.fresh();
                    self.push(Inst::Load { dst, ptr });
                    return dst;
                }
                if let Some(ptr) = self.lookup_module_static(&d.base) {
                    let dst = self.fresh();
                    self.push(Inst::Load { dst, ptr });
                    return dst;
                }
                // Sema scope lookup — may be a Var or Const.
                let sym = self
                    .ctx
                    .sema
                    .scopes
                    .lookup(self.scope, n)
                    .cloned();
                if let Some(sym) = sym {
                    match sym.kind {
                        SymbolKind::Var { ty, .. } => {
                            let ptr = self.fresh();
                            self.push(Inst::Alloca { dst: ptr, ty });
                            self.locals.insert(
                                n.clone(),
                                Binding { storage: ptr, ty, kind: BindingKind::Direct },
                            );
                            let dst = self.fresh();
                            self.push(Inst::Load { dst, ptr });
                            return dst;
                        }
                        SymbolKind::Const { value, ty } => {
                            return self.emit_const_value(&value, ty);
                        }
                        SymbolKind::EnumMember { ord, .. } => {
                            let dst = self.fresh();
                            self.push(Inst::Const { dst, val: ConstVal::Int(ord) });
                            return dst;
                        }
                        _ => {}
                    }
                }
            }
        }

        if let Some((module_name, member, kind, consumed)) = self.designator_module_member(d)
            && consumed == d.selectors.len()
        {
            match kind {
                SymbolKind::Var { ty, .. } => {
                    let ptr = self.emit_global_ref(self.module_static_name(&module_name, &member), ty);
                    let dst = self.fresh();
                    self.push(Inst::Load { dst, ptr });
                    return dst;
                }
                SymbolKind::Const { value, ty } => {
                    return self.emit_const_value(&value, ty);
                }
                SymbolKind::EnumMember { ord, .. } => {
                    let dst = self.fresh();
                    self.push(Inst::Const { dst, val: ConstVal::Int(ord) });
                    return dst;
                }
                _ => {}
            }
        }

        // General case: evaluate as lvalue then load (or return func ref).
        if d.selectors.is_empty() {
            // A procedure used as a value (procedure pointer) must resolve to
            // its defining-module-qualified name so the FuncRef matches the
            // qualified definition (e.g. `next := Inv` → `WholeConv.Inv`).
            if let Some(proc_name) = self.designator_proc_name(d) {
                return self.resolve_name_as_value(&proc_name);
            }
            // Pure name — likely a function reference or module-qualified name.
            return self.resolve_name_as_value(&d.base);
        }

        if let Some(proc_name) = self.designator_proc_name(d) {
            return self.resolve_name_as_value(&proc_name);
        }

        // Name with selectors: get base pointer, apply selectors, load.
        let ptr = self.eval_lvalue(d);
        let dst = self.fresh();
        self.push(Inst::Load { dst, ptr });
        dst
    }

    /// Evaluate a designator as an lvalue (return its address).
    fn eval_lvalue(&mut self, d: &ast::Designator) -> ValueId {
        if let Some(ptr) = self.with_field_ptr(d) {
            return ptr;
        }
        if let Some((module_name, member, SymbolKind::Var { ty, .. }, consumed)) =
            self.designator_module_member(d)
        {
            let mut ptr = self.emit_global_ref(self.module_static_name(&module_name, &member), ty);
            let mut current_ty = Some(ty);
            for sel in &d.selectors[consumed..] {
                ptr = self.apply_selector(ptr, current_ty, sel);
                current_ty = current_ty.and_then(|current| self.selector_result_type(current, sel));
            }
            return ptr;
        }

        let mut ptr = self.eval_base_ptr(&d.base);
        let mut current_ty = self.resolve_name_type(&d.base);
        for sel in &d.selectors {
            ptr = self.apply_selector(ptr, current_ty, sel);
            current_ty = current_ty.and_then(|ty| self.selector_result_type(ty, sel));
        }
        ptr
    }

    fn designator_module_member(
        &self,
        d: &ast::Designator,
    ) -> Option<(String, String, SymbolKind, usize)> {
        let [module_name] = d.base.segments.as_slice() else {
            return None;
        };
        if !matches!(self.ctx.sema.resolved_name(self.ctx.mid, d.base.span), Some(SymbolKind::Module(..))) {
            return None;
        }
        let Some(ast::Selector::Field(member, span)) = d.selectors.first() else {
            return None;
        };
        let kind = self.ctx.sema.resolved_name(self.ctx.mid, *span)?.clone();

        Some((module_name.clone(), member.clone(), kind, 1))
    }

    /// Get the base address for a (possibly qualified) name.
    fn eval_base_ptr(&mut self, name: &ast::QualName) -> ValueId {
        if let [n] = name.segments.as_slice() {
            // Local variable → already Alloca'd.
            if let Some(binding) = self.locals.get(n.as_str()).copied() {
                return self.local_ptr(binding);
            }
            if let Some(ptr) = self.lookup_module_static(name) {
                return ptr;
            }
            // Look up in sema scope.
            let sym = self.ctx.sema.scopes.lookup(self.scope, n).cloned();
            if let Some(sym) = sym {
                if let SymbolKind::Var { ty, .. } = sym.kind {
                    let ptr = self.fresh();
                    self.push(Inst::Alloca { dst: ptr, ty });
                    self.locals.insert(
                        n.clone(),
                        Binding { storage: ptr, ty, kind: BindingKind::Direct },
                    );
                    return ptr;
                }
                // A RECORD/ARRAY constant used as an lvalue (`vecConst[i]`,
                // `recConst.field`) has no storage of its own — materialise its
                // value into a fresh slot and index that.
                if let SymbolKind::Const { ty, value } = &sym.kind
                    && matches!(value, newm2_sema::ConstValue::Aggregate(_))
                {
                    let ty = *ty;
                    let value = value.clone();
                    let val = self.emit_const_value(&value, ty);
                    let ptr = self.fresh();
                    self.push(Inst::Alloca { dst: ptr, ty });
                    self.push(Inst::Store { ptr, val });
                    return ptr;
                }
            }
        }
        if let Some(ptr) = self.lookup_module_static(name) {
            return ptr;
        }
        // Fallback: emit a FuncRef (handles qualified proc names used as lvalues
        // in e.g. `SomeModule.SomeProc(...)` — the callee expression path).
        self.resolve_name_as_value(name)
    }

    /// If `base_ty` is a class (a reference type), load `base` (the address of
    /// the reference) to obtain the object pointer and annotate it with the
    /// object-record layout, so a following field GEP indexes the heap object.
    /// Any other base type is returned unchanged.
    fn deref_class_base(&mut self, base: ValueId, base_ty: Option<newm2_sema::TypeId>) -> ValueId {
        let Some(bt) = base_ty else { return base };
        let obj_rec = match self.ctx.sema.types.get(bt) {
            TypeKind::Class { symbol } => {
                self.ctx.sema.classes.get(ClassSymbolId(*symbol)).object_record
            }
            _ => return base,
        };
        let loaded = self.fresh();
        self.push(Inst::Load { dst: loaded, ptr: base });
        match obj_rec {
            Some(or) => {
                let typed = self.fresh();
                self.push(Inst::TypedPtr { dst: typed, src: loaded, ty: or });
                typed
            }
            None => loaded,
        }
    }

    /// If `d` names a class-typed variable, return its `(object_record, class
    /// name, has_vtable)` so `NEW` can allocate the instance and install the
    /// vtable pointer.
    fn class_instance_info(
        &self,
        d: &ast::Designator,
    ) -> Option<(newm2_sema::types::TypeId, String, bool)> {
        let ty = self.sema_var_type(d)?;
        let TypeKind::Class { symbol } = self.ctx.sema.types.get(ty) else {
            return None;
        };
        let cls = self.ctx.sema.classes.get(ClassSymbolId(*symbol));
        let obj = cls.object_record?;
        // Every concrete native class has a {Class}.vtable (carrying typeinfo at
        // slot -1) even when method-less, so field 0 always points at it (NEW then
        // stores element-1) — keeping ISMEMBER/GUARD answers correct for
        // field-only classes. (Interfaces/abstract classes are never NEW'd.)
        let has_vtable = !cls.is_interface && !cls.is_abstract;
        Some((obj, cls.name.clone(), has_vtable))
    }

    /// `NEW(obj)` for a class variable: allocate the object record on the heap,
    /// store the pointer into the variable, and install the vtable pointer at
    /// field 0 (NIL for a method-less class).
    fn lower_class_new(
        &mut self,
        d: &ast::Designator,
        object_record: newm2_sema::types::TypeId,
        class_name: &str,
        has_vtable: bool,
    ) {
        let obj = self.fresh();
        self.push(Inst::Allocate { dst: obj, ty: object_record });
        let lval = self.eval_lvalue(d);
        self.push(Inst::Store { ptr: lval, val: obj });
        // Install the vtable pointer at field 0 of the object record.
        let vptr_slot = self.fresh();
        self.push(Inst::FieldPtr { dst: vptr_slot, base: obj, field: 0 });
        let vtable_val = if has_vtable {
            let addr = self.ctx.sema.types.builtin(Builtin::Address);
            let base = self.emit_global_ref(format!("{class_name}.vtable"), addr);
            // The vtable global is laid out [typeinfo, method0, method1, …]; store
            // a pointer to the FIRST METHOD (element 1) into the object so method
            // dispatch stays a plain [vtable_index] (identical to a foreign COM
            // object) and the {Class}.typeinfo pointer sits at vtable[-1] for RTTI.
            let one = self.fresh();
            self.push(Inst::Const { dst: one, val: ConstVal::Int(1) });
            let methods = self.fresh();
            self.push(Inst::IndexPtr { dst: methods, base, index: one, elem_ty: addr });
            methods
        } else {
            self.emit_nil()
        };
        self.push(Inst::Store { ptr: vptr_slot, val: vtable_val });
    }

    fn apply_selector(
        &mut self,
        base: ValueId,
        base_ty: Option<newm2_sema::TypeId>,
        sel: &ast::Selector,
    ) -> ValueId {
        match sel {
            ast::Selector::Field(field_name, span) => {
                // A class is a reference: load it to get the object pointer
                // before indexing into the object record (field 0 = vtable).
                let base = self.deref_class_base(base, base_ty);
                let field_index = self
                    .ctx
                    .sema
                    .selector_binding(self.ctx.mid, *span)
                    .and_then(|binding| match binding {
                        SelectorBinding::Field { index, .. } => index,
                        SelectorBinding::Method { .. } => None,
                    })
                    .or_else(|| base_ty.and_then(|ty| self.resolve_field_index(ty, field_name)))
                    .unwrap_or(0);
                let dst = self.fresh();
                self.push(Inst::FieldPtr { dst, base, field: field_index });
                dst
            }
            ast::Selector::Index(indices, _) => {
                // The array's dimension index-types and element type.
                let (dims, base_elem): (Vec<newm2_sema::types::TypeId>, Option<_>) = base_ty
                    .map(|ty| match self.ctx.sema.types.get(ty) {
                        TypeKind::Array { indices, base } => (indices.clone(), Some(*base)),
                        TypeKind::OpenArray { base } => (Vec::new(), Some(*base)),
                        _ => (Vec::new(), None),
                    })
                    .unwrap_or((Vec::new(), None));
                let elem_ty = base_elem.unwrap_or_else(|| self.ctx.int_ty());

                // Multi-dimensional indexing of a fixed array: flatten row-major
                // with per-dimension lower-bound adjustment,
                // flat = Σ_k (i_k - lo_k) · ∏_{m>k} count_m. A single fixed-array
                // index goes here too, so a non-zero-based ARRAY[1..3] subtracts
                // its lower bound. *Partial* indexing (fewer indices than dims)
                // also flattens — the stride over the remaining dimensions lands
                // the pointer on the start of the lower-rank sub-array. Open
                // arrays (no fixed dims) fall back to the raw first index.
                let index = if !dims.is_empty() && indices.len() <= dims.len() {
                    let mut flat: Option<ValueId> = None;
                    for (k, ix) in indices.iter().enumerate() {
                        let raw = self.eval_expr(ix);
                        let lo = self.dim_lo(dims[k]);
                        let adj = if lo != 0 {
                            let lo_c = self.fresh();
                            self.push(Inst::Const { dst: lo_c, val: ConstVal::Int(lo) });
                            let a = self.fresh();
                            self.push(Inst::Binary { dst: a, op: BinOp::Sub, lhs: raw, rhs: lo_c });
                            a
                        } else {
                            raw
                        };
                        // ISO array index check (on by default): 0 <= adj < count_k.
                        // Skip degenerate or "unbounded" dimensions: the standard
                        // `POINTER TO ARRAY [0..MAX(CARDINAL)-1] OF T` idiom has a
                        // meaningless count (MAX folds to a placeholder), and a
                        // lo>hi subrange yields count <= 0. Only a real, sane
                        // fixed bound is checked.
                        let count = self.dim_count(dims[k]);
                        if self.ctx.runtime_checks && count > 0 && count <= i64::MAX as i128 {
                            self.emit_index_bounds_check(adj, count);
                        }
                        let stride: i128 =
                            dims[k + 1..].iter().map(|&d| self.dim_count(d)).product();
                        let term = if stride != 1 {
                            let s_c = self.fresh();
                            self.push(Inst::Const { dst: s_c, val: ConstVal::Int(stride) });
                            let t = self.fresh();
                            self.push(Inst::Binary { dst: t, op: BinOp::Mul, lhs: adj, rhs: s_c });
                            t
                        } else {
                            adj
                        };
                        flat = Some(match flat {
                            None => term,
                            Some(f) => {
                                let s = self.fresh();
                                self.push(Inst::Binary { dst: s, op: BinOp::Add, lhs: f, rhs: term });
                                s
                            }
                        });
                    }
                    flat.unwrap()
                } else {
                    self.eval_expr(&indices[0])
                };
                let dst = self.fresh();
                self.push(Inst::IndexPtr { dst, base, index, elem_ty });
                dst
            }
            ast::Selector::Deref(_) => {
                // `^` dereferences a pointer; result is another pointer (the
                // pointee's address).
                let dst = self.fresh();
                self.push(Inst::Load { dst, ptr: base });
                // Dereferencing NIL is `invalidLocation` (ISO). Gated by the
                // runtime-checks flag; emitted before any GEP off the pointer.
                if self.ctx.runtime_checks {
                    self.emit_nil_check(dst);
                }
                // Annotate the loaded pointer with its pointee type so a
                // following field/index GEP uses the correct element type
                // rather than codegen's conservative i64 fallback. (Needed for
                // by-value pointer params like `s: SEMAPHORE` whose alloca slot
                // carries no pointee hint of its own.)
                if let Some(pointee) = base_ty.and_then(|ty| match self.ctx.sema.types.get(ty) {
                    TypeKind::Pointer { base } => Some(*base),
                    _ => None,
                }) {
                    let typed = self.fresh();
                    self.push(Inst::TypedPtr { dst: typed, src: dst, ty: pointee });
                    return typed;
                }
                dst
            }
            ast::Selector::TypeGuard(_, _) => base,
        }
    }

    /// Lower bound of an array dimension index-type. Uses the shared ordinal
    /// helper so a bare built-in ordinal index (CHAR/BOOLEAN) reports its real
    /// MIN, not 0-by-default.
    fn dim_lo(&self, dim: newm2_sema::types::TypeId) -> i128 {
        self.ctx.sema.types.ordinal_bounds(dim).map(|(lo, _)| lo).unwrap_or(0)
    }

    /// Number of elements in an array dimension index-type. Uses the shared
    /// ordinal cardinality so a bare built-in ordinal index (e.g.
    /// `ARRAY CHAR OF …` = 65536, `ARRAY BOOLEAN OF …` = 2) is sized correctly,
    /// not collapsed to 1.
    fn dim_count(&self, dim: newm2_sema::types::TypeId) -> i128 {
        self.ctx.sema.types.ordinal_cardinality(dim).unwrap_or(1)
    }

    /// Resolve a (possibly qualified) name to a value suitable as a callee.
    ///
    /// For Proc symbols this emits `Const { FuncRef }` and ensures an
    /// `ExternFunc` global entry exists.  For unknown names the same pattern
    /// is used as a fallback.
    fn resolve_name_as_value(&mut self, name: &ast::QualName) -> ValueId {
        let qname = name.segments.join(".");

        // Sema lookup (two-segment qualified names are common: `M.proc`).
        if let Some(sig) = self.resolve_proc_signature(name) {
            // An EXTERNAL proc is resolved by its LINK NAME, so the emitted LLVM
            // symbol must *be* that link name — not the module-qualified name —
            // for both a bare `["link" EXTERNAL]` and a DLL import
            // `["QueryPerformanceFrequency" EXTERNAL FROM "KERNEL32.dll"]`. The
            // JIT maps it via dll_name+GetProcAddress; the AOT linker resolves it
            // against the DLL's import library (added to the link command). Using
            // the qualified `System_Performance.QueryPerformanceFrequency` here
            // left an unresolvable external at AOT.
            let call_name = match &sig.import_name {
                Some(link) => link.clone(),
                None => qname.clone(),
            };
            // Register in globals table (idempotent).
            self.ctx.get_or_add_extern(
                self.ir,
                &call_name,
                sig.import_name,
                sig.dll_name,
                Some(sig.params),
                sig.return_ty,
                sig.is_variadic,
            );
            let dst = self.fresh();
            self.push(Inst::Const { dst, val: ConstVal::FuncRef(call_name) });
            return dst;
        }

        self.ctx.get_or_add_extern(self.ir, &qname, None, None, None, None, false);
        let dst = self.fresh();
        self.push(Inst::Const { dst, val: ConstVal::FuncRef(qname) });
        dst
    }

    fn designator_proc_name(&self, d: &ast::Designator) -> Option<ast::QualName> {
        // Resolve the proc symbol's provenance and base name. Proc definitions
        // are emitted module-qualified (`{module}.{proc}`), so every call must
        // be rewritten to the *defining*-module-qualified name. This unifies
        // intra-module, imported, and re-exported references and prevents
        // same-named procs in different modules from colliding once linked.
        //
        // The fallback name preserves the original behaviour when provenance is
        // unavailable. SYSTEM intrinsics / pervasive builtins are intercepted
        // earlier, so only real Declared/Imported module procs reach here.
        let (prov, base_name, fallback): (Option<&SymbolProvenance>, String, ast::QualName) =
            if let [n] = d.base.segments.as_slice()
                && d.selectors.is_empty()
            {
                // Unqualified name: scope lookup reliably carries provenance,
                // even for intra-module calls whose call-site span sema didn't
                // annotate.
                let sym = self.ctx.sema.scopes.lookup(self.scope, n);
                let is_proc = matches!(sym.map(|s| &s.kind), Some(SymbolKind::Proc(_)))
                    || self.resolve_is_proc(&d.base);
                if !is_proc {
                    return None;
                }
                (sym.map(|s| &s.provenance), n.clone(), d.base.clone())
            } else if let Some((module_name, member, SymbolKind::Proc(_), consumed)) =
                self.designator_module_member(d)
                && consumed == d.selectors.len()
            {
                let member_span = match d.selectors.first() {
                    Some(ast::Selector::Field(_, sp)) => *sp,
                    _ => d.span,
                };
                let prov = self.ctx.sema.resolved_provenance(self.ctx.mid, member_span);
                let fallback = ast::QualName {
                    segments: vec![module_name, member.clone()],
                    span: d.span,
                };
                (prov, member, fallback)
            } else {
                let mut segments = d.base.segments.clone();
                for sel in &d.selectors {
                    let ast::Selector::Field(name, _) = sel else {
                        return None;
                    };
                    segments.push(name.clone());
                }
                let qname = ast::QualName { segments, span: d.span };
                if !self.resolve_is_proc(&qname) {
                    return None;
                }
                return Some(qname);
            };

        if let Some(prov) = prov
            && matches!(
                prov,
                SymbolProvenance::Declared { .. } | SymbolProvenance::Imported { .. }
            )
            && let Some((_mid, mod_name)) = prov.declaring_module()
        {
            let proc_name = prov.root_name().unwrap_or(base_name.as_str());
            return Some(ast::QualName {
                segments: vec![mod_name.to_string(), proc_name.to_string()],
                span: fallback.span,
            });
        }

        Some(fallback)
    }

    /// Pure sema query: is `name` a Proc symbol?
    fn resolve_is_proc(&self, name: &ast::QualName) -> bool {
        matches!(self.ctx.sema.resolved_name(self.ctx.mid, name.span), Some(SymbolKind::Proc(_)))
            || self.resolve_proc_signature(name).is_some()
    }

    fn resolve_proc_signature(
        &self,
        name: &ast::QualName,
    ) -> Option<ResolvedExternSig> {
        if let Some(sig) = self.annotated_proc_signature(name) {
            return Some(sig);
        }

        match name.segments.as_slice() {
            [n] => match self.ctx.sema.scopes.lookup(self.scope, n).map(|s| &s.kind) {
                Some(SymbolKind::Proc(sig)) => Some(Self::sig_from_proc(sig)),
                _ => None,
            },
            // Qualified `Module.Proc` (including the defining-module-qualified
            // names produced for intra-module calls): resolve via the named
            // module's scope so open-array companion args are emitted.
            [module, proc] => {
                let mid = self.ctx.graph.lookup(module)?;
                let mscope = *self.ctx.sema.module_scopes.get(&mid)?;
                match self.ctx.sema.scopes.get(mscope).get(proc).map(|s| &s.kind) {
                    Some(SymbolKind::Proc(sig)) => Some(Self::sig_from_proc(sig)),
                    _ => None,
                }
            }
            _ => None,
        }
    }

    /// Build a `ResolvedExternSig` from a sema `ProcSig`.
    fn sig_from_proc(sig: &newm2_sema::scope::ProcSig) -> ResolvedExternSig {
        let params = sig
            .params
            .iter()
            .map(|param| IrParam {
                name: param.name.clone().unwrap_or_default(),
                ty: param.ty,
                is_var: param.mode == newm2_sema::types::ParamMode::Var,
            })
            .collect();
        ResolvedExternSig {
            params,
            return_ty: sig.return_ty,
            import_name: sig.external_linkage.as_ref().map(|linkage| linkage.link_name.clone()),
            dll_name: sig.external_linkage.as_ref().and_then(|linkage| linkage.dll_name.clone()),
            is_variadic: sig.attrs.contains(&newm2_sema::scope::ProcAttrKind::Varargs),
        }
    }

    /// Finalise the in-progress function.
    fn finish(mut self) -> Func {
        // If the current block is unterminated, jump to exit.
        if !self.builder.is_terminated() {
            let exit = self.builder.exit_block();
            self.builder.terminate(Terminator::Goto(exit));
        }
        self.builder.finish()
    }
}

// ---- Utilities -----------------------------------------------------------

/// Extract a compile-time integer from a simple literal expression.
/// Used for CASE label expansion.
fn const_int(expr: &ast::Expr) -> Option<i128> {
    match expr {
        ast::Expr::Integer(n, _) => Some(*n as i128),
        ast::Expr::Char(c, _) => Some(c.value as i128),
        ast::Expr::Unary(ast::UnaryOp::Neg, e, _) => const_int(e).map(|n| -n),
        _ => None,
    }
}

/// True when `callee` is the bare identifier `NEW` with no module qualifier
/// and no selectors (i.e., the pervasive `NEW` builtin).
fn is_new_builtin(callee: &ast::Expr) -> bool {
    match callee {
        ast::Expr::Designator(d) =>
            d.selectors.is_empty()
            && d.base.segments.len() == 1
            && d.base.segments[0] == "NEW",
        _ => false,
    }
}

fn expr_span(expr: &ast::Expr) -> Span {
    match expr {
        ast::Expr::Integer(_, span)
        | ast::Expr::Real(_, span)
        | ast::Expr::Char(_, span)
        | ast::Expr::String(_, span)
        | ast::Expr::Nil(span)
        | ast::Expr::Call(_, _, span)
        | ast::Expr::Binary(_, _, _, span)
        | ast::Expr::Unary(_, _, span) => *span,
        ast::Expr::Designator(designator) => designator.span,
        ast::Expr::Set { span, .. } => *span,
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum TransferClass {
    Whole,
    Real,
    Char,
    Boolean,
    Enumeration,
}

fn transfer_class(types: &newm2_sema::TypeArena, ty: newm2_sema::types::TypeId) -> Option<TransferClass> {
    match types.get(ty) {
        TypeKind::Subrange { host, .. } => transfer_class(types, *host),
        TypeKind::Enum { .. } => Some(TransferClass::Enumeration),
        TypeKind::Builtin(b) => match b {
            Builtin::Integer
            | Builtin::LongInt
            | Builtin::Integer8
            | Builtin::Integer16
            | Builtin::Integer32
            | Builtin::Integer64
            | Builtin::Cardinal
            | Builtin::LongCard
            | Builtin::Cardinal8
            | Builtin::Cardinal16
            | Builtin::Cardinal32
            | Builtin::Cardinal64
            | Builtin::Byte
            | Builtin::Word
            | Builtin::Dword
            | Builtin::Qword
            | Builtin::SysWord
            | Builtin::SysByte
            | Builtin::SysLoc => Some(TransferClass::Whole),
            Builtin::Real | Builtin::LongReal | Builtin::Real32 | Builtin::Real16 => {
                Some(TransferClass::Real)
            }
            Builtin::Char | Builtin::Achar | Builtin::Uchar => Some(TransferClass::Char),
            Builtin::Boolean => Some(TransferClass::Boolean),
            _ => None,
        },
        _ => None,
    }
}

fn integer_width(types: &newm2_sema::TypeArena, ty: newm2_sema::types::TypeId) -> Option<u32> {
    match types.get(ty) {
        TypeKind::Subrange { host, .. } => integer_width(types, *host),
        TypeKind::Enum { .. } => Some(32),
        TypeKind::Builtin(b) => match b {
            Builtin::Boolean => Some(1),
            Builtin::Char | Builtin::Achar | Builtin::Byte | Builtin::Integer8 | Builtin::Cardinal8
            | Builtin::SysByte | Builtin::SysLoc => Some(8),
            Builtin::Uchar | Builtin::Word | Builtin::Integer16 | Builtin::Cardinal16 => Some(16),
            Builtin::Integer32 | Builtin::Cardinal32 | Builtin::Dword => Some(32),
            Builtin::Integer
            | Builtin::LongInt
            | Builtin::Integer64
            | Builtin::Cardinal
            | Builtin::LongCard
            | Builtin::Cardinal64
            | Builtin::Qword
            | Builtin::SysWord => Some(64),
            _ => None,
        },
        _ => None,
    }
}

/// Types whose LLVM representation is an opaque pointer (see codegen
/// `builtin_type`): genuine pointers, procedure values, and the address-ish
/// SYSTEM builtins.
fn is_pointer_like(types: &newm2_sema::TypeArena, ty: newm2_sema::types::TypeId) -> bool {
    match types.get(ty) {
        // A CLASS is a reference type (a pointer to the object, base fields first
        // under single inheritance), so SYSTEM.CAST between classes — or a class
        // and ADDRESS — is a pointer reinterpret (BitCast), e.g. a Backend ->
        // ControlBackend downcast. Without this a class CAST lowers to no Cast
        // inst and leaves its result ValueId undefined in codegen.
        TypeKind::Pointer { .. } | TypeKind::Proc { .. } | TypeKind::Class { .. } => true,
        TypeKind::Builtin(b) => matches!(
            b,
            Builtin::Address
                | Builtin::SysAddress
                | Builtin::SysLoc
                | Builtin::Adrint
                | Builtin::Adrcard
                | Builtin::Nil
                | Builtin::Proc
        ),
        _ => false,
    }
}

/// Whole-aggregate lvalue copies of at least this many bytes are lowered to
/// `memmove` (Inst::MemCopy) instead of an SSA by-value load/store. Well below
/// the ~64KB element-count cliff that segfaults LLVM's SelectionDAG, and above
/// every ordinary small record/array (which keep the proven load/store path).
const AGGREGATE_MEMCOPY_THRESHOLD: i128 = 1024;

/// A genuine aggregate (RECORD or closed ARRAY) — the operand shape that makes a
/// `SYSTEM.CAST` a memory reinterpret rather than a scalar/pointer cast. Open
/// arrays, vectors and sets are deliberately excluded (they have their own paths).
fn is_aggregate_xfer(types: &newm2_sema::TypeArena, ty: newm2_sema::types::TypeId) -> bool {
    matches!(types.get(ty), TypeKind::Record(..) | TypeKind::Array { .. })
}

/// Static byte size of a type, for the whole-aggregate-copy threshold. Returns
/// None when not statically sizable here (the caller then keeps the default
/// load/store path). Mirrors codegen's array/record layout sizing.
fn type_byte_size(types: &newm2_sema::TypeArena, ty: newm2_sema::types::TypeId) -> Option<i128> {
    match types.get(ty) {
        TypeKind::Subrange { host, .. } => type_byte_size(types, *host),
        TypeKind::Array { indices, base } => {
            let mut count: i128 = 1;
            for &idx in indices {
                count = count.checked_mul(types.ordinal_cardinality(idx)?)?;
            }
            count.checked_mul(type_byte_size(types, *base)?)
        }
        TypeKind::Record(layout) => {
            let mut sum: i128 = 0;
            for (_, fty) in layout.flatten_fields() {
                sum = sum.checked_add(type_byte_size(types, fty)?)?;
            }
            Some(sum)
        }
        TypeKind::Set { .. } | TypeKind::Builtin(Builtin::Bitset | Builtin::SysBitset) => Some(32),
        _ if is_pointer_like(types, ty) => Some(8),
        TypeKind::Enum { .. } => Some(4),
        _ => scalar_bit_width(types, ty).map(|w| (w as i128 + 7) / 8),
    }
}

/// Bit width of a real type (REAL/LONGREAL = 64, REAL32 = 32, REAL16 = 16).
fn real_bit_width(types: &newm2_sema::TypeArena, ty: newm2_sema::types::TypeId) -> Option<u32> {
    match types.get(ty) {
        TypeKind::Subrange { host, .. } => real_bit_width(types, *host),
        TypeKind::Builtin(Builtin::Real16) => Some(16),
        TypeKind::Builtin(Builtin::Real32) => Some(32),
        TypeKind::Builtin(Builtin::Real | Builtin::LongReal) => Some(64),
        _ => None,
    }
}

/// Bit width of a scalar, for same-width `SYSTEM.CAST` reinterpretation
/// detection.
fn scalar_bit_width(types: &newm2_sema::TypeArena, ty: newm2_sema::types::TypeId) -> Option<u32> {
    match transfer_class(types, ty)? {
        TransferClass::Real => real_bit_width(types, ty),
        _ => integer_width(types, ty),
    }
}

/// Classify a `VAL`/`CAST` transfer into an IR cast kind.
///
/// `is_cast` selects `SYSTEM.CAST` semantics (bit-level reinterpretation)
/// over `VAL` semantics (arithmetic value conversion). Pointer-involved
/// transfers always reinterpret, regardless of which builtin was used.
fn classify_transfer_cast(
    sema: &SemaResult,
    source_ty: newm2_sema::types::TypeId,
    target_ty: newm2_sema::types::TypeId,
    is_cast: bool,
) -> Option<CastKind> {
    // A CAST where one operand is an aggregate (RECORD / closed ARRAY) is a
    // bit-level memory reinterpret — not a scalar conversion or a pointer cast.
    // Checked FIRST so a record↔ADDRESS pair routes here too (it would otherwise
    // mis-route to Int↔Ptr and feed emit_cast a StructValue). Gated on `is_cast`
    // because VAL is restricted to scalars by sema, so VAL never reaches here.
    if is_cast
        && (is_aggregate_xfer(&sema.types, source_ty) || is_aggregate_xfer(&sema.types, target_ty))
    {
        return Some(CastKind::MemReinterpret);
    }

    // Pointer-involved transfers: reinterpret rather than convert.
    match (
        is_pointer_like(&sema.types, source_ty),
        is_pointer_like(&sema.types, target_ty),
    ) {
        (true, true) => return Some(CastKind::BitCast),
        (true, false) => return Some(CastKind::PtrToInt),
        (false, true) => return Some(CastKind::IntToPtr),
        (false, false) => {}
    }

    // Set/BITSET-involved transfers: a set is an i256 bit-pattern, so VAL/CAST
    // to or from a whole number (PIM BITSET-as-word) is a width adjustment of
    // the raw bits — truncate when narrowing, zero-extend when widening.
    let set_like = |t: newm2_sema::types::TypeId| {
        matches!(
            sema.types.get(t),
            TypeKind::Set { .. } | TypeKind::Builtin(Builtin::Bitset | Builtin::SysBitset)
        )
    };
    if set_like(source_ty) || set_like(target_ty) {
        let src_w = if set_like(source_ty) { 256 } else { scalar_bit_width(&sema.types, source_ty)? };
        let dst_w = if set_like(target_ty) { 256 } else { scalar_bit_width(&sema.types, target_ty)? };
        return Some(if src_w > dst_w {
            CastKind::IntTrunc
        } else if src_w < dst_w {
            CastKind::IntZeroExt
        } else {
            CastKind::BitCast
        });
    }

    let source_class = transfer_class(&sema.types, source_ty)?;
    let target_class = transfer_class(&sema.types, target_ty)?;

    // SYSTEM.CAST punning: same-width scalars reinterpret with a single
    // bitcast (REAL↔ordinal, equal-width ordinals). Differing widths fall
    // through to the value-style adjustment below.
    if is_cast
        && let (Some(sw), Some(dw)) = (
            scalar_bit_width(&sema.types, source_ty),
            scalar_bit_width(&sema.types, target_ty),
        )
        && sw == dw
    {
        return Some(CastKind::BitCast);
    }

    match (source_class, target_class) {
        (TransferClass::Real, TransferClass::Real) => {
            let src_width = real_bit_width(&sema.types, source_ty)?;
            let dst_width = real_bit_width(&sema.types, target_ty)?;
            if src_width < dst_width {
                Some(CastKind::FloatExt)
            } else if src_width > dst_width {
                Some(CastKind::FloatTrunc)
            } else {
                Some(CastKind::BitCast)
            }
        }
        (TransferClass::Real, _) => Some(CastKind::FloatToInt),
        (_, TransferClass::Real) => Some(CastKind::IntToFloat),
        (TransferClass::Char, TransferClass::Char) => Some(CastKind::BitCast),
        (_, TransferClass::Char) => Some(CastKind::OrdToChar),
        (TransferClass::Char, _) => Some(CastKind::CharToOrd),
        _ => {
            let src_width = integer_width(&sema.types, source_ty)?;
            let dst_width = integer_width(&sema.types, target_ty)?;
            if src_width == dst_width {
                Some(CastKind::BitCast)
            } else if src_width > dst_width {
                Some(CastKind::IntTrunc)
            } else if matches!(source_class, TransferClass::Boolean | TransferClass::Enumeration) {
                Some(CastKind::IntZeroExt)
            } else {
                Some(CastKind::IntSignExt)
            }
        }
    }
}

/// Convert a sema `ConstValue` to an IR `ConstVal`.
fn sema_const_to_ir(v: &newm2_sema::ConstValue) -> ConstVal {
    match v {
        newm2_sema::ConstValue::Int(n) => ConstVal::Int(*n),
        newm2_sema::ConstValue::Real(f) => ConstVal::Real(*f),
        newm2_sema::ConstValue::Bool(b) => ConstVal::Bool(*b),
        newm2_sema::ConstValue::Char(c) => ConstVal::Char(*c),
        newm2_sema::ConstValue::Str(s) => ConstVal::Str(s.clone()),
        _ => ConstVal::Nil,
    }
}

// ---- Tests ---------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use newm2_loader::{SearchPath, build_module_graph};
    use std::fs;

    fn tmpdir(suffix: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("newm2_ir_{suffix}_{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn hello_world_module_body_has_call() {
        let dir = tmpdir("hello");
        fs::write(
            dir.join("STextIO.def"),
            "DEFINITION MODULE STextIO;\n\
             PROCEDURE WriteString(s: ARRAY OF CHAR);\n\
             END STextIO.\n",
        )
        .unwrap();
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\n\
             IMPORT STextIO;\n\
             BEGIN\n\
               STextIO.WriteString(\"hi\");\n\
             END Hello.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        assert!(!sema.has_errors(), "sema errors: {:?}", sema.diagnostics);
        let mid = graph.lookup("Hello").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc)
            .expect("Hello should lower");
        let body = ir.funcs.last().expect("expected body func");
        let has_call = body
            .blocks
            .iter()
            .any(|b| b.insts.iter().any(|i| matches!(i, Inst::Call { .. })));
        assert!(has_call, "expected Call instruction in hello-world body");
    }

    #[test]
    fn bare_parameterless_procedure_statement_has_call() {
        let dir = tmpdir("writeln");
        fs::write(
            dir.join("STextIO.def"),
            "DEFINITION MODULE STextIO;\n\
             PROCEDURE WriteLn;\n\
             END STextIO.\n",
        )
        .unwrap();
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\n\
             IMPORT STextIO;\n\
             BEGIN\n\
               STextIO.WriteLn;\n\
             END Hello.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        assert!(!sema.has_errors(), "sema errors: {:?}", sema.diagnostics);
        let mid = graph.lookup("Hello").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc)
            .expect("Hello should lower");
        let body = ir.funcs.last().expect("expected body func");
        let has_call = body
            .blocks
            .iter()
            .any(|b| b.insts.iter().any(|i| matches!(i, Inst::Call { args, .. } if args.is_empty())));
        assert!(has_call, "expected zero-arg Call instruction for bare procedure statement");
    }

    #[test]
    fn while_loop_has_condbr_and_back_edge() {
        let dir = tmpdir("while");
        fs::write(
            dir.join("W.mod"),
            "MODULE W;\nVAR i: INTEGER;\n\
             BEGIN\n  i := 0;\n  WHILE i < 10 DO i := i + 1 END\n\
             END W.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("W.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        let mid = graph.lookup("W").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let body = ir.funcs.last().unwrap();
        // At minimum: entry, exit, while_cond, while_body, while_exit.
        assert!(body.blocks.len() >= 5, "expected ≥5 blocks, got {}", body.blocks.len());
        let has_condbr =
            body.blocks.iter().any(|b| matches!(b.term, Terminator::CondBr { .. }));
        assert!(has_condbr, "expected CondBr terminator");
        // Verify back edge: while_body should have a Goto to while_cond (lower index).
        let back_edges: Vec<_> = body
            .blocks
            .iter()
            .filter(|b| {
                if let Terminator::Goto(target) = b.term {
                    target.0 < b.id.0
                } else {
                    false
                }
            })
            .collect();
        assert!(!back_edges.is_empty(), "expected at least one back edge");
    }

    #[test]
    fn if_else_produces_condbr() {
        let dir = tmpdir("ifelse");
        fs::write(
            dir.join("IE.mod"),
            "MODULE IE;\nVAR x: INTEGER;\n\
             BEGIN\n  IF x > 0 THEN x := 1 ELSE x := 2 END\n\
             END IE.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("IE.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        let mid = graph.lookup("IE").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let body = ir.funcs.last().unwrap();
        let has_condbr =
            body.blocks.iter().any(|b| matches!(b.term, Terminator::CondBr { .. }));
        assert!(has_condbr, "expected CondBr for IF/ELSE");
    }

    #[test]
    fn case_produces_switch() {
        let dir = tmpdir("case");
        fs::write(
            dir.join("C.mod"),
            "MODULE C;\nVAR x, y: INTEGER;\n\
             BEGIN\n  CASE x OF\n  1: y := 1\n  | 2: y := 2\n  ELSE y := 0\n  END\n\
             END C.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("C.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        let mid = graph.lookup("C").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let body = ir.funcs.last().unwrap();
        let has_switch =
            body.blocks.iter().any(|b| matches!(b.term, Terminator::Switch { .. }));
        assert!(has_switch, "expected Switch terminator for CASE");
    }

    #[test]
    fn for_loop_has_step_block() {
        let dir = tmpdir("for");
        fs::write(
            dir.join("F.mod"),
            "MODULE F;\nVAR i, s: INTEGER;\n\
             BEGIN\n  s := 0;\n  FOR i := 1 TO 10 DO s := s + i END\n\
             END F.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("F.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        let mid = graph.lookup("F").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let body = ir.funcs.last().unwrap();
        // FOR: entry + exit + for_cond + for_body + for_step + for_exit = ≥6 blocks.
        assert!(body.blocks.len() >= 6, "expected ≥6 blocks for FOR loop, got {}", body.blocks.len());
    }

    #[test]
    fn class_field_access_uses_sema_selector_slot() {
        let dir = tmpdir("class_field_slot");
        fs::write(
            dir.join("F.mod"),
            "MODULE F;\n\
                         CLASS T;\n\
                             VAR a, b: INTEGER;\n\
                         END T;\n\
                         VAR xs: ARRAY [0..0] OF T;\n\
             BEGIN\n\
                             xs[0].b := 1\n\
             END F.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("F.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        assert!(!sema.has_errors(), "sema errors: {:?}", sema.diagnostics);

        let mid = graph.lookup("F").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let body = ir.funcs.last().unwrap();
        let field_slots: Vec<_> = body
            .blocks
            .iter()
            .flat_map(|block| block.insts.iter())
            .filter_map(|inst| match inst {
                Inst::FieldPtr { field, .. } => Some(*field),
                _ => None,
            })
            .collect();

        // Slot 2: vtable pointer occupies object-record slot 0; b is the 2nd
        // field (a=1, b=2).
        assert!(field_slots.contains(&2), "expected class field access to use slot 2, got {field_slots:?}");
    }

    #[test]
    fn direct_class_field_access_uses_sema_selector_slot() {
        let dir = tmpdir("direct_class_field_slot");
        fs::write(
            dir.join("F.mod"),
            "MODULE F;\n\
             CLASS T;\n\
               VAR a, b: INTEGER;\n\
             END T;\n\
             VAR x: T;\n\
             BEGIN\n\
               x.b := 1\n\
             END F.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("F.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        assert!(!sema.has_errors(), "sema errors: {:?}", sema.diagnostics);

        let mid = graph.lookup("F").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let body = ir.funcs.last().unwrap();
        let field_slots: Vec<_> = body
            .blocks
            .iter()
            .flat_map(|block| block.insts.iter())
            .filter_map(|inst| match inst {
                Inst::FieldPtr { field, .. } => Some(*field),
                _ => None,
            })
            .collect();

        // Slot 2: the object record reserves slot 0 for the vtable pointer, so
        // fields a, b land at struct indices 1, 2.
        assert!(field_slots.contains(&2), "expected direct class field access to use slot 2, got {field_slots:?}");
    }

    #[test]
    fn module_qualified_variable_access_uses_sema_member_resolution() {
        let dir = tmpdir("module_var_resolution");
        fs::write(
            dir.join("M.def"),
            "DEFINITION MODULE M;\n\
             VAR x: INTEGER;\n\
             END M.\n",
        )
        .unwrap();
        fs::write(
            dir.join("User.mod"),
            "MODULE User;\n\
             IMPORT M;\n\
             BEGIN\n\
               M.x := 1\n\
             END User.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("User.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        assert!(!sema.has_errors(), "sema errors: {:?}", sema.diagnostics);

        let mid = graph.lookup("User").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let body = ir.funcs.last().unwrap();
        let module_refs: Vec<_> = body
            .blocks
            .iter()
            .flat_map(|block| block.insts.iter())
            .filter_map(|inst| match inst {
                Inst::Const {
                    val: ConstVal::GlobalRef { name, .. },
                    ..
                } => Some(name.clone()),
                _ => None,
            })
            .collect();

        assert!(module_refs.iter().any(|name| name == "M.x"), "expected global ref to M.x, got {module_refs:?}");
    }

    #[test]
    fn qualified_procedure_call_reads_proc_binding_from_name_span() {
        let dir = tmpdir("qualified_proc_binding");
        fs::write(
            dir.join("STextIO.def"),
            "DEFINITION MODULE STextIO;\n\
             PROCEDURE WriteLn;\n\
             END STextIO.\n",
        )
        .unwrap();
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\n\
             IMPORT STextIO;\n\
             BEGIN\n\
               STextIO.WriteLn;\n\
             END Hello.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        assert!(!sema.has_errors(), "sema errors: {:?}", sema.diagnostics);

        let mid = graph.lookup("Hello").unwrap();
        let ast = graph.get(mid).impl_ast.as_ref().unwrap();
        let name_span = match &ast.body.as_ref().unwrap().stmts[0] {
            ast::Stmt::Call(ast::Expr::Designator(designator), _) => designator.span,
            other => panic!("expected call statement, got {other:?}"),
        };
        assert!(matches!(sema.resolved_name(mid, name_span), Some(SymbolKind::Proc(_))));

        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let body = ir.funcs.last().unwrap();
        let has_func_ref = body
            .blocks
            .iter()
            .flat_map(|block| block.insts.iter())
            .any(|inst| matches!(inst, Inst::Const { val: ConstVal::FuncRef(name), .. } if name == "STextIO.WriteLn"));
        assert!(has_func_ref, "expected FuncRef for STextIO.WriteLn");
    }

    #[test]
    fn extern_func_carries_dll_metadata_from_sema() {
        let dir = tmpdir("extern_func_dll_metadata");
        fs::write(
            dir.join("Win.def"),
            "DEFINITION MODULE Win;\n\
             PROCEDURE Beep[\"Beep\" EXTERNAL FROM \"kernel32.dll\"](dwFreq, dwDuration : CARDINAL) : BOOLEAN;\n\
             END Win.\n",
        )
        .unwrap();
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\n\
             IMPORT Win;\n\
             BEGIN\n\
               Win.Beep(440, 1)\n\
             END Hello.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        assert!(!sema.has_errors(), "sema errors: {:?}", sema.diagnostics);

        let mid = graph.lookup("Hello").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let extern_func = ir
            .globals
            .iter()
            .find_map(|global| match global {
                Global::ExternFunc {
                    name,
                    import_name,
                    dll_name,
                    ..
                } if name == "Win.Beep" => Some((import_name.as_deref(), dll_name.as_deref())),
                _ => None,
            })
            .expect("Win.Beep extern func");
        assert_eq!(extern_func.0, Some("Beep"));
        assert_eq!(extern_func.1, Some("kernel32.dll"));
    }

    #[test]
    fn val_and_system_cast_lower_to_ir_casts() {
        let dir = tmpdir("transfer_casts");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             IMPORT SYSTEM;\n\
             VAR x: LONGREAL; y: INTEGER64; z: INTEGER;\n\
             BEGIN\n\
               y := VAL(INTEGER64, x);\n\
               z := SYSTEM.CAST(INTEGER, y)\n\
             END M.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let sema = newm2_sema::check_module_graph(&graph);
        assert!(!sema.has_errors(), "sema errors: {:?}", sema.diagnostics);

        let mid = graph.lookup("M").unwrap();
        let ir = lower_module(&graph, mid, &sema, MemoryMode::NoGc).unwrap();
        let body = ir.funcs.last().unwrap();

        let cast_count = body
            .blocks
            .iter()
            .flat_map(|block| block.insts.iter())
            .filter(|inst| matches!(inst, Inst::Cast { .. }))
            .count();
        let has_transfer_call = body
            .blocks
            .iter()
            .flat_map(|block| block.insts.iter())
            .any(|inst| matches!(inst, Inst::Const { val: ConstVal::FuncRef(name), .. } if name == "VAL" || name == "SYSTEM.CAST" || name == "CAST"));

        assert!(cast_count >= 2, "expected transfer builtins to lower as IR casts");
        assert!(!has_transfer_call, "transfer builtins should not lower as function references");
    }
}
