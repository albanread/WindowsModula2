//! JIT integration test harness for NewM2.
//!
//! [`run_m2`] compiles a `.mod` file through the full pipeline and returns
//! the captured I/O output as a `String`.  All tests run at opt-level 0 and
//! in GC mode by default (pass `--no-gc` via `MemoryMode::NoGc` if needed).
//!
//! ## How capture works
//! We control the `STextIO.WriteString` / `SWholeIO.WriteInt` / … bindings
//! in the JIT — they write to a thread-local buffer instead of stdout.
//! `nm2_test_capture_start` arms the buffer; `nm2_test_capture_drain` returns
//! the accumulated text and disarms it.

pub mod testdb;

use std::path::{Path, PathBuf};

pub use newm2_ir::MemoryMode;

/// Absolute path to `Mod/tests/` next to the workspace root.
pub fn tests_dir() -> PathBuf {
    // CARGO_MANIFEST_DIR = …/tests/newm2-tests
    // workspace root     = …/NewM2
    // Mod/tests          = …/NewM2/Mod/tests
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .ancestors()
        .find(|p| p.join("Mod").is_dir())
        .expect("workspace root (contains Mod/) not found")
        .join("Mod")
        .join("tests")
}

/// Run a single `.mod` file through the JIT at a specific opt-level, returning
/// both the captured stdout text and the process exit status (0 normally; a
/// `HALT(n)` carries `n`, bare `HALT` is 1).
pub fn run_m2_status_with_opt(
    mod_path: &Path,
    mode: MemoryMode,
    opt_level: u32,
) -> Result<(String, i32), String> {
    run_m2_status_full(mod_path, mode, opt_level, false)
}

/// As [`run_m2_status_with_opt`] but with control over `--m2-heap`: when
/// `m2_heap` is set, the `Heap` module is force-linked and NEW/DISPOSE lower to
/// `Heap.Alloc` / `Heap.Free` (the self-hosted M2 allocator).
pub fn run_m2_status_full(
    mod_path: &Path,
    mode: MemoryMode,
    opt_level: u32,
    m2_heap: bool,
) -> Result<(String, i32), String> {
    use newm2_ir::lower_module;
    use newm2_llvm::{CodegenOptions, run_modules};
    use newm2_loader::{SearchPath, build_module_graph_with_extra_roots};
    use newm2_lexer::Env;
    use newm2_runtime::{nm2_test_capture_drain, nm2_test_capture_start};
    use newm2_sema::check_module_graph;

    // Build search path: Mod/tests/ + the standard ADW reference subdirs.
    let mut sp = SearchPath::new();
    if let Some(parent) = mod_path.parent() {
        sp.push(parent);
    }
    if let Some(root) = locate_library_root(mod_path) {
        push_library_def_dirs(&mut sp, &root);
    }
    // Locate ADW reference tree at <workspace>/../ADW reference
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    if let Some(root) = manifest
        .ancestors()
        .find(|p| p.join("Mod").is_dir())
        .and_then(|ws| ws.parent())
        .map(|p| p.join("ADW reference"))
    {
        for sub in ["isodef", "def", "gldef"] {
            let dir = root.join(sub);
            if dir.is_dir() {
                sp.push(dir);
            }
        }
    }

    let win32_finder = win32_finder_for(mod_path)?;

    let extra: &[&str] = if m2_heap { &["Heap"] } else { &[] };
    let graph = build_module_graph_with_extra_roots(mod_path, &sp, &Env::target_default(), win32_finder, extra)
        .map_err(|e| format!("loader: {e}"))?;

    let sema = check_module_graph(&graph);
    if sema.has_errors() {
        let msgs: Vec<_> = sema.diagnostics.iter().map(|d| {
            let node = graph.get(d.module_id);
            format!("{}:{}: error: {}", node.name, d.span.start.line, d.message)
        }).collect();
        return Err(msgs.join("\n"));
    }

    let opts = CodegenOptions { memory_mode: mode, opt_level, aot: false, m2_heap };
    let entry_mid = *graph.topo_order.last()
        .ok_or("empty topo order")?;
    let entry_name = graph.get(entry_mid).name.clone();
    let lowered: Vec<_> = graph
        .topo_order
        .iter()
        .filter_map(|&mid| lower_module(&graph, mid, &sema, mode))
        .collect();
    let lowered_refs: Vec<_> = lowered.iter().collect();

    nm2_test_capture_start();

    let result = run_modules(&lowered_refs, &entry_name, &sema, opts);
    let output = nm2_test_capture_drain();
    let code = result.map_err(|e| format!("JIT: {e}"))?;
    Ok((output, code))
}

/// Run a single `.mod` file through the JIT at a specific opt-level.
///
/// Returns the captured stdout text on success, or a descriptive error
/// string on failure (so tests can call `unwrap` for a clear message).
pub fn run_m2_with_opt(mod_path: &Path, mode: MemoryMode, opt_level: u32) -> Result<String, String> {
    run_m2_status_with_opt(mod_path, mode, opt_level).map(|(out, _)| out)
}

/// Run a single `.mod` file through the JIT at opt-level 0.
pub fn run_m2(mod_path: &Path, mode: MemoryMode) -> Result<String, String> {
    run_m2_with_opt(mod_path, mode, 0)
}

/// Convenience: run a test file from `Mod/tests/` by numbered name.
/// Manual memory is the default model.
pub fn run_test(filename: &str) -> Result<String, String> {
    run_m2(&tests_dir().join(filename), MemoryMode::NoGc)
}

/// Convenience: run a test file from `Mod/tests/` returning `(stdout, status)`.
pub fn run_test_status(filename: &str) -> Result<(String, i32), String> {
    run_m2_status_with_opt(&tests_dir().join(filename), MemoryMode::NoGc, 0)
}

/// Convenience: run a test file from `Mod/tests/` (manual mode) at O2.
pub fn run_test_o2(filename: &str) -> Result<String, String> {
    run_m2_with_opt(&tests_dir().join(filename), MemoryMode::NoGc, 2)
}

/// Convenience: run a test file with `--m2-heap` — NEW/DISPOSE routed through
/// the self-hosted M2 `Heap` (force-linked, codegen targets Heap.Alloc/Free).
pub fn run_test_m2heap(filename: &str) -> Result<String, String> {
    run_m2_status_full(&tests_dir().join(filename), MemoryMode::NoGc, 0, true).map(|(out, _)| out)
}

/// Convenience: run a test file in NoGc mode.
pub fn run_test_nogc(filename: &str) -> Result<String, String> {
    run_m2(&tests_dir().join(filename), MemoryMode::NoGc)
}

/// Convenience: run a test file in GC mode. Only meaningful with the `gc`
/// feature (the collector must be compiled in to bind its runtime helpers).
#[cfg(feature = "gc")]
pub fn run_test_gc(filename: &str) -> Result<String, String> {
    run_m2(&tests_dir().join(filename), MemoryMode::Gc)
}

/// Convenience: type-check a test file from `Mod/tests/` without codegen.
pub fn check_test(filename: &str) -> Result<(), String> {
    check_m2(&tests_dir().join(filename))
}

/// Convenience: type-check a test file with `--strict` pedantic checks enabled.
pub fn check_test_strict(filename: &str) -> Result<(), String> {
    check_m2_strict(&tests_dir().join(filename))
}

/// Run loader + sema on a single `.mod` file without JIT codegen.
pub fn check_m2(mod_path: &Path) -> Result<(), String> {
    check_m2_impl(mod_path, false)
}

/// Like [`check_m2`] but with the driver's `--strict` pedantic static checks on.
pub fn check_m2_strict(mod_path: &Path) -> Result<(), String> {
    check_m2_impl(mod_path, true)
}

fn check_m2_impl(mod_path: &Path, strict: bool) -> Result<(), String> {
    use newm2_loader::{SearchPath, build_module_graph_with_env_and_pack};
    use newm2_lexer::Env;
    use newm2_sema::{check_module_graph, check_module_graph_strict};

    let mut sp = SearchPath::new();
    if let Some(parent) = mod_path.parent() {
        sp.push(parent);
    }
    if let Some(root) = locate_library_root(mod_path) {
        push_library_def_dirs(&mut sp, &root);
    }

    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    if let Some(root) = manifest
        .ancestors()
        .find(|p| p.join("Mod").is_dir())
        .and_then(|ws| ws.parent())
        .map(|p| p.join("ADW reference"))
    {
        for sub in ["isodef", "def", "gldef"] {
            let dir = root.join(sub);
            if dir.is_dir() {
                sp.push(dir);
            }
        }
    }

    let win32_finder = win32_finder_for(mod_path)?;

    let graph = build_module_graph_with_env_and_pack(mod_path, &sp, &Env::target_default(), win32_finder)
        .map_err(|e| format!("loader: {e}"))?;

    let sema = if strict {
        check_module_graph_strict(&graph, true)
    } else {
        check_module_graph(&graph)
    };
    if sema.has_errors() {
        let msgs: Vec<_> = sema.diagnostics.iter().map(|d| {
            let node = graph.get(d.module_id);
            format!("{}:{}: error: {}", node.name, d.span.start.line, d.message)
        }).collect();
        return Err(msgs.join("\n"));
    }

    Ok(())
}

/// The Win32 def finder (baked into the binary at build time) over
/// `library/NewM2`, used so Win32 API modules resolve authoritatively through
/// the index rather than a same-named file on the search path.
fn win32_finder_for(
    mod_path: &Path,
) -> Result<Option<&'static newm2_loader::win32_finder::Win32Finder>, String> {
    let Some(library_root) = locate_library_root(mod_path) else {
        return Ok(None);
    };
    let newm2 = library_root.join("NewM2");
    if !newm2.is_dir() {
        return Ok(None);
    }
    Ok(Some(newm2_loader::win32_finder::embedded_finder(&newm2)))
}

fn locate_library_root(entry: &Path) -> Option<PathBuf> {
    for ancestor in entry.ancestors() {
        let candidate = ancestor.join("library");
        if candidate.is_dir() {
            return Some(candidate);
        }
    }
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for ancestor in manifest.ancestors() {
        let candidate = ancestor.join("library");
        if candidate.is_dir() {
            return Some(candidate);
        }
    }
    None
}

fn push_library_def_dirs(sp: &mut newm2_loader::SearchPath, root: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };

    let mut dirs = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        // `*def` reference dirs, plus `NewM2` (our generated Win32 API defs).
        // The ADW subtree (`library/ADW`) is deliberately excluded.
        if name.ends_with("def") || name == "NewM2" {
            dirs.push(path);
        }
    }

    dirs.sort();
    for dir in dirs {
        sp.push(dir);
    }
}
