//! End-to-end proof that a *generated* Win32 `.def` module — produced by
//! `newm2-winapi-gen` from windows_api.db — materializes a real DLL call
//! through the JIT, in isolation from the shared ADW `def_out` tree.

#![cfg(windows)]

use std::path::{Path, PathBuf};

use newm2_ir::{MemoryMode, lower_module};
use newm2_lexer::Env;
use newm2_llvm::{CodegenOptions, run_modules};
use newm2_loader::{
    SearchPath, build_module_graph_with_env_and_pack, win32_finder::build_win32_finder,
};
use newm2_runtime::{nm2_test_capture_drain, nm2_test_capture_start};
use newm2_sema::check_module_graph;
use newm2_winapi_gen::{db, generate_namespace, generate_win32_base};

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .find(|p| p.join("Mod").is_dir())
        .expect("workspace root (contains Mod/)")
        .to_path_buf()
}

fn locate_windows_api_db() -> Option<PathBuf> {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .map(|p| p.join("windows_api").join("windows_api.db"))
        .find(|p| p.is_file())
}

fn push_library_def_dirs(sp: &mut SearchPath, library: &Path) {
    if let Ok(entries) = std::fs::read_dir(library) {
        let mut dirs: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.is_dir()
                    && p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.ends_with("def"))
            })
            .collect();
        dirs.sort();
        for d in dirs {
            sp.push(d);
        }
    }
}

/// Generate `WIN32` + the given namespaces, build a pack, and JIT-run a program
/// that calls the generated `GetCurrentProcessId`. Returns its captured output,
/// or `None` if the metadata DB isn't present. Panics on any pipeline error.
fn run_generated_pid(namespaces: &[&str], tag: &str) -> Option<String> {
    let db_path = locate_windows_api_db()?;
    let ws = workspace_root();
    let conn = db::open(db_path.to_str().unwrap()).expect("open windows_api.db");

    let tmp = std::env::temp_dir().join(format!("nm2-winapi-gen-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    let def_out = tmp.join("windows_api").join("def_out").join("gen");
    std::fs::create_dir_all(&def_out).unwrap();
    std::fs::write(def_out.join("WIN32_types.def"), generate_win32_base()).unwrap();

    let ns_list: Vec<String> = namespaces.iter().map(|ns| ns.to_string()).collect();
    let index = newm2_winapi_gen::build_cross_index(&conn, &ns_list).expect("build cross index");
    for ns in namespaces {
        let g = generate_namespace(&conn, ns, &index).expect("generate namespace");
        let module = newm2_winapi_gen::module_name_for(ns);
        std::fs::write(def_out.join(format!("{module}_types.def")), &g.text).unwrap();
    }

    // Index the generated defs with the def finder (the same mechanism the
    // driver uses over library/NewM2), then resolve Win32 modules through it.
    let finder = build_win32_finder(&def_out).expect("build win32 finder");

    let program = tmp.join("WinGenSmoke.mod");
    std::fs::write(
        &program,
        "MODULE WinGenSmoke;\n\
         FROM System_Threading IMPORT GetCurrentProcessId;\n\
         FROM STextIO IMPORT WriteString;\n\
         FROM WholeStr IMPORT CardToStr;\n\
         VAR buf : ARRAY [0..31] OF CHAR;\n\
         BEGIN\n\
         \x20 CardToStr(VAL(CARDINAL, GetCurrentProcessId()), buf);\n\
         \x20 WriteString(buf)\n\
         END WinGenSmoke.\n",
    )
    .unwrap();

    let mut sp = SearchPath::new();
    sp.push(tmp.clone());
    push_library_def_dirs(&mut sp, &ws.join("library"));

    let graph =
        build_module_graph_with_env_and_pack(&program, &sp, &Env::target_default(), Some(&finder))
            .expect("build module graph");

    let sema = check_module_graph(&graph);
    if sema.has_errors() {
        let msgs: Vec<_> = sema
            .diagnostics
            .iter()
            .map(|d| {
                let node = graph.get(d.module_id);
                format!("{}:{}: {}", node.name, d.span.start.line, d.message)
            })
            .collect();
        panic!("sema errors:\n{}", msgs.join("\n"));
    }

    let mode = MemoryMode::NoGc;
    let entry_mid = *graph.topo_order.last().unwrap();
    let entry_name = graph.get(entry_mid).name.clone();
    let lowered: Vec<_> =
        graph.topo_order.iter().filter_map(|&mid| lower_module(&graph, mid, &sema, mode)).collect();
    let lowered_refs: Vec<_> = lowered.iter().collect();

    nm2_test_capture_start();
    let result = run_modules(
        &lowered_refs,
        &entry_name,
        &sema,
        CodegenOptions { memory_mode: mode, opt_level: 0, aot: false, m2_heap: false, protect_heap: false },
    );
    let output = nm2_test_capture_drain();
    result.expect("JIT run");
    let _ = std::fs::remove_dir_all(&tmp);
    Some(output)
}

const FULL_SUBSET: &[&str] = &[
    "Windows.Win32.Foundation",
    "Windows.Win32.UI.WindowsAndMessaging",
    "Windows.Win32.System.Console",
    "Windows.Win32.System.Registry",
    "Windows.Win32.Graphics.Gdi",
    "Windows.Win32.System.LibraryLoader",
    "Windows.Win32.System.Threading",
];

/// Fast core proof: a single generated module makes a real, correctly-typed
/// JIT'd OS call. MCJIT runs in-process so the result must equal our own PID.
#[test]
fn generated_win32_module_calls_into_os() {
    let Some(output) = run_generated_pid(&["Windows.Win32.System.Threading"], "solo") else {
        eprintln!("skipping: windows_api.db not found");
        return;
    };
    assert_eq!(output.trim(), std::process::id().to_string(), "got {output:?}");
}

/// Comprehensive: the whole generated ADW subset (cross-namespace struct/enum
/// references and all) links and runs together. Slow (sema-checks ~7 large
/// generated modules); run with `--ignored`.
#[test]
#[ignore = "full generated subset; ~80s"]
fn generated_full_subset_links_and_runs() {
    let Some(output) = run_generated_pid(FULL_SUBSET, "full") else {
        eprintln!("skipping: windows_api.db not found");
        return;
    };
    assert_eq!(output.trim(), std::process::id().to_string(), "got {output:?}");
}
