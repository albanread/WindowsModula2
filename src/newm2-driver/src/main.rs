use std::env;
use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::path::Path;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::Ordering;

use newm2_ir::{format_cfg, format_ir, lower_module, lower_module_opts, MemoryMode};
use newm2_lexer::{Env, LiteralFlavor, StringLiteral, format_tokens, preprocess, tokenize};
use newm2_llvm::{CodegenOptions, emit_asm, emit_llvm_ir};
use newm2_loader::{
    SearchPath,
    build_module_graph_with_env_and_pack,
    format_graph,
    win32_finder::{Win32Finder, embedded_finder},
};
use newm2_parser::ast::{Decl, Module, ProcDecl, ProcExternalLinkage};
use newm2_parser::{format_module, format_types_module_with_env, parse_module};
use newm2_runtime::HEAP_STATS;
use newm2_sema::{check_module_graph, export_interface, format_module_interface, format_sema};
use rusqlite::{Connection, params};

mod server;

const COMMANDS: &[&str] = &[
    "dump-tokens",
    "dump-ast",
    "parsedef",
    "dump-module-graph",
    "dump-sema",
    "dump-interface",
    "timings",
    "dump-cfg",
    "dump-ir",
    "dump-llvm",
    "dump-asm",
    "dump-heap",
    "check",
    "analyze",
    "complete",
    "describe",
    "run",
    "build",
    "daemon",
    "build-stdlib",
    "fmt",
    "deps",
    "doc",
    "edit",
];

const GLOBAL_FLAGS: &[&str] = &[
    "--adw-win64-unicode",
    "--library",
    "--out",
    "--windows",
    "--win-source",
    "--no-runtime-checks",
    "--strict",
    "--gui",
    "--opt",
    "--no-gc",
    "--gc",
    "--m2-heap",
    "--protect-heap",
    "--sanitize",
    "--no-cache",
    "--cache",
    "--manifest",
    "--no-manifest",
    "--ref-allow-impl",
    "--types-out",
    "--define",
    "-O0",
    "-O1",
    "-O2",
    "-O3",
];

/// Which Win32 `.def` source the windows pack is built from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WinSource {
    /// The ADW-derived defs in `windows_api/def_out`.
    Adw,
    /// Our own generated defs in `windows_api/def_out_gen`.
    Generated,
}

impl WinSource {
    /// (def_out subdirectory, pack filename) for this source.
    fn paths(self) -> (&'static str, &'static str) {
        match self {
            WinSource::Adw => ("def_out", "windows_api.pack"),
            WinSource::Generated => ("def_out_gen", "windows_api_gen.pack"),
        }
    }
}

/// The built-in default application manifest embedded into GUI `.exe`s when no
/// `--manifest`/`--no-manifest` is given. Deliberately CONSERVATIVE so it is safe
/// for *every* GUI program: it enables modern themed controls (Common Controls v6,
/// which also gives dialogs Segoe UI) and declares Windows 7–11 support, but it does
/// NOT declare DPI awareness — an app that is not DPI-ready would render with a
/// broken layout if forced aware. Apps that ARE DPI-ready (e.g. FastPanesM2) supply
/// their own manifest via `--manifest`.
const DEFAULT_GUI_MANIFEST: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <dependency>
    <dependentAssembly>
      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls"
                        version="6.0.0.0" processorArchitecture="amd64"
                        publicKeyToken="6595b64144ccf1df" language="*"/>
    </dependentAssembly>
  </dependency>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
    </windowsSettings>
  </application>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
      <supportedOS Id="{1f676c76-80e1-4239-95bb-83d0f6d0da78}"/>
      <supportedOS Id="{4a2f28e3-53b9-4441-ba9c-d69d4a4a6e38}"/>
      <supportedOS Id="{35138b9a-5d96-4fbd-8e2d-a2440225f93a}"/>
    </application>
  </compatibility>
</assembly>
"#;

/// What application manifest to embed into an AOT `.exe`.
#[derive(Debug, Clone)]
enum ManifestMode {
    /// No `--manifest`/`--no-manifest`: embed `DEFAULT_GUI_MANIFEST` for GUI builds,
    /// nothing for console builds.
    Default,
    /// `--manifest PATH`: embed this manifest file (any subsystem).
    Custom(PathBuf),
    /// `--no-manifest`: embed nothing.
    None,
}

#[derive(Debug, Clone)]
struct DriverOptions {
    env: Env,
    windows: bool,
    win_source: WinSource,
    library_paths: Vec<PathBuf>,
    /// Emit ISO runtime checks (array index, …). On by default.
    runtime_checks: bool,
    /// `--strict`: enable pedantic static checks (e.g. a compile-time-constant
    /// index proven out of bounds). OFF by default — the dialect is deliberately
    /// lenient; lenient builds still catch these at run time.
    strict: bool,
    /// `--gui`: link the `.exe` for the Windows GUI subsystem (no console window
    /// is allocated when it runs). Keeps the normal `main` entry via
    /// `/ENTRY:mainCRTStartup`. Off by default (console apps). For windowed apps.
    gui: bool,
    /// `--out PATH`: output file for `build` (the `.exe`). Defaults to the
    /// entry file's stem with a `.exe` suffix.
    out: Option<PathBuf>,
    /// `--m2-heap`: route NEW/DISPOSE through the self-hosted Modula-2 `Heap`
    /// (force-linked) instead of the Rust runtime allocator. Off by default.
    m2_heap: bool,
    /// `--protect-heap`: enable the runtime heap guard (a counting Bloom filter of
    /// live allocations) — catches double/invalid frees and reports leaks at exit.
    /// For `run` (JIT) it sets NM2_PROTECT_HEAP in-process; AOT exes honor that env var.
    protect_heap: bool,
    /// `--cache`: use the separate-compilation symbol cache (re-intern unchanged
    /// module interfaces instead of re-checking them). Off by default.
    cache: bool,
    /// `--stdlib PATH`: at `build` time, link against a prebuilt standard library
    /// (a `.lib` + sidecar `.manifest` from `build-stdlib`) instead of lowering
    /// the ISO library from source.
    stdlib: Option<PathBuf>,
    /// `--manifest PATH` / `--no-manifest`: the Windows application manifest to embed
    /// into the AOT `.exe` (modern themed controls + DPI awareness, etc.). Default:
    /// embed a conservative modern-controls manifest for GUI builds. See [`ManifestMode`].
    manifest: ManifestMode,
}

impl DriverOptions {
    fn parse(raw_args: &[String]) -> Result<Self, String> {
        let mut env = Env::target_default();
        let mut windows = false;
        let mut win_source = WinSource::Adw;
        let mut library_paths = Vec::new();
        let mut runtime_checks = true;
        let mut strict = false;
        let mut gui = false;
        let mut out: Option<PathBuf> = None;
        let mut m2_heap = false;
        let mut protect_heap = false;
        let mut cache = false;
        let mut stdlib: Option<PathBuf> = None;
        let mut manifest = ManifestMode::Default;
        let mut index = 0usize;
        while index < raw_args.len() {
            if raw_args[index] == "--adw-win64-unicode" {
                env = Env::adw_win64_unicode();
                index += 1;
            } else if raw_args[index] == "--library" {
                let Some(path) = raw_args.get(index + 1) else {
                    return Err("--library expects a directory path".into());
                };
                library_paths.push(PathBuf::from(path));
                index += 2;
            } else if raw_args[index] == "--windows" {
                windows = true;
                index += 1;
            } else if raw_args[index] == "--no-runtime-checks" {
                runtime_checks = false;
                index += 1;
            } else if raw_args[index] == "--strict" {
                strict = true;
                index += 1;
            } else if raw_args[index] == "--gui" {
                gui = true;
                index += 1;
            } else if raw_args[index] == "--m2-heap" {
                m2_heap = true;
                index += 1;
            } else if raw_args[index] == "--protect-heap" {
                protect_heap = true;
                index += 1;
            } else if raw_args[index] == "--cache" {
                cache = true;
                index += 1;
            } else if raw_args[index] == "--stdlib" {
                let Some(path) = raw_args.get(index + 1) else {
                    return Err("--stdlib expects a .lib path".into());
                };
                stdlib = Some(PathBuf::from(path));
                index += 2;
            } else if raw_args[index] == "--manifest" {
                let Some(path) = raw_args.get(index + 1) else {
                    return Err("--manifest expects a .manifest file path".into());
                };
                manifest = ManifestMode::Custom(PathBuf::from(path));
                index += 2;
            } else if let Some(value) = raw_args[index].strip_prefix("--manifest=") {
                manifest = ManifestMode::Custom(PathBuf::from(value));
                index += 1;
            } else if raw_args[index] == "--no-manifest" {
                manifest = ManifestMode::None;
                index += 1;
            } else if let Some(value) = raw_args[index].strip_prefix("--win-source=") {
                win_source = parse_win_source(value)?;
                windows = true;
                index += 1;
            } else if raw_args[index] == "--win-source" {
                let Some(value) = raw_args.get(index + 1) else {
                    return Err("--win-source expects 'adw' or 'generated'".into());
                };
                win_source = parse_win_source(value)?;
                windows = true;
                index += 2;
            } else if raw_args[index] == "--define" {
                let Some(spec) = raw_args.get(index + 1) else {
                    return Err("--define expects NAME, KEY:VALUE, or KEY=VALUE".into());
                };
                apply_define(&mut env, spec)?;
                index += 2;
            } else if raw_args[index] == "--out" {
                let Some(path) = raw_args.get(index + 1) else {
                    return Err("--out expects a file path".into());
                };
                out = Some(PathBuf::from(path));
                index += 2;
            } else if let Some(value) = raw_args[index].strip_prefix("--out=") {
                out = Some(PathBuf::from(value));
                index += 1;
            } else {
                index += 1;
            }
        }
        Ok(Self {
            env,
            windows,
            win_source,
            library_paths,
            runtime_checks,
            strict,
            gui,
            out,
            m2_heap,
            protect_heap,
            cache,
            stdlib,
            manifest,
        })
    }
}

/// The symbol-cache configuration for this compile, or `None` when `--cache`
/// is off. The on-disk store lives under the system temp dir.
fn cache_config(options: &DriverOptions) -> Option<newm2_sema::CacheConfig> {
    if !options.cache {
        return None;
    }
    Some(newm2_sema::CacheConfig {
        dir: std::env::temp_dir().join("newm2-iface-cache"),
        codegen_flags: String::new(),
        memory_mode: newm2_loader::MemoryMode::Gc,
        read: true,
        write: true,
    })
}

/// Run semantic analysis, with the symbol cache if `--cache` is set.
fn check_graph(graph: &newm2_loader::ModuleGraph, options: &DriverOptions) -> newm2_sema::SemaResult {
    match cache_config(options) {
        Some(cfg) => newm2_sema::check_module_graph_cached_strict(graph, &cfg, options.strict),
        None => newm2_sema::check_module_graph_strict(graph, options.strict),
    }
}

fn parse_win_source(value: &str) -> Result<WinSource, String> {
    match value {
        "adw" => Ok(WinSource::Adw),
        "generated" | "gen" => Ok(WinSource::Generated),
        other => Err(format!("--win-source must be 'adw' or 'generated', got {other:?}")),
    }
}

fn apply_define(env: &mut Env, spec: &str) -> Result<(), String> {
    let (name, value) = if let Some((name, value)) = spec.split_once('=') {
        (name.trim(), value.trim())
    } else if let Some((name, value)) = spec.split_once(':') {
        (name.trim(), value.trim())
    } else {
        (spec.trim(), "true")
    };
    if name.is_empty() {
        return Err(format!("invalid empty define name in {spec:?}"));
    }
    env.define_value(name, value);
    Ok(())
}

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        print_usage();
        return ExitCode::SUCCESS;
    };
    let rest: Vec<String> = args.collect();

    if !COMMANDS.contains(&command.as_str()) {
        eprintln!("newm2: unknown command '{command}'");
        print_usage();
        return ExitCode::from(2);
    }

    // The resident compiler service runs its own arg parse + server loop.
    if command == "daemon" {
        return server::run_daemon(&rest);
    }

    let options = match DriverOptions::parse(&rest) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("newm2: {message}");
            return ExitCode::from(2);
        }
    };

    // Separate file paths from flags so flag order doesn't matter.
    let mut paths: Vec<PathBuf> = Vec::new();
    let mut skip_next = false;
    for arg in &rest {
        if skip_next {
            skip_next = false;
            continue;
        }
        if arg == "--define" || arg == "--out" || arg == "--library" || arg == "--win-source"
            || arg == "--stdlib" || arg == "--opt" || arg == "--manifest"
        {
            skip_next = true;
            continue;
        }
        if arg.starts_with('-') {
            // Flags are parsed but otherwise ignored here.
        } else {
            paths.push(PathBuf::from(arg));
        }
    }

    match command.as_str() {
        "dump-tokens" => run_dump_tokens(&paths, &options.env),
        "dump-ast" => run_dump_ast(&paths, &options.env),
        "parsedef" => run_parse_def(&paths, &rest, &options.env),
        "dump-module-graph" => run_dump_module_graph(&paths, &options),
        "dump-sema" => run_dump_sema(&paths, &options),
        "dump-interface" => run_dump_interface(&paths, &options),
        "timings" => run_timings(&paths, &options),
        "dump-ir" => run_dump_ir(&paths, &rest, &options),
        "dump-cfg" => run_dump_cfg(&paths, &rest, &options),
        "dump-llvm" => run_dump_llvm(&paths, &rest, &options),
        "dump-asm" => run_dump_asm(&paths, &rest, &options),
        "check" => run_check(&paths, &options),
        "analyze" => run_analyze(&paths, &options),
        "complete" => run_complete(&paths, &options),
        "describe" => run_describe(&paths, &options),
        "run" => run_run(&paths, &rest, &options),
        "build" => run_build(&paths, &rest, &options),
        "build-stdlib" => run_build_stdlib(&options, &rest),
        "dump-heap" => run_dump_heap(&paths, &rest, &options),
        _ => {
            // Stub: not implemented yet.
            println!("TODO: newm2 {command}");
            ExitCode::SUCCESS
        }
    }
}

/// Build the default search path: the directory containing the entry
/// file (so adjacent `.def` siblings resolve), then the ADW reference
/// tree if present alongside the workspace.
fn default_search_path(entry: &Path, windows: bool, library_paths: &[PathBuf]) -> SearchPath {
    let mut sp = SearchPath::new();
    if let Some(parent) = entry.parent() {
        sp.push(parent);
    }

    for root in explicit_and_default_library_roots(entry, library_paths) {
        push_library_def_dirs(&mut sp, &root);
    }

    // If the entry file itself lives inside the ADW reference tree,
    // add all sibling sub-directories so cross-folder imports resolve.
    // We detect this by walking up looking for a directory whose name
    // case-insensitively equals "ADW reference".
    let adw_root: Option<std::path::PathBuf> = {
        let mut dir = entry.parent().and_then(|p| p.parent());
        let mut found = None;
        while let Some(d) = dir {
            let name = d.file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("");
            if name.eq_ignore_ascii_case("ADW reference") {
                found = Some(d.to_path_buf());
                break;
            }
            dir = d.parent();
        }
        found
    };

    // Also try to locate `<workspace-root>/../ADW reference/` from CWD.
    let cwd_adw_root: Option<std::path::PathBuf> = std::env::current_dir().ok()
        .and_then(|cwd| cwd.parent().map(|p| p.join("ADW reference")))
        .filter(|p| p.is_dir());

    let root = adw_root.or(cwd_adw_root);

    if let Some(ref root) = root {
        let adw_subdirs: &[&str] = if windows {
            &["isodef", "def", "gldef"]
        } else {
            &["isodef", "def", "gldef", "win32def", "win32apidef", "advapidef"]
        };
        for sub in adw_subdirs {
            let dir = root.join(sub);
            if dir.is_dir() {
                sp.push(dir);
            }
        }
    }
    sp
}

fn explicit_and_default_library_roots(entry: &Path, library_paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    let mut seen = BTreeSet::new();

    for path in library_paths {
        let candidate = if path.is_absolute() {
            path.clone()
        } else {
            std::env::current_dir()
                .unwrap_or_else(|_| PathBuf::from("."))
                .join(path)
        };
        if candidate.is_dir() && seen.insert(candidate.clone()) {
            roots.push(candidate);
        }
    }

    if let Some(default_root) = locate_library_root(entry) {
        if seen.insert(default_root.clone()) {
            roots.push(default_root);
        }
    }

    roots
}

fn locate_library_root(entry: &Path) -> Option<PathBuf> {
    for ancestor in entry.ancestors() {
        let candidate = ancestor.join("library");
        if candidate.is_dir() {
            return Some(candidate);
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        for ancestor in cwd.ancestors() {
            let candidate = ancestor.join("library");
            if candidate.is_dir() {
                return Some(candidate);
            }
        }
    }
    None
}

fn push_library_def_dirs(sp: &mut SearchPath, root: &Path) {
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
        // `*def` subdirs hold reference DEF modules; `NewM2` holds our own
        // generated Win32 API definitions (flat `<Module>_types.def` files).
        // The ADW subtree (`library/ADW/…`) is intentionally NOT picked up
        // here — it carries third-party (ADW Software) copyright and is opt-in
        // only, via an explicit `--library library/ADW` root.
        if name.ends_with("def") || name == "NewM2" {
            dirs.push(path);
        }
    }
    dirs.sort();
    for dir in dirs {
        sp.push(dir);
    }
}

fn locate_windows_api_root(entry: &Path) -> Option<PathBuf> {
    let has_defs = |root: &Path| root.join("def_out").is_dir() || root.join("def_out_gen").is_dir();
    for ancestor in entry.ancestors() {
        let root = ancestor.join("windows_api");
        if has_defs(&root) {
            return Some(root);
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        for ancestor in cwd.ancestors() {
            let root = ancestor.join("windows_api");
            if has_defs(&root) {
                return Some(root);
            }
        }
    }
    None
}

fn win32_finder_for(entry: &Path, options: &DriverOptions) -> Option<&'static Win32Finder> {
    if !options.windows {
        return None;
    }
    // The Win32 def finder is a sorted symbol index baked into the binary at
    // build time (see newm2-loader/build.rs): a binary search maps a module /
    // procedure / type / constant name to the one def that declares it, which is
    // then parsed on demand. The index needs no file and no disk read; only the
    // handful of defs a program actually imports are touched. `newm2_root` is
    // where the relative def paths are resolved against at load time.
    let newm2_root = locate_newm2_root(entry)?;
    Some(embedded_finder(&newm2_root))
}

/// Locate the committed `library/NewM2` tree (our generated Win32 API defs),
/// walking up from the entry file and then the CWD.
fn locate_newm2_root(entry: &Path) -> Option<PathBuf> {
    let found = |root: PathBuf| root.is_dir().then_some(root);
    for ancestor in entry.ancestors() {
        if let Some(r) = found(ancestor.join("library").join("NewM2")) {
            return Some(r);
        }
    }
    let cwd = std::env::current_dir().ok()?;
    for ancestor in cwd.ancestors() {
        if let Some(r) = found(ancestor.join("library").join("NewM2")) {
            return Some(r);
        }
    }
    None
}

fn build_graph_from_entry(
    entry: &Path,
    options: &DriverOptions,
) -> Result<newm2_loader::ModuleGraph, newm2_loader::LoadError> {
    let sp = default_search_path(entry, options.windows, &options.library_paths);
    let win32_finder = win32_finder_for(entry, options);
    // --m2-heap: force-link the self-hosted Heap module (codegen routes
    // NEW/DISPOSE to Heap.Alloc/Heap.Free) even if the program never imports it.
    let extra_roots: &[&str] = if options.m2_heap { &["Heap"] } else { &[] };
    newm2_loader::build_module_graph_with_extra_roots(
        entry,
        &sp,
        &options.env,
        win32_finder,
        extra_roots,
    )
}

fn run_dump_module_graph(paths: &[PathBuf], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 dump-module-graph: expected a file argument");
        return ExitCode::from(2);
    };
    match build_graph_from_entry(entry, options) {
        Ok(g) => {
            print!("{}", format_graph(&g));
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("newm2: {e}");
            ExitCode::from(1)
        }
    }
}

fn run_dump_sema(paths: &[PathBuf], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 dump-sema: expected a file argument");
        return ExitCode::from(2);
    };
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let result = check_graph(&graph, options);
    print!("{}", format_sema(&result, &graph));
    if result.has_errors() {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

/// Minimum wall-clock (ms) of `f` over `iters` in-process runs. In-process
/// `Instant` timing — no process-startup or shell-harness noise. Minimum (not
/// mean) because it's the cleanest run, least perturbed by scheduler jitter.
fn min_ms(iters: usize, mut f: impl FnMut()) -> f64 {
    let mut best = f64::MAX;
    for _ in 0..iters {
        let t = std::time::Instant::now();
        f();
        let ms = t.elapsed().as_secs_f64() * 1000.0;
        if ms < best {
            best = ms;
        }
    }
    best
}

/// `newm2 timings FILE` — a reliable per-phase compile-time probe. Each phase is
/// timed in-process as the minimum of several runs, so the numbers are stable
/// and directly comparable (unlike wrapping the whole process in an external
/// timer). Reports graph-build (parse), sema cold vs warm-cache, and IR lower.
fn run_timings(paths: &[PathBuf], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 timings: expected a file argument");
        return ExitCode::from(2);
    };
    const N: usize = 9;
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };

    let g_ms = min_ms(N, || {
        let _ = std::hint::black_box(build_graph_from_entry(entry, options));
    });
    let s_ms = min_ms(N, || {
        let _ = std::hint::black_box(check_module_graph(&graph));
    });

    // Warm-cache sema: populate once, then time read-only re-checks.
    let dir = std::env::temp_dir().join("newm2-timings-cache");
    let _ = std::fs::remove_dir_all(&dir);
    let warm = newm2_sema::CacheConfig {
        dir,
        codegen_flags: String::new(),
        memory_mode: newm2_loader::MemoryMode::Gc,
        read: true,
        write: true,
    };
    let _ = newm2_sema::check_module_graph_cached(&graph, &warm);
    let read_only = newm2_sema::CacheConfig { write: false, ..warm.clone() };
    let sc_ms = min_ms(N, || {
        let _ = std::hint::black_box(newm2_sema::check_module_graph_cached(&graph, &read_only));
    });

    // IR lowering of every module.
    let sema = check_module_graph(&graph);
    let mode = MemoryMode::NoGc;
    let l_ms = min_ms(N, || {
        let lowered: Vec<_> = graph
            .topo_order
            .iter()
            .filter_map(|&m| lower_module(&graph, m, &sema, mode))
            .collect();
        std::hint::black_box(lowered);
    });

    eprintln!("timings for {} ({} modules, min of {N}):", entry.display(), graph.topo_order.len());
    eprintln!("  graph-build (parse all) : {g_ms:8.2} ms");
    eprintln!("  sema  cold              : {s_ms:8.2} ms");
    eprintln!("  sema  warm-cache        : {sc_ms:8.2} ms  ({:+.2} ms vs cold)", sc_ms - s_ms);
    eprintln!("  IR lower (all modules)  : {l_ms:8.2} ms");
    eprintln!("  ── front-end subtotal   : {:8.2} ms (graph + sema cold)", g_ms + s_ms);
    ExitCode::SUCCESS
}

fn run_dump_interface(paths: &[PathBuf], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 dump-interface: expected a file argument");
        return ExitCode::from(2);
    };
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let result = check_graph(&graph, options);
    let (mut cacheable, mut total) = (0usize, 0usize);
    for &mid in &graph.topo_order {
        let node = graph.get(mid);
        if node.is_intrinsic {
            continue;
        }
        total += 1;
        let exportable = export_interface(&result, &graph, mid).is_some();
        if exportable {
            cacheable += 1;
        }
        let tag = if exportable { "cacheable" } else { "not cacheable" };
        println!("=== MODULE {} [{tag}] ===", node.name);
        print!("{}", format_module_interface(&result, &graph, mid));
        println!();
    }
    eprintln!("newm2 dump-interface: {cacheable}/{total} modules cacheable");
    if result.has_errors() {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

/// `analyze` — sema (errors) plus the static NEW/DISPOSE pass (warnings: leak,
/// double-DISPOSE, use-after-DISPOSE). Never fails the build on warnings alone.
fn run_analyze(paths: &[PathBuf], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 analyze: expected a file argument");
        return ExitCode::from(2);
    };
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let result = check_graph(&graph, options);
    let warns = newm2_sema::analyze_new_dispose(&graph);
    let mut all: Vec<&newm2_sema::Diagnostic> = result.diagnostics.iter().chain(warns.iter()).collect();
    all.sort_by_key(|d| (d.module_id.0, d.span.start.line, d.span.start.column));
    for d in &all {
        let sev = match d.severity {
            newm2_sema::Severity::Error => "error",
            newm2_sema::Severity::Warning => "warning",
        };
        let node = graph.get(d.module_id);
        eprintln!("{}:{}: {sev}: {}", node.name, d.span.start.line, d.message);
    }
    if result.has_errors() {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

// ---- autocomplete ---------------------------------------------------------

/// A dummy selector injected after a bare trailing `.` so the (fatal-first)
/// parser still produces an AST; sema flags it as an unknown field, which we
/// ignore — we only need the receiver's type + the module's scopes/types.
const COMPLETE_PLACEHOLDER: &str = "M2xComplete";

/// Find the entry module's id in the graph by matching its source path; falls
/// back to the last topological module (the root dependent).
fn entry_module_id(graph: &newm2_loader::ModuleGraph, path: &Path) -> newm2_loader::ModuleId {
    if let Ok(want) = std::fs::canonicalize(path) {
        for node in &graph.modules {
            for p in [node.impl_path.as_ref(), node.def_path.as_ref()].into_iter().flatten() {
                if std::fs::canonicalize(p).map(|c| c == want).unwrap_or(false) {
                    return node.id;
                }
            }
        }
    }
    graph
        .topo_order
        .last()
        .copied()
        .unwrap_or(newm2_loader::ModuleId(graph.modules.len().saturating_sub(1)))
}

fn complete_sibling_temp(entry: &Path) -> PathBuf {
    entry.parent().unwrap_or_else(|| Path::new(".")).join("__m2complete__.mod")
}

fn is_ident_b(b: u8) -> bool {
    b == b'_' || b.is_ascii_alphanumeric()
}

/// Make a mid-edit buffer parseable by rewriting ONLY the cursor's logical line
/// into a self-contained, terminated statement, leaving the rest untouched.
/// The fatal-first parser otherwise dies on the half-typed line (a bare partial
/// `Write` runs into the next statement; a trailing `rt.` has no selector).
///
/// Returns the repaired source + the new cursor offset (pointing right after the
/// receiver's dot for member access, or at the word start for a bare identifier),
/// from which `complete_at` re-derives the receiver. Client-side prefix filtering
/// in the IDE means we can drop the half-typed word here without losing anything.
fn repair_for_completion(raw: &str, line: usize, col: usize) -> (String, usize) {
    let cursor = newm2_sema::line_col_to_offset(raw, line, col);
    let b = raw.as_bytes();
    let ls = raw[..cursor].rfind('\n').map(|i| i + 1).unwrap_or(0);
    let le = raw[cursor..].find('\n').map(|i| cursor + i).unwrap_or(raw.len());

    let mut ind = ls;
    while ind < le && (b[ind] == b' ' || b[ind] == b'\t') {
        ind += 1;
    }
    let indent = &raw[ls..ind];

    // The partial word ending at the cursor, then whether a `.` precedes it.
    let mut ps = cursor;
    while ps > ls && is_ident_b(b[ps - 1]) {
        ps -= 1;
    }
    let is_member = ps > ls && b[ps - 1] == b'.';

    let (repaired_line, cursor_in_line) = if is_member {
        // Receiver = the ident/`.` run ending at the dot.
        let dot = ps - 1;
        let mut rs = dot;
        while rs > ls && (is_ident_b(b[rs - 1]) || b[rs - 1] == b'.') {
            rs -= 1;
        }
        let receiver = &raw[rs..dot];
        if receiver.is_empty() {
            (indent.to_string(), indent.len()) // no real receiver -> bare
        } else {
            (
                format!("{indent}{receiver}.{COMPLETE_PLACEHOLDER};"),
                indent.len() + receiver.len() + 1, // right after the dot
            )
        }
    } else {
        // Bare identifier: blank the line to whitespace; the cursor's position
        // still selects the enclosing scope, and we enumerate everything in it.
        (indent.to_string(), indent.len())
    };

    let mut out = String::with_capacity(raw.len() + repaired_line.len());
    out.push_str(&raw[..ls]);
    out.push_str(&repaired_line);
    out.push_str(&raw[le..]);
    (out, ls + cursor_in_line)
}

/// Core completion, shared by the `complete` CLI verb and the daemon verb.
/// Reads `file`, repairs the cursor line so the buffer parses, builds the graph +
/// runs sema, and resolves the members visible at (1-based `line`, 0-based
/// `col`). Returns candidates (possibly empty); never panics.
pub(crate) fn complete_core(
    file: &str,
    line: usize,
    col: usize,
    options: &DriverOptions,
) -> Vec<newm2_sema::Completion> {
    let raw = match std::fs::read_to_string(file) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let (source, cursor) = repair_for_completion(&raw, line, col);
    let build_path = complete_sibling_temp(Path::new(file));
    if std::fs::write(&build_path, &source).is_err() {
        return Vec::new();
    }
    let cands = match build_graph_from_entry(&build_path, options) {
        Ok(graph) => {
            let sema = check_graph(&graph, options);
            let mid = entry_module_id(&graph, &build_path);
            newm2_sema::complete_at(&graph, &sema, mid, &source, cursor)
        }
        Err(_) => Vec::new(),
    };
    let _ = std::fs::remove_file(&build_path);
    cands
}

/// `newm2 complete <file> <line> <col>` — prints `name\tkind\tdetail` lines.
fn run_complete(paths: &[PathBuf], options: &DriverOptions) -> ExitCode {
    let Some(file) = paths.first().and_then(|p| p.to_str()) else {
        eprintln!("newm2 complete: expected <file> <line> <col>");
        return ExitCode::from(2);
    };
    let line: usize =
        paths.get(1).and_then(|p| p.to_str()).and_then(|s| s.parse().ok()).unwrap_or(0);
    let col: usize =
        paths.get(2).and_then(|p| p.to_str()).and_then(|s| s.parse().ok()).unwrap_or(0);
    for c in complete_core(file, line, col, options) {
        println!("{}\t{}\t{}", c.name, c.kind, c.detail);
    }
    ExitCode::SUCCESS
}

// ---- context help (describe) ----------------------------------------------

/// Core context-help, shared by the `describe` CLI verb and the daemon verb.
/// Reads `file`, builds the graph + runs sema over the **real** buffer (the
/// span annotations describe must read point into the un-edited source, and the
/// cursor sits on a settled identifier — so unlike `complete` there is no
/// line-repair), resolves the symbol at (1-based `line`, 0-based `col`), and
/// returns markdown. Then enriches a Win32 function with its DLL + docs link
/// from the shared Windows-API DB (graceful — skipped silently when absent).
/// Returns `None` when nothing resolves at the cursor.
pub(crate) fn describe_core(
    file: &str,
    line: usize,
    col: usize,
    options: &DriverOptions,
) -> Option<String> {
    let source = std::fs::read_to_string(file).ok()?;
    let cursor = newm2_sema::line_col_to_offset(&source, line, col);
    let entry = Path::new(file);
    let graph = build_graph_from_entry(entry, options).ok()?;
    let sema = check_graph(&graph, options);
    let mid = entry_module_id(&graph, entry);
    let mut md = newm2_sema::describe_at(&graph, &sema, mid, &source, cursor)?;

    // Driver-side enrichment: if the described symbol's heading names a Win32
    // function present in the shared DB, append its DLL + a Microsoft-docs link.
    if let Some(name) = describe_heading_name(&md) {
        if let Some(extra) = win32_db_enrichment(entry, &name) {
            md.push_str(&extra);
        }
    }
    Some(md)
}

/// The `## Name` heading the describe markdown opens with (the symbol name),
/// for the DB lookup. `None` for the generic `(expression)` heading.
fn describe_heading_name(md: &str) -> Option<String> {
    let first = md.lines().next()?;
    let name = first.strip_prefix("## ")?.trim();
    if name.is_empty() || name.starts_with('(') {
        return None;
    }
    Some(name.to_string())
}

/// Look up `func` in the shared Windows-API DB and, if found, return a markdown
/// `**DLL** … · [Microsoft docs](url)` line. Graceful: `None` if the DB is
/// missing, the function is absent, or any query fails — context help stays
/// fully functional offline without it.
fn win32_db_enrichment(entry: &Path, func: &str) -> Option<String> {
    let db_path = locate_describe_db(entry)?;
    let conn = Connection::open(&db_path).ok()?;
    let mut stmt = conn
        .prepare(
            "SELECT COALESCE(dll_name, ''), COALESCE(documentation_url, '') \
             FROM functions \
             WHERE function_name = ?1 COLLATE NOCASE OR import_name = ?1 COLLATE NOCASE \
             LIMIT 1",
        )
        .ok()?;
    let row: Option<(String, String)> = stmt
        .query_row(params![func], |r| Ok((r.get(0)?, r.get(1)?)))
        .ok();
    let (dll, url) = row?;
    if dll.is_empty() && url.is_empty() {
        return None;
    }
    let mut s = String::from("\n");
    if !dll.is_empty() {
        s.push_str(&format!("**DLL** {}", dll));
    }
    if !url.is_empty() {
        if !dll.is_empty() {
            s.push_str("  ·  ");
        }
        s.push_str(&format!("[Microsoft docs]({})", url));
    }
    s.push('\n');
    Some(s)
}

/// Locate the shared Windows-API DB for describe enrichment. Prefers the
/// well-known absolute path, then the existing `windows_api/windows_api.db`
/// walk-up from the entry file / CWD. Returns the first that exists on disk.
fn locate_describe_db(entry: &Path) -> Option<PathBuf> {
    const WELL_KNOWN: &str = r"E:\windows_api\windows_api.db";
    let well_known = PathBuf::from(WELL_KNOWN);
    if well_known.is_file() {
        return Some(well_known);
    }
    let try_root = |root: PathBuf| -> Option<PathBuf> {
        let db = root.join("windows_api").join("windows_api.db");
        db.is_file().then_some(db)
    };
    for ancestor in entry.ancestors() {
        if let Some(db) = try_root(ancestor.to_path_buf()) {
            return Some(db);
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        for ancestor in cwd.ancestors() {
            if let Some(db) = try_root(ancestor.to_path_buf()) {
                return Some(db);
            }
        }
    }
    None
}

/// `newm2 describe <file> <line> <col>` — prints the context-help markdown for
/// the symbol at the cursor (1-based `line`, 0-based `col`), or nothing when no
/// symbol resolves there.
fn run_describe(paths: &[PathBuf], options: &DriverOptions) -> ExitCode {
    let Some(file) = paths.first().and_then(|p| p.to_str()) else {
        eprintln!("newm2 describe: expected <file> <line> <col>");
        return ExitCode::from(2);
    };
    let line: usize =
        paths.get(1).and_then(|p| p.to_str()).and_then(|s| s.parse().ok()).unwrap_or(0);
    let col: usize =
        paths.get(2).and_then(|p| p.to_str()).and_then(|s| s.parse().ok()).unwrap_or(0);
    if let Some(md) = describe_core(file, line, col, options) {
        print!("{md}");
    }
    ExitCode::SUCCESS
}

fn run_check(paths: &[PathBuf], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 check: expected a file argument");
        return ExitCode::from(2);
    };
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let result = check_graph(&graph, options);
    for d in &result.diagnostics {
        let sev = match d.severity {
            newm2_sema::Severity::Error => "error",
            newm2_sema::Severity::Warning => "warning",
        };
        let node = graph.get(d.module_id);
        eprintln!(
            "{}:{}: {sev}: {}",
            node.name, d.span.start.line, d.message
        );
    }
    if result.has_errors() {
        ExitCode::from(1)
    } else {
        ExitCode::SUCCESS
    }
}

fn run_dump_ir(paths: &[PathBuf], raw_args: &[String], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 dump-ir: expected a file argument");
        return ExitCode::from(2);
    };
    let mode = parse_memory_mode(raw_args);
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => { eprintln!("newm2: {e}"); return ExitCode::from(1); }
    };
    let sema = check_graph(&graph, options);
    let mut any = false;
    for &mid in &graph.topo_order {
        if let Some(ir) = lower_module(&graph, mid, &sema, mode) {
            print!("{}", format_ir(&ir));
            any = true;
        }
    }
    if !any {
        eprintln!("newm2 dump-ir: no lowerable modules found");
        return ExitCode::from(1);
    }
    if sema.has_errors() { ExitCode::from(1) } else { ExitCode::SUCCESS }
}

fn parse_memory_mode(_raw_args: &[String]) -> MemoryMode {
    // Manual memory is the default and primary model. GC is opt-in via
    // `--gc` and only available when the compiler is built with the `gc`
    // feature; `--no-gc` is accepted (and now redundant) for compatibility.
    #[cfg(feature = "gc")]
    if _raw_args.iter().any(|a| a == "--gc") {
        return MemoryMode::Gc;
    }
    MemoryMode::NoGc
}

/// Optimization level for both the backend (`CodeGenOpt`) and the IR pass
/// pipeline. `--opt <n>` / `--opt=<n>` (n = 0..3) is the primary control and
/// takes precedence over the legacy `-O<n>` flags. Level 0 (the default) runs no
/// IR optimization pipeline — the fast, lenient default.
fn parse_opt_level(raw_args: &[String]) -> u32 {
    let clamp = |s: &str| -> u32 {
        match s {
            "0" | "none" => 0,
            "1" | "less" => 1,
            "2" | "default" => 2,
            "3" | "max" | "aggressive" => 3,
            _ => 2, // `--opt` with an unrecognised setting still means "optimise"
        }
    };
    for (i, a) in raw_args.iter().enumerate() {
        if let Some(v) = a.strip_prefix("--opt=") {
            return clamp(v);
        }
        if a == "--opt" {
            if let Some(v) = raw_args.get(i + 1) {
                return clamp(v);
            }
            return 2;
        }
    }
    if raw_args.iter().any(|a| a == "-O3") {
        3
    } else if raw_args.iter().any(|a| a == "-O2") {
        2
    } else if raw_args.iter().any(|a| a == "-O1") {
        1
    } else {
        0
    }
}

fn run_dump_cfg(paths: &[PathBuf], raw_args: &[String], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 dump-cfg: expected a file argument");
        return ExitCode::from(2);
    };
    let mode = parse_memory_mode(raw_args);
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => { eprintln!("newm2: {e}"); return ExitCode::from(1); }
    };
    let sema = check_graph(&graph, options);
    let mut any = false;
    for &mid in &graph.topo_order {
        if let Some(ir) = lower_module(&graph, mid, &sema, mode) {
            print!("{}", format_cfg(&ir));
            any = true;
        }
    }
    if !any {
        eprintln!("newm2 dump-cfg: no lowerable modules found");
        return ExitCode::from(1);
    }
    if sema.has_errors() { ExitCode::from(1) } else { ExitCode::SUCCESS }
}

fn run_dump_llvm(paths: &[PathBuf], raw_args: &[String], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 dump-llvm: expected a file argument");
        return ExitCode::from(2);
    };
    let mode = parse_memory_mode(raw_args);
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => { eprintln!("newm2: {e}"); return ExitCode::from(1); }
    };
    let sema = check_graph(&graph, options);
    if sema.has_errors() {
        eprintln!("newm2 dump-llvm: semantic errors; cannot lower");
        return ExitCode::from(1);
    }
    let opts = CodegenOptions { memory_mode: mode, opt_level: parse_opt_level(raw_args), aot: false, m2_heap: options.m2_heap, protect_heap: options.protect_heap };
    let mut any = false;
    for &mid in &graph.topo_order {
        if let Some(ir) = lower_module(&graph, mid, &sema, mode) {
            let text = emit_llvm_ir(&ir, &sema, opts);
            print!("{text}");
            any = true;
        }
    }
    if !any {
        eprintln!("newm2 dump-llvm: no lowerable modules found");
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}

fn run_dump_asm(paths: &[PathBuf], raw_args: &[String], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 dump-asm: expected a file argument");
        return ExitCode::from(2);
    };
    let mode = parse_memory_mode(raw_args);
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => { eprintln!("newm2: {e}"); return ExitCode::from(1); }
    };
    let sema = check_graph(&graph, options);
    if sema.has_errors() {
        eprintln!("newm2 dump-asm: semantic errors; cannot lower");
        return ExitCode::from(1);
    }
    let opts = CodegenOptions { memory_mode: mode, opt_level: parse_opt_level(raw_args), aot: false, m2_heap: options.m2_heap, protect_heap: options.protect_heap };
    let mut any = false;
    for &mid in &graph.topo_order {
        if let Some(ir) = lower_module(&graph, mid, &sema, mode) {
            match emit_asm(&ir, &sema, opts) {
                Ok(text) => { print!("{text}"); any = true; }
                Err(e) => { eprintln!("newm2: {e}"); return ExitCode::from(1); }
            }
        }
    }
    if !any {
        eprintln!("newm2 dump-asm: no lowerable modules found");
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}

fn run_run(paths: &[PathBuf], raw_args: &[String], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 run: expected a file argument");
        return ExitCode::from(2);
    };
    // `--protect-heap`: the JIT runs in-process, so enabling the runtime guard is
    // just setting the env var the allocator reads (lazily, on first NEW).
    if options.protect_heap {
        unsafe { std::env::set_var("NM2_PROTECT_HEAP", "1") };
    }
    let mode = parse_memory_mode(raw_args);

    // Program-argument forwarding for ISO `ProgramArgs`: argument 0 is the
    // entry file's stem (≈ a C program's argv[0]); everything after a literal
    // `--` becomes the M2 program's command-line arguments.
    {
        let program_name = entry
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("program")
            .to_string();
        let user_args: Vec<String> = raw_args
            .iter()
            .skip_while(|a| a.as_str() != "--")
            .skip(1)
            .cloned()
            .collect();
        let mut args = Vec::with_capacity(1 + user_args.len());
        args.push(program_name);
        args.extend(user_args);
        newm2_runtime::nm2_program_args_set(args);
    }

    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => { eprintln!("newm2: {e}"); return ExitCode::from(1); }
    };
    let sema = check_graph(&graph, options);
    if sema.has_errors() {
        for d in &sema.diagnostics {
            let sev = match d.severity {
                newm2_sema::Severity::Error => "error",
                newm2_sema::Severity::Warning => "warning",
            };
            let node = graph.get(d.module_id);
            eprintln!("{}:{}: {sev}: {}", node.name, d.span.start.line, d.message);
        }
        return ExitCode::from(1);
    }
    let opts = CodegenOptions { memory_mode: mode, opt_level: parse_opt_level(raw_args), aot: false, m2_heap: options.m2_heap, protect_heap: options.protect_heap };
    // Run modules in topo order; execute the entry module's body last.
    let entry_mid = *graph.topo_order.last().unwrap_or(&graph.topo_order[0]);
    for &mid in &graph.topo_order {
        if mid == entry_mid {
            let lowered: Vec<_> = graph
                .topo_order
                .iter()
                .filter_map(|&mid| lower_module_opts(&graph, mid, &sema, mode, options.runtime_checks))
                .collect();
            let lowered_refs: Vec<_> = lowered.iter().collect();
            match newm2_llvm::run_modules(&lowered_refs, &graph.get(entry_mid).name, &sema, opts) {
                Ok(code) => {
                    if code != 0 {
                        return ExitCode::from(code as u8);
                    }
                }
                Err(e) => {
                    eprintln!("newm2: JIT error: {e}");
                    return ExitCode::from(1);
                }
            }
        }
    }
    ExitCode::SUCCESS
}

/// The ISO 10514-1 standard-library modules that `build-stdlib` compiles. Their
/// transitive imports (the M2 runtime-support modules: NM2.*, Heap, Storage, …)
/// are pulled in automatically by the loader and included in the archive.
const ISO_MODULES: &[&str] = &[
    "ChanConsts", "CharClass", "ComplexMath", "ConvTypes", "EXCEPTIONS",
    "GeneralUserExceptions", "IOChan", "IOConsts", "IOLink", "IOResult",
    "LongComplexMath", "LongConv", "LongIO", "LongMath", "LongStr", "LowLong",
    "LowReal", "M2EXCEPTION", "ProgramArgs", "RawIO", "RealConv", "RealIO",
    "RealMath", "RealStr", "RndFile", "SIOResult", "SLongIO", "SRawIO", "SRealIO",
    "STextIO", "SWholeIO", "Semaphores", "SeqFile", "StdChans", "Storage",
    "StreamFile", "Strings", "SysClock", "TERMINATION", "TermFile", "TextIO",
    "WholeConv", "WholeIO", "WholeStr",
];

/// `newm2 build-stdlib [--out stdlib.lib]` — pre-compile the ISO library (and
/// its transitive runtime-support modules) into a static library object plus a
/// manifest of the contained modules in initialisation order. A later
/// `newm2 build PROG --stdlib stdlib.lib` links against it instead of
/// re-lowering the whole library from source.
fn run_build_stdlib(options: &DriverOptions, raw_args: &[String]) -> ExitCode {
    let out_lib = options.out.clone().unwrap_or_else(|| PathBuf::from("stdlib.lib"));

    // Synthesise a root that imports the whole ISO surface so the loader pulls
    // in every ISO module and its transitive runtime-support modules.
    let mut src = String::from("MODULE __m2stdlib__;\n");
    for m in ISO_MODULES {
        src.push_str(&format!("IMPORT {m};\n"));
    }
    src.push_str("BEGIN END __m2stdlib__.\n");
    let root = std::env::temp_dir().join("__m2stdlib__.mod");
    if let Err(e) = std::fs::write(&root, src) {
        eprintln!("newm2: write stdlib root: {e}");
        return ExitCode::from(1);
    }

    let graph = match build_graph_from_entry(&root, options) {
        Ok(g) => g,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let sema = check_graph(&graph, options);
    if sema.has_errors() {
        for d in &sema.diagnostics {
            if d.severity == newm2_sema::Severity::Error {
                let node = graph.get(d.module_id);
                eprintln!("{}:{}: error: {}", node.name, d.span.start.line, d.message);
            }
        }
        return ExitCode::from(1);
    }

    let mode = MemoryMode::NoGc;
    let opts = CodegenOptions {
        memory_mode: mode,
        opt_level: parse_opt_level(raw_args),
        aot: true,
        m2_heap: options.m2_heap,
        protect_heap: options.protect_heap,
    };
    const ROOT: &str = "__m2stdlib__";
    let lowered: Vec<_> = graph
        .topo_order
        .iter()
        .filter(|&&mid| graph.get(mid).name != ROOT)
        .filter_map(|&mid| lower_module_opts(&graph, mid, &sema, mode, options.runtime_checks))
        .collect();
    let lowered_refs: Vec<_> = lowered.iter().collect();

    let obj_path = out_lib.with_extension("obj");
    if let Err(e) = newm2_llvm::emit_library_object(&lowered_refs, &sema, opts, &obj_path) {
        eprintln!("newm2: codegen: {e}");
        return ExitCode::from(1);
    }
    if let Err(e) = archive_lib(&obj_path, &out_lib) {
        eprintln!("newm2: lib: {e}");
        return ExitCode::from(1);
    }

    // Manifest: the real modules in initialisation (topological) order, each
    // flagged if it has a finalizer (`.final`), plus the import libraries the
    // stdlib's own Win32 calls need. A program build reads this to know which
    // modules the archive provides, the order their bodies run, which have
    // finalizers, and what to add to the final link.
    let has_fn = |suffix: &str| -> std::collections::HashSet<&str> {
        lowered
            .iter()
            .filter(|ir| ir.funcs.iter().any(|f| f.name == format!("{}.{suffix}", ir.name)))
            .map(|ir| ir.name.as_str())
            .collect()
    };
    let has_body = has_fn("body");
    let has_final = has_fn("final");
    let mut lines: Vec<String> = graph
        .topo_order
        .iter()
        .map(|&mid| graph.get(mid))
        .filter(|n| n.name != ROOT && !n.is_intrinsic)
        .map(|n| {
            let mut s = n.name.clone();
            if has_body.contains(n.name.as_str()) {
                s.push_str(" body");
            }
            if has_final.contains(n.name.as_str()) {
                s.push_str(" final");
            }
            s
        })
        .collect();
    let module_count = lines.len();
    for lib in collect_import_libs(&lowered) {
        lines.push(format!("lib {lib}"));
    }
    let man_path = out_lib.with_extension("manifest");
    if let Err(e) = std::fs::write(&man_path, lines.join("\n") + "\n") {
        eprintln!("newm2: write manifest: {e}");
        return ExitCode::from(1);
    }

    println!(
        "newm2: wrote {} ({} modules) + {}",
        out_lib.display(),
        module_count,
        man_path.display()
    );
    ExitCode::SUCCESS
}

/// The standard-library manifest written by `build-stdlib`: the contained
/// modules in init order (with finalizer flags) and the import libraries the
/// archive's Win32 calls need.
struct StdlibManifest {
    /// (module name, has_body, has_finalizer) in initialisation order.
    modules: Vec<(String, bool, bool)>,
    /// Import libraries to add to the final link (e.g. `kernel32.lib`).
    import_libs: Vec<String>,
}

fn read_stdlib_manifest(lib: &Path) -> Result<StdlibManifest, String> {
    let man_path = lib.with_extension("manifest");
    let text = std::fs::read_to_string(&man_path)
        .map_err(|e| format!("read {}: {e}", man_path.display()))?;
    let mut modules = Vec::new();
    let mut import_libs = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(lib) = line.strip_prefix("lib ") {
            import_libs.push(lib.trim().to_string());
        } else {
            let mut it = line.split_whitespace();
            let name = it.next().unwrap().to_string();
            let flags: Vec<&str> = it.collect();
            modules.push((name, flags.contains(&"body"), flags.contains(&"final")));
        }
    }
    Ok(StdlibManifest { modules, import_libs })
}

/// Archive an object file into a static library with the MSVC librarian.
fn archive_lib(obj: &Path, lib: &Path) -> Result<(), String> {
    let mut cmd = cc::windows_registry::find("x86_64-pc-windows-msvc", "lib.exe")
        .ok_or("could not locate the MSVC librarian (lib.exe)")?;
    cmd.arg("/NOLOGO");
    cmd.arg(format!("/OUT:{}", lib.display()));
    cmd.arg(obj);
    let out = cmd.output().map_err(|e| format!("lib.exe: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "lib.exe failed: {}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(())
}

/// `newm2 build foo.mod [-o foo.exe]` — ahead-of-time compile to a native
/// Windows executable: lower every module, emit one object file with an
/// AOT entry driver, then link it against the runtime static library and the
/// system libraries via the MSVC linker.
fn run_build(paths: &[PathBuf], raw_args: &[String], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 build: expected a file argument");
        return ExitCode::from(2);
    };
    // AOT defaults to manual memory: the tracing GC needs its JIT-time root
    // init + stack sentinel, which the static entry path does not set up.
    let mode = MemoryMode::NoGc;

    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => { eprintln!("newm2: {e}"); return ExitCode::from(1); }
    };
    let sema = check_graph(&graph, options);
    if sema.has_errors() {
        for d in &sema.diagnostics {
            let sev = match d.severity {
                newm2_sema::Severity::Error => "error",
                newm2_sema::Severity::Warning => "warning",
            };
            let node = graph.get(d.module_id);
            eprintln!("{}:{}: {sev}: {}", node.name, d.span.start.line, d.message);
        }
        return ExitCode::from(1);
    }

    let opts = CodegenOptions {
        memory_mode: mode,
        opt_level: parse_opt_level(raw_args),
        aot: true,
        m2_heap: options.m2_heap,
        protect_heap: options.protect_heap,
    };

    if options.stdlib.is_some() {
        return build_against_stdlib(entry, &graph, &sema, opts, mode, options);
    }

    let lowered: Vec<_> = graph
        .topo_order
        .iter()
        .filter_map(|&mid| lower_module_opts(&graph, mid, &sema, mode, options.runtime_checks))
        .collect();
    let lowered_refs: Vec<_> = lowered.iter().collect();

    // Output paths: <out> (default <stem>.exe next to the entry file) and a
    // sibling object file.
    let exe_path = options.out.clone().unwrap_or_else(|| {
        let stem = entry.file_stem().and_then(|s| s.to_str()).unwrap_or("a");
        entry.with_file_name(format!("{stem}.exe"))
    });
    let obj_path = exe_path.with_extension("obj");

    if let Err(e) = newm2_llvm::emit_aot_object(&lowered_refs, &sema, opts, &obj_path) {
        eprintln!("newm2: codegen: {e}");
        return ExitCode::from(1);
    }

    let import_libs = collect_import_libs(&lowered);
    let gui = options.gui || entry_has_gui_pragma(&graph);
    let manifest = match resolve_manifest(&options.manifest, gui) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    match link_executable(&obj_path, &exe_path, &[], &import_libs, gui, manifest.path()) {
        Ok(()) => {
            println!("newm2: wrote {}", exe_path.display());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("newm2: link: {e}");
            ExitCode::from(1)
        }
    }
}

/// `build --stdlib stdlib.lib`: lower only the program's own modules, emit the
/// AOT driver over the FULL init order from the manifest (stdlib module bodies
/// referenced as externals), and link against the prebuilt stdlib.lib instead of
/// re-lowering the ISO library from source.
fn build_against_stdlib(
    entry: &Path,
    graph: &newm2_loader::ModuleGraph,
    sema: &newm2_sema::SemaResult,
    opts: CodegenOptions,
    mode: MemoryMode,
    options: &DriverOptions,
) -> ExitCode {
    let stdlib_lib = options.stdlib.as_ref().expect("build_against_stdlib requires --stdlib");
    let manifest = match read_stdlib_manifest(stdlib_lib) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("newm2: stdlib manifest: {e}");
            return ExitCode::from(1);
        }
    };
    // name -> (has_body, has_finalizer) for the modules the archive provides.
    let stdlib_info: std::collections::HashMap<&str, (bool, bool)> =
        manifest.modules.iter().map(|(n, b, f)| (n.as_str(), (*b, *f))).collect();

    // Lower ONLY the program's own modules — everything the stdlib provides is
    // referenced as an external symbol resolved from stdlib.lib.
    let program_lowered: Vec<_> = graph
        .topo_order
        .iter()
        .map(|&mid| (mid, graph.get(mid)))
        .filter(|(_, n)| !n.is_intrinsic && !stdlib_info.contains_key(n.name.as_str()))
        .filter_map(|(mid, _)| lower_module_opts(graph, mid, sema, mode, options.runtime_checks))
        .collect();
    let program_refs: Vec<_> = program_lowered.iter().collect();
    let prog_has = |suffix: &str| -> std::collections::HashSet<&str> {
        program_lowered
            .iter()
            .filter(|ir| ir.funcs.iter().any(|f| f.name == format!("{}.{suffix}", ir.name)))
            .map(|ir| ir.name.as_str())
            .collect()
    };
    let prog_body = prog_has("body");
    let prog_final = prog_has("final");

    // Full init order: every non-intrinsic module in topological order, with its
    // (has_body, has_finalizer) flags — from the manifest for stdlib modules,
    // from the lowered IR for program modules.
    let init_order: Vec<(String, bool, bool)> = graph
        .topo_order
        .iter()
        .map(|&mid| graph.get(mid))
        .filter(|n| !n.is_intrinsic)
        .map(|n| {
            let (has_body, has_final) = stdlib_info.get(n.name.as_str()).copied().unwrap_or_else(|| {
                (prog_body.contains(n.name.as_str()), prog_final.contains(n.name.as_str()))
            });
            (n.name.clone(), has_body, has_final)
        })
        .collect();

    let exe_path = options.out.clone().unwrap_or_else(|| {
        let stem = entry.file_stem().and_then(|s| s.to_str()).unwrap_or("a");
        entry.with_file_name(format!("{stem}.exe"))
    });
    let obj_path = exe_path.with_extension("obj");

    if let Err(e) =
        newm2_llvm::emit_aot_object_with_init_order(&program_refs, &init_order, sema, opts, &obj_path)
    {
        eprintln!("newm2: codegen: {e}");
        return ExitCode::from(1);
    }

    // Import libs: the program's own Win32 calls + the ones the stdlib needs.
    let mut import_libs = collect_import_libs(&program_lowered);
    import_libs.extend(manifest.import_libs.iter().cloned());
    import_libs.sort();
    import_libs.dedup();

    let gui = options.gui || entry_has_gui_pragma(graph);
    let app_manifest = match resolve_manifest(&options.manifest, gui) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    match link_executable(&obj_path, &exe_path, &[stdlib_lib.as_path()], &import_libs, gui, app_manifest.path()) {
        Ok(()) => {
            println!(
                "newm2: wrote {} ({} program modules, {} from stdlib)",
                exe_path.display(),
                program_lowered.len(),
                manifest.modules.len()
            );
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("newm2: link: {e}");
            ExitCode::from(1)
        }
    }
}

/// Locate the runtime static library (`newm2_runtime.lib`), built alongside the
/// driver in the cargo target directory.
fn locate_runtime_lib() -> Result<PathBuf, String> {
    let exe = std::env::current_exe()
        .map_err(|e| format!("current_exe: {e}"))?;
    let dir = exe.parent().ok_or("driver exe has no parent directory")?;
    let lib = dir.join("newm2_runtime.lib");
    if lib.is_file() {
        return Ok(lib);
    }
    // `cargo run`/`cargo test` may place the driver under target/<profile>/deps.
    if let Some(up) = dir.parent() {
        let alt = up.join("newm2_runtime.lib");
        if alt.is_file() {
            return Ok(alt);
        }
    }
    Err(format!(
        "newm2_runtime.lib not found next to {} — run `cargo build -p newm2-runtime`",
        dir.display()
    ))
}

/// Map a DLL name from an `EXTERNAL FROM "x.dll"` binding to its MSVC import
/// library (`KERNEL32.dll` → `kernel32.lib`). The 1:1 stem rule covers the vast
/// majority of Win32 DLLs; the linker ignores a `.lib` it cannot find only if
/// nothing references it, so an unknown mapping is harmless unless a symbol is
/// actually used (then the user adds the right lib explicitly).
fn dll_to_import_lib(dll: &str) -> String {
    let lower = dll.to_ascii_lowercase();
    let stem = lower.strip_suffix(".dll").unwrap_or(&lower);
    // The D3D shader compiler ships as the versioned d3dcompiler_47.dll, but its
    // Windows SDK import library is the unversioned d3dcompiler.lib.
    if stem.starts_with("d3dcompiler") {
        return "d3dcompiler.lib".to_string();
    }
    format!("{stem}.lib")
}

/// Collect the import libraries needed by every `EXTERNAL FROM "x.dll"` proc the
/// program references, so a direct Win32 call links at AOT regardless of which
/// DLL it targets (kernel32, gdi32, winmm, comctl32, …). Deduplicated, sorted.
fn collect_import_libs(lowered: &[newm2_ir::IrModule]) -> Vec<String> {
    use newm2_ir::Global;
    let mut libs: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for ir in lowered {
        for g in &ir.globals {
            if let Global::ExternFunc { dll_name: Some(dll), .. } = g
                && !dll.is_empty()
            {
                libs.insert(dll_to_import_lib(dll));
            }
        }
    }
    libs.into_iter().collect()
}

/// True if the entry program module carries a `<*GUI*>` pragma — at the module
/// header (`Module.pragmas`) or as a top-level declaration (`Decl::Pragma`). Such
/// a program is linked for the Windows GUI subsystem (no console), exactly like
/// `--gui`. The entry is always `ModuleId(0)` (the loader's first module); an
/// imported library carrying the pragma must NOT flip the whole program.
fn entry_has_gui_pragma(graph: &newm2_loader::ModuleGraph) -> bool {
    let node = graph.get(newm2_loader::ModuleId(0));
    let Some(m) = node.impl_ast.as_ref().or(node.def_ast.as_ref()) else {
        return false;
    };
    let is_gui = |body: &str| body.trim().eq_ignore_ascii_case("GUI");
    m.pragmas.iter().any(|p| is_gui(&p.body))
        || m.decls.iter().any(|d| matches!(d, Decl::Pragma(p) if is_gui(&p.body)))
}

/// Link `obj` + the runtime static library + system libraries into `exe` using
/// the MSVC linker (located via the same registry/vswhere lookup rustc uses).
/// `import_libs` are the DLL import libraries the program's direct Win32 calls
/// require (derived from its `EXTERNAL FROM "x.dll"` declarations).
/// The manifest file to hand to `link.exe /MANIFESTINPUT`, with its temp lifetime.
/// For [`ManifestMode::Default`] (GUI) the built-in XML is written to a temp file
/// that is deleted when this guard drops (after the link completes).
struct EmbedManifest {
    path: Option<PathBuf>,
    temp: bool,
}

impl EmbedManifest {
    fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }
}

impl Drop for EmbedManifest {
    fn drop(&mut self) {
        if self.temp {
            if let Some(p) = &self.path {
                let _ = std::fs::remove_file(p);
            }
        }
    }
}

/// Resolve which manifest (if any) to embed into the `.exe` for this build.
/// `Custom` always embeds the given file; `Default` embeds the built-in
/// modern-controls manifest only for GUI builds; `None` embeds nothing.
fn resolve_manifest(mode: &ManifestMode, gui: bool) -> Result<EmbedManifest, String> {
    match mode {
        ManifestMode::None => Ok(EmbedManifest { path: None, temp: false }),
        ManifestMode::Custom(p) => {
            if !p.is_file() {
                return Err(format!("--manifest: file not found: {}", p.display()));
            }
            Ok(EmbedManifest { path: Some(p.clone()), temp: false })
        }
        ManifestMode::Default => {
            if !gui {
                // Console programs get no default manifest (modern controls are a
                // GUI concern; forcing UTF-8/longPath behaviour changes is opt-in).
                return Ok(EmbedManifest { path: None, temp: false });
            }
            let tmp = std::env::temp_dir()
                .join(format!("newm2-default-{}.manifest", std::process::id()));
            std::fs::write(&tmp, DEFAULT_GUI_MANIFEST)
                .map_err(|e| format!("could not write default manifest {}: {e}", tmp.display()))?;
            Ok(EmbedManifest { path: Some(tmp), temp: true })
        }
    }
}

/// Where `mt.exe` (needed by `link.exe /MANIFEST:EMBED`) can be found:
/// - `Some(Some(dir))` — in a Windows SDK bin dir; prepend `dir` to the linker PATH.
/// - `Some(None)` — already on PATH; no PATH change needed.
/// - `None` — not found; the caller must not pass /MANIFEST:EMBED.
fn locate_mt() -> Option<Option<PathBuf>> {
    if let Some(dir) = locate_sdk_tool_dir() {
        return Some(Some(dir));
    }
    let on_path = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join("mt.exe").is_file()))
        .unwrap_or(false);
    if on_path {
        Some(None)
    } else {
        None
    }
}

/// Locate the Windows SDK `bin\<ver>\x64` directory that holds `mt.exe`/`rc.exe`.
/// `link.exe /MANIFEST:EMBED` shells out to `mt.exe`, which `cc::windows_registry`
/// does not put on PATH, so we find it and prepend its directory to the linker's
/// PATH. Returns the newest SDK version's x64 bin dir, or None if no SDK is found.
fn locate_sdk_tool_dir() -> Option<PathBuf> {
    for root in [
        std::env::var_os("ProgramFiles(x86)").map(PathBuf::from),
        std::env::var_os("ProgramFiles").map(PathBuf::from),
    ]
    .into_iter()
    .flatten()
    {
        let bin = root.join("Windows Kits").join("10").join("bin");
        let Ok(entries) = std::fs::read_dir(&bin) else {
            continue;
        };
        // Version subdirs (e.g. 10.0.26100.0); pick the newest with x64\mt.exe.
        let mut vers: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.join("x64").join("mt.exe").is_file())
            .collect();
        vers.sort();
        if let Some(v) = vers.pop() {
            return Some(v.join("x64"));
        }
    }
    None
}

fn link_executable(
    obj: &Path,
    exe: &Path,
    extra_libs: &[&Path],
    import_libs: &[String],
    gui: bool,
    manifest: Option<&Path>,
) -> Result<(), String> {
    let runtime_lib = locate_runtime_lib()?;

    let mut cmd = cc::windows_registry::find("x86_64-pc-windows-msvc", "link.exe")
        .ok_or_else(|| {
            "could not locate the MSVC linker (link.exe). Install the Visual Studio \
             Build Tools (C++ workload) or run from a Developer Command Prompt."
                .to_string()
        })?;

    cmd.arg("/NOLOGO");
    // Embed the application manifest (modern themed controls / DPI awareness) as
    // RT_MANIFEST resource #1. link.exe implements /MANIFEST:EMBED by shelling out
    // to mt.exe (Windows SDK), which cc::windows_registry does not put on PATH, so
    // we locate it. If mt.exe cannot be found anywhere we fall back to a side-by-side
    // <exe>.manifest after linking, so a GUI build never FAILS merely for lack of the
    // SDK tool. link merges in a default `asInvoker` trustInfo fragment automatically.
    let mt = match manifest {
        Some(_) => locate_mt(),
        None => None,
    };
    let mut embed_manifest = false;
    if let Some(m) = manifest {
        if let Some(mt_loc) = &mt {
            cmd.arg("/MANIFEST:EMBED");
            cmd.arg(format!("/MANIFESTINPUT:{}", m.display()));
            // Embed the input manifest VERBATIM: /MANIFESTUAC:NO stops link from also
            // injecting its own <trustInfo>, which would collide (mt error c1010001)
            // with a custom manifest that already declares a requestedExecutionLevel.
            // Our manifests (default + FastPanesM2) carry their own asInvoker block.
            cmd.arg("/MANIFESTUAC:NO");
            if let Some(dir) = mt_loc {
                let existing = std::env::var_os("PATH").unwrap_or_default();
                let mut prefixed = dir.clone().into_os_string();
                prefixed.push(";");
                prefixed.push(existing);
                cmd.env("PATH", prefixed);
            }
            embed_manifest = true;
        }
    }
    if gui {
        // GUI subsystem: Windows does not allocate a console for the process.
        // Keep the ordinary `main` entry (the C runtime's mainCRTStartup) so the
        // program runs unchanged — only the PE subsystem flag differs from a
        // console build, which otherwise would need a WinMain.
        cmd.arg("/SUBSYSTEM:WINDOWS");
        cmd.arg("/ENTRY:mainCRTStartup");
    } else {
        cmd.arg("/SUBSYSTEM:CONSOLE");
    }
    cmd.arg(format!("/OUT:{}", exe.display()));
    cmd.arg(obj);
    // Prebuilt static libraries to link first (e.g. a prebuilt stdlib.lib), so
    // the program object's external `Module.Proc`/`Module.body` references resolve.
    for lib in extra_libs {
        cmd.arg(lib);
    }
    cmd.arg(&runtime_lib);
    // The dynamic C runtime (Rust's default CRT on windows-msvc): the C runtime
    // (memset/strlen/_fltused/__chkstk/TLS), the Universal CRT, and the C++
    // exception-handling runtime (__CxxFrameHandler3/_CxxThrowException/type_info)
    // that `panic = "unwind"` relies on. The CRT also supplies `mainCRTStartup`,
    // which calls our emitted `main`.
    cmd.arg("msvcrt.lib");
    cmd.arg("vcruntime.lib");
    cmd.arg("ucrt.lib");
    // System libraries the Rust standard library (bundled in the static
    // runtime) depends on, plus COM for the OO/COM layer. These mirror rustc's
    // `native-static-libs` for x86_64-pc-windows-msvc.
    for lib in [
        "kernel32.lib", "advapi32.lib", "ntdll.lib", "userenv.lib", "ws2_32.lib",
        "bcrypt.lib", "dbghelp.lib", "ole32.lib", "oleaut32.lib", "shell32.lib",
        "user32.lib", "synchronization.lib",
    ] {
        cmd.arg(lib);
    }
    // Import libraries for the program's own direct Win32 calls (`EXTERNAL FROM
    // "x.dll"`). Duplicates of the fixed set above are harmless to the linker.
    for lib in import_libs {
        cmd.arg(lib);
    }

    let output = cmd
        .output()
        .map_err(|e| format!("failed to run linker: {e}"))?;
    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "linker exited with {}\n{stdout}{stderr}",
            output.status
        ));
    }
    // Could not embed (no mt.exe): write the manifest beside the exe instead, so the
    // app still gets modern controls — Windows honours a side-by-side <exe>.manifest.
    if let Some(m) = manifest {
        if !embed_manifest {
            let mut sxs = exe.as_os_str().to_owned();
            sxs.push(".manifest");
            let sxs = PathBuf::from(sxs);
            // If the supplied manifest IS already the side-by-side file (same path),
            // there is nothing to copy — it is in place and Windows will honour it.
            let same = sxs.exists()
                && std::fs::canonicalize(m).ok() == std::fs::canonicalize(&sxs).ok();
            if same {
                eprintln!(
                    "newm2: note: mt.exe (Windows SDK) not found — using the manifest already beside the exe ({})",
                    sxs.display()
                );
            } else {
            match std::fs::copy(m, &sxs) {
                Ok(_) => eprintln!(
                    "newm2: note: mt.exe (Windows SDK) not found — wrote side-by-side {} instead of embedding the manifest",
                    sxs.display()
                ),
                Err(e) => eprintln!(
                    "newm2: warning: could not embed manifest (no mt.exe) nor write {}: {e}",
                    sxs.display()
                ),
            }
            }
        }
    }
    Ok(())
}

fn print_usage() {
    println!("newm2 — Modula-2 compiler driver (Phase 3)");
    println!();
    println!("Commands:");
    for cmd in COMMANDS {
        println!("  newm2 {cmd}");
    }
    println!();
    println!("Global flags (apply to run / build / check):");
    for f in GLOBAL_FLAGS {
        println!("  {f}");
    }
    println!("  --define NAME");
    println!("  --define KEY:VALUE");
    println!("  --define KEY=VALUE");
    println!("  --adw-win64-unicode");
    println!("  --out PATH");
    println!();
    println!("Preprocessor conditions:");
    println!("  %IF NAME %THEN ...");
    println!("  %IF KEY = VALUE %THEN ...");
    println!("  %IF KEY # VALUE %THEN ...");
}

fn run_dump_heap(paths: &[PathBuf], raw_args: &[String], options: &DriverOptions) -> ExitCode {
    let Some(entry) = paths.first() else {
        eprintln!("newm2 dump-heap: expected a file argument");
        return ExitCode::from(2);
    };
    // Manual memory is the model; report the HeapAlloc-backed heap.
    let _ = raw_args;
    let graph = match build_graph_from_entry(entry, options) {
        Ok(g) => g,
        Err(e) => { eprintln!("newm2: {e}"); return ExitCode::from(1); }
    };
    let sema = check_graph(&graph, options);
    if sema.has_errors() {
        for d in &sema.diagnostics {
            let sev = match d.severity {
                newm2_sema::Severity::Error => "error",
                newm2_sema::Severity::Warning => "warning",
            };
            let node = graph.get(d.module_id);
            eprintln!("{}:{}: {sev}: {}", node.name, d.span.start.line, d.message);
        }
        return ExitCode::from(1);
    }
    let opts = CodegenOptions { memory_mode: MemoryMode::NoGc, opt_level: 0, aot: false, m2_heap: options.m2_heap, protect_heap: options.protect_heap };
    let entry_mid = *graph.topo_order.last().unwrap_or(&graph.topo_order[0]);
    let lowered: Vec<_> = graph
        .topo_order
        .iter()
        .filter_map(|&mid| lower_module(&graph, mid, &sema, MemoryMode::NoGc))
        .collect();
    let lowered_refs: Vec<_> = lowered.iter().collect();
    match newm2_llvm::run_modules(&lowered_refs, &graph.get(entry_mid).name, &sema, opts) {
        Ok(code) if code != 0 => {
            eprintln!("newm2: module exited with code {code}");
            return ExitCode::from(code as u8);
        }
        Err(e) => {
            eprintln!("newm2: JIT error: {e}");
            return ExitCode::from(1);
        }
        _ => {}
    }

    // ── Manual heap report (HeapAlloc-backed Storage) ────────────────────────
    let alloc_blocks = HEAP_STATS.alloc_blocks.load(Ordering::Relaxed);
    let alloc_bytes  = HEAP_STATS.alloc_bytes.load(Ordering::Relaxed);
    let free_blocks  = HEAP_STATS.free_blocks.load(Ordering::Relaxed);
    let free_bytes   = HEAP_STATS.free_bytes.load(Ordering::Relaxed);
    let live_blocks  = HEAP_STATS.live_blocks.load(Ordering::Relaxed);
    let live_bytes   = HEAP_STATS.live_bytes.load(Ordering::Relaxed);
    let peak_bytes   = HEAP_STATS.peak_live_bytes.load(Ordering::Relaxed);

    println!("══════════════════════════════════════════════════════");
    println!(" NewM2 Manual Heap Report — {}", entry.display());
    println!("══════════════════════════════════════════════════════");
    println!();
    println!("  Lifetime allocation (HeapAlloc):");
    println!("    blocks allocated : {alloc_blocks}");
    println!("    bytes  allocated : {alloc_bytes}");
    println!("    blocks freed     : {free_blocks}");
    println!("    bytes  freed     : {free_bytes}");
    println!();
    println!("  Live heap (still allocated at exit):");
    println!("    live blocks      : {live_blocks}");
    println!("    live bytes       : {live_bytes}");
    println!("    peak live bytes  : {peak_bytes}");
    if live_blocks > 0 {
        println!();
        println!(
            "  note: {live_blocks} block(s) still live at exit — manual memory, \
             no automatic reclamation (use DISPOSE)."
        );
    }
    println!();

    ExitCode::SUCCESS
}

fn run_dump_tokens(paths: &[PathBuf], env: &Env) -> ExitCode {
    let Some(path) = paths.first() else {
        eprintln!("newm2 dump-tokens: expected a file argument");
        return ExitCode::from(2);
    };
    let src = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) => {
            eprintln!("newm2: failed to read {}: {e}", path.display());
            return ExitCode::from(1);
        }
    };
    let s = String::from_utf8_lossy(&src);
    let pp = match preprocess(&s, env) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let tokens = match tokenize(&pp) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    print!("{}", format_tokens(&tokens));
    ExitCode::SUCCESS
}

fn run_dump_ast(paths: &[PathBuf], env: &Env) -> ExitCode {
    let Some(path) = paths.first() else {
        eprintln!("newm2 dump-ast: expected a file argument");
        return ExitCode::from(2);
    };
    let src = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) => {
            eprintln!("newm2: failed to read {}: {e}", path.display());
            return ExitCode::from(1);
        }
    };
    let s = String::from_utf8_lossy(&src);
    let pp = match preprocess(&s, env) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let tokens = match tokenize(&pp) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let module = match parse_module(&tokens) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    print!("{}", format_module(&module));
    ExitCode::SUCCESS
}

fn run_parse_def(paths: &[PathBuf], raw_args: &[String], env: &Env) -> ExitCode {
    let Some(path) = paths.first() else {
        eprintln!("newm2 parsedef: expected a file argument");
        return ExitCode::from(2);
    };
    let out_path = match parse_out_path(raw_args) {
        Ok(path) => path,
        Err(message) => {
            eprintln!("newm2 parsedef: {message}");
            return ExitCode::from(2);
        }
    };
    let src = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) => {
            eprintln!("newm2: failed to read {}: {e}", path.display());
            return ExitCode::from(1);
        }
    };
    let s = String::from_utf8_lossy(&src);
    let pp = match preprocess(&s, env) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let tokens = match tokenize(&pp) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let mut module = match parse_module(&tokens) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("newm2: {e}");
            return ExitCode::from(1);
        }
    };
    let rendered = if raw_args.iter().any(|arg| arg == "--types-out") {
        let db_warnings = match annotate_windows_external_linkage(path, &mut module) {
            Ok(warnings) => warnings,
            Err(message) => {
                eprintln!("warning: {message}");
                Vec::new()
            }
        };
        let out = format_types_module_with_env(&module, env);
        for warning in &db_warnings {
            eprintln!("warning: {warning}");
        }
        for warning in &out.warnings {
            eprintln!("warning: {warning}");
        }
        out.text
    } else {
        format_module(&module)
    };

    if let Some(out_path) = out_path {
        if let Some(parent) = out_path.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                eprintln!("newm2: failed to create {}: {e}", parent.display());
                return ExitCode::from(1);
            }
        }
        if let Err(e) = std::fs::write(&out_path, rendered) {
            eprintln!("newm2: failed to write {}: {e}", out_path.display());
            return ExitCode::from(1);
        }
    } else {
        print!("{rendered}");
    }
    ExitCode::SUCCESS
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
struct WindowsProcMetadata {
    dll_name: String,
    import_name: String,
}

fn annotate_windows_external_linkage(path: &Path, module: &mut Module) -> Result<Vec<String>, String> {
    let Some(db_path) = locate_windows_api_db(path) else {
        return Ok(Vec::new());
    };
    let conn = Connection::open(&db_path)
        .map_err(|e| format!("types-out: failed to open Windows API metadata {}: {e}", db_path.display()))?;
    let mut warnings = Vec::new();
    annotate_decls_with_windows_db(&conn, &module.name, &mut module.decls, &mut warnings)?;
    Ok(warnings)
}

fn locate_windows_api_db(path: &Path) -> Option<PathBuf> {
    for ancestor in path.ancestors() {
        let Some(name) = ancestor.file_name().and_then(OsStr::to_str) else {
            continue;
        };
        if !(name.eq_ignore_ascii_case("def_in") || name.eq_ignore_ascii_case("def_out")) {
            continue;
        }
        let root = ancestor.parent()?;
        let root_name = root.file_name().and_then(OsStr::to_str)?;
        if !root_name.eq_ignore_ascii_case("windows_api") {
            continue;
        }
        let db_path = root.join("windows_api.db");
        if db_path.is_file() {
            return Some(db_path);
        }
    }
    None
}

fn annotate_decls_with_windows_db(
    conn: &Connection,
    module_name: &str,
    decls: &mut [Decl],
    warnings: &mut Vec<String>,
) -> Result<(), String> {
    for decl in decls {
        match decl {
            Decl::Procedure(proc_decl) => annotate_proc_with_windows_db(conn, module_name, proc_decl, warnings)?,
            Decl::LocalModule(module) => {
                annotate_decls_with_windows_db(conn, &module.name, &mut module.decls, warnings)?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn annotate_proc_with_windows_db(
    conn: &Connection,
    module_name: &str,
    proc_decl: &mut ProcDecl,
    warnings: &mut Vec<String>,
) -> Result<(), String> {
    if proc_decl.external_linkage.as_ref().and_then(|linkage| linkage.dll_name.as_ref()).is_some() {
        return Ok(());
    }

    let lookup_name = proc_decl
        .external_linkage
        .as_ref()
        .map(|linkage| linkage.link_name.value.as_str())
        .unwrap_or(proc_decl.name.as_str());
    let matches = lookup_windows_proc_metadata(conn, lookup_name)?;
    match matches.len() {
        0 => Ok(()),
        1 => {
            let metadata = matches.into_iter().next().unwrap();
            apply_windows_proc_metadata(proc_decl, metadata);
            Ok(())
        }
        _ => {
            warnings.push(format!(
                "types-out: Windows API metadata for {}.{} is ambiguous; leaving procedure heading unchanged",
                module_name,
                proc_decl.name,
            ));
            Ok(())
        }
    }
}

fn lookup_windows_proc_metadata(conn: &Connection, lookup_name: &str) -> Result<Vec<WindowsProcMetadata>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT DISTINCT COALESCE(dll_name, ''), COALESCE(import_name, ''), COALESCE(function_name, '') \
             FROM functions \
             WHERE function_name = ?1 COLLATE NOCASE OR import_name = ?1 COLLATE NOCASE",
        )
        .map_err(|e| format!("types-out: failed to prepare Windows API metadata query: {e}"))?;
    let rows = stmt
        .query_map(params![lookup_name], |row| {
            let dll_name: String = row.get(0)?;
            let import_name: String = row.get(1)?;
            let function_name: String = row.get(2)?;
            Ok((dll_name, import_name, function_name))
        })
        .map_err(|e| format!("types-out: failed to query Windows API metadata for {lookup_name}: {e}"))?;

    let mut matches = BTreeSet::new();
    for row in rows {
        let (dll_name, import_name, function_name) = row
            .map_err(|e| format!("types-out: failed to read Windows API metadata for {lookup_name}: {e}"))?;
        if dll_name.is_empty() {
            continue;
        }
        let import_name = if import_name.is_empty() {
            function_name
        } else {
            import_name
        };
        matches.insert(WindowsProcMetadata { dll_name, import_name });
    }
    Ok(matches.into_iter().collect())
}

fn apply_windows_proc_metadata(proc_decl: &mut ProcDecl, metadata: WindowsProcMetadata) {
    let dll_name = StringLiteral {
        value: metadata.dll_name,
        flavor: LiteralFlavor::Default,
    };
    if let Some(linkage) = &mut proc_decl.external_linkage {
        if linkage.dll_name.is_none() {
            linkage.dll_name = Some(dll_name);
        }
        return;
    }
    proc_decl.external_linkage = Some(ProcExternalLinkage {
        link_name: StringLiteral {
            value: metadata.import_name,
            flavor: LiteralFlavor::Default,
        },
        dll_name: Some(dll_name),
        is_external: true,
        span: proc_decl.span,
    });
}

fn parse_out_path(raw_args: &[String]) -> Result<Option<PathBuf>, String> {
    let mut index = 0usize;
    while index < raw_args.len() {
        if raw_args[index] == "--out" {
            let Some(path) = raw_args.get(index + 1) else {
                return Err("--out expects a file path".into());
            };
            return Ok(Some(PathBuf::from(path)));
        }
        index += 1;
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use rusqlite::Connection;

    #[test]
    fn commands_list_includes_run() {
        assert!(COMMANDS.contains(&"run"));
    }

    #[test]
    fn commands_list_includes_parsedef() {
        assert!(COMMANDS.contains(&"parsedef"));
    }

    #[test]
    fn global_flags_include_no_gc() {
        assert!(GLOBAL_FLAGS.contains(&"--no-gc"));
    }

    #[test]
    fn global_flags_include_types_out() {
        assert!(GLOBAL_FLAGS.contains(&"--types-out"));
    }

    #[test]
    fn global_flags_include_adw_win64_unicode() {
        assert!(GLOBAL_FLAGS.contains(&"--adw-win64-unicode"));
    }

    #[test]
    fn global_flags_include_library() {
        assert!(GLOBAL_FLAGS.contains(&"--library"));
    }

    #[test]
    fn global_flags_include_out() {
        assert!(GLOBAL_FLAGS.contains(&"--out"));
    }

    #[test]
    fn global_flags_include_windows() {
        assert!(GLOBAL_FLAGS.contains(&"--windows"));
    }

    #[test]
    fn parse_define_value_flag() {
        let options = DriverOptions::parse(&[
            "--define".to_string(),
            "Flavor:debug".to_string(),
        ])
        .unwrap();
        let pp = preprocess("%IF Flavor = debug %THEN keep %END", &options.env).unwrap();
        assert!(pp.contains("keep"));
    }

    #[test]
    fn adw_win64_unicode_flag_sets_word_size() {
        let options = DriverOptions::parse(&["--adw-win64-unicode".to_string()]).unwrap();
        let pp = preprocess("%IF WordSize = 64 %THEN keep %END", &options.env).unwrap();
        assert!(pp.contains("keep"));
    }

    #[test]
    fn win_source_flag_selects_generated() {
        let space = DriverOptions::parse(&[
            "--win-source".to_string(),
            "generated".to_string(),
        ])
        .unwrap();
        assert_eq!(space.win_source, WinSource::Generated);
        assert!(space.windows, "--win-source implies --windows");

        let eq = DriverOptions::parse(&["--win-source=adw".to_string()]).unwrap();
        assert_eq!(eq.win_source, WinSource::Adw);

        let default = DriverOptions::parse(&["--windows".to_string()]).unwrap();
        assert_eq!(default.win_source, WinSource::Adw);

        assert!(DriverOptions::parse(&["--win-source".to_string(), "bogus".to_string()]).is_err());
        assert_eq!(WinSource::Generated.paths(), ("def_out_gen", "windows_api_gen.pack"));
    }

    #[test]
    fn runtime_checks_default_on_and_opt_out() {
        assert!(DriverOptions::parse(&[]).unwrap().runtime_checks);
        let off = DriverOptions::parse(&["--no-runtime-checks".to_string()]).unwrap();
        assert!(!off.runtime_checks);
        assert!(GLOBAL_FLAGS.contains(&"--no-runtime-checks"));
    }

    #[test]
    fn windows_flag_is_recorded() {
        let options = DriverOptions::parse(&["--windows".to_string()]).unwrap();
        assert!(options.windows);
    }

    #[test]
    fn library_flag_is_recorded() {
        let options = DriverOptions::parse(&[
            "--library".to_string(),
            "library".to_string(),
        ])
        .unwrap();
        assert_eq!(options.library_paths, vec![PathBuf::from("library")]);
    }

    #[test]
    fn explicit_library_root_contributes_def_dirs_to_search_path() {
        let temp_root = temp_test_dir("driver_library_search_path");
        let library_root = temp_root.join("library");
        let def_dir = library_root.join("advapidef");
        std::fs::create_dir_all(&def_dir).unwrap();

        let entry = temp_root.join("Mod").join("Hello.mod");
        std::fs::create_dir_all(entry.parent().unwrap()).unwrap();
        std::fs::write(&entry, "MODULE Hello; BEGIN END Hello.\n").unwrap();

        let sp = default_search_path(&entry, true, std::slice::from_ref(&library_root));
        assert!(sp.entries().iter().any(|p| p == &def_dir));

        std::fs::remove_dir_all(temp_root).unwrap();
    }

    #[test]
    fn parse_out_path_reads_output_target() {
        let out = parse_out_path(&[
            "--types-out".to_string(),
            "--out".to_string(),
            "windows_api/def_out/Foo_types.def".to_string(),
            "windows_api/def_in/Foo.def".to_string(),
        ])
        .unwrap();
        assert_eq!(out, Some(PathBuf::from("windows_api/def_out/Foo_types.def")));
    }

    #[test]
    fn annotate_windows_external_linkage_applies_unique_db_match() {
        let temp_root = temp_test_dir("driver_windows_db_unique");
        let windows_api_root = temp_root.join("windows_api");
        let db_path = windows_api_root.join("windows_api.db");
        let source_path = windows_api_root.join("def_in").join("win32apidef").join("WIN32.def");
        fs::create_dir_all(source_path.parent().unwrap()).unwrap();
        fs::write(&source_path, "").unwrap();
        seed_windows_api_db(
            &db_path,
            &[("Beep", "Beep", "KERNEL32.dll")],
        );

        let mut module = parse_module(&tokenize("DEFINITION MODULE WIN32; PROCEDURE Beep(); END WIN32.").unwrap()).unwrap();
        let warnings = annotate_windows_external_linkage(&source_path, &mut module).unwrap();
        assert!(warnings.is_empty());

        let Decl::Procedure(proc_decl) = &module.decls[0] else {
            panic!("expected procedure decl");
        };
        let linkage = proc_decl.external_linkage.as_ref().expect("expected external linkage");
        assert_eq!(linkage.link_name.value, "Beep");
        assert_eq!(linkage.dll_name.as_ref().map(|name| name.value.as_str()), Some("KERNEL32.dll"));
        assert!(linkage.is_external);

        fs::remove_dir_all(temp_root).unwrap();
    }

    #[test]
    fn annotate_windows_external_linkage_skips_ambiguous_db_match() {
        let temp_root = temp_test_dir("driver_windows_db_ambiguous");
        let windows_api_root = temp_root.join("windows_api");
        let db_path = windows_api_root.join("windows_api.db");
        let source_path = windows_api_root.join("def_in").join("win32apidef").join("WIN32.def");
        fs::create_dir_all(source_path.parent().unwrap()).unwrap();
        fs::write(&source_path, "").unwrap();
        seed_windows_api_db(
            &db_path,
            &[
                ("Foo", "Foo", "KERNEL32.dll"),
                ("Foo", "Foo", "USER32.dll"),
            ],
        );

        let mut module = parse_module(&tokenize("DEFINITION MODULE WIN32; PROCEDURE Foo(); END WIN32.").unwrap()).unwrap();
        let warnings = annotate_windows_external_linkage(&source_path, &mut module).unwrap();
        assert_eq!(warnings.len(), 1);

        let Decl::Procedure(proc_decl) = &module.decls[0] else {
            panic!("expected procedure decl");
        };
        assert!(proc_decl.external_linkage.is_none());

        fs::remove_dir_all(temp_root).unwrap();
    }

    fn temp_test_dir(prefix: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("{prefix}_{unique}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn seed_windows_api_db(db_path: &Path, rows: &[(&str, &str, &str)]) {
        if let Some(parent) = db_path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        let conn = Connection::open(db_path).unwrap();
        conn.execute_batch(
            "CREATE TABLE functions (
                function_name TEXT,
                import_name TEXT,
                dll_name TEXT
            );",
        )
        .unwrap();
        let mut stmt = conn
            .prepare("INSERT INTO functions(function_name, import_name, dll_name) VALUES (?1, ?2, ?3)")
            .unwrap();
        for (function_name, import_name, dll_name) in rows {
            stmt.execute(params![function_name, import_name, dll_name]).unwrap();
        }
    }
}
