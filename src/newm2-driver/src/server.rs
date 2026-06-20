//! `daemon` — the resident compiler service (the "fast channel" for the IDE).
//!
//! A warm process the IDE keeps a Windows named pipe open to, instead of
//! spawning `newm2-driver.exe` (+ LLVM init + temp-file redirect) per build or
//! dump. It speaks a minimal **ptcl** reader: one request = one command line,
//! one response = one string — the same string vocabulary the GUI uses, so the
//! editor and the compiler share a language (see docs/design/fastpanes-script-language.md).
//!
//! Protocol (both directions): a 4-byte little-endian length prefix, then a
//! UTF-8 payload. Structured results are ptcl lists of `{...}` tuples — still
//! strings, but parseable.
//!
//! Slice 1 verbs: `ping`, `version`, `check`, `dump <view>`, `shutdown`.
//! (`build`/`run` reuse the existing run_build path — a later slice.)

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::ptr;

use newm2_ir::{format_ir, lower_module, lower_module_opts, MemoryMode};
use newm2_lexer::{format_tokens, preprocess, tokenize};
use newm2_llvm::CodegenOptions;
use newm2_parser::{format_module, parse_module};
use newm2_sema::{SemaResult, Severity};

use windows_sys::Win32::Foundation::{
    CloseHandle, GetLastError, HANDLE, INVALID_HANDLE_VALUE,
};
use windows_sys::Win32::Storage::FileSystem::{
    FlushFileBuffers, ReadFile, WriteFile, PIPE_ACCESS_DUPLEX,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe,
    PIPE_READMODE_BYTE, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES, PIPE_WAIT,
};

const ERROR_PIPE_CONNECTED: u32 = 535;
const DEFAULT_PIPE_NAME: &str = "newm2";
const MAX_FRAME: usize = 64 * 1024 * 1024;

/// `newm2-driver daemon [--pipe NAME] [--library PATH ...] [...driver flags]`
/// `NAME` is the BARE pipe name (no backslashes — they get mangled by some shells);
/// the daemon serves it at `\\.\pipe\NAME`. The non-`--pipe` flags become the base
/// `DriverOptions` for every request.
pub fn run_daemon(rest: &[String]) -> ExitCode {
    let mut pipe = DEFAULT_PIPE_NAME.to_string();
    let mut base: Vec<String> = Vec::new();
    let mut i = 0;
    while i < rest.len() {
        if rest[i] == "--pipe" {
            if let Some(n) = rest.get(i + 1) {
                pipe = n.clone();
            }
            i += 2;
            continue;
        }
        if let Some(n) = rest[i].strip_prefix("--pipe=") {
            pipe = n.to_string();
            i += 1;
            continue;
        }
        base.push(rest[i].clone());
        i += 1;
    }
    serve(base, pipe)
}

fn serve(base_args: Vec<String>, pipe_name: String) -> ExitCode {
    let full = format!(r"\\.\pipe\{pipe_name}");
    let wname: Vec<u16> = full.encode_utf16().chain(std::iter::once(0)).collect();
    eprintln!("newm2 daemon: listening on {full}");
    loop {
        let h = unsafe {
            CreateNamedPipeW(
                wname.as_ptr(),
                PIPE_ACCESS_DUPLEX,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                PIPE_UNLIMITED_INSTANCES,
                1 << 16,
                1 << 16,
                0,
                ptr::null(),
            )
        };
        if h == INVALID_HANDLE_VALUE {
            eprintln!("newm2 daemon: CreateNamedPipe failed ({})", unsafe { GetLastError() });
            return ExitCode::from(1);
        }
        let ok = unsafe { ConnectNamedPipe(h, ptr::null_mut()) };
        let connected = ok != 0 || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
        let mut stop = false;
        if connected {
            // serve frames on this connection until the client closes (or shutdown)
            while let Some(req) = read_frame(h) {
                let (resp, halt) = handle(&req, &base_args);
                if !write_frame(h, resp.as_bytes()) {
                    break;
                }
                if halt {
                    stop = true;
                    break;
                }
            }
        }
        unsafe {
            FlushFileBuffers(h); // block until the client has drained the last response
            DisconnectNamedPipe(h);
            CloseHandle(h);
        }
        if stop {
            eprintln!("newm2 daemon: shutdown");
            return ExitCode::SUCCESS;
        }
    }
}

// ---- framing ----

fn read_exact(h: HANDLE, buf: &mut [u8]) -> bool {
    let mut got = 0usize;
    while got < buf.len() {
        let mut n: u32 = 0;
        let ok = unsafe {
            ReadFile(
                h,
                buf[got..].as_mut_ptr().cast(),
                (buf.len() - got) as u32,
                &mut n,
                ptr::null_mut(),
            )
        };
        if ok == 0 || n == 0 {
            return false;
        }
        got += n as usize;
    }
    true
}

fn read_frame(h: HANDLE) -> Option<String> {
    let mut len_buf = [0u8; 4];
    if !read_exact(h, &mut len_buf) {
        return None;
    }
    let len = u32::from_le_bytes(len_buf) as usize;
    if len == 0 {
        return Some(String::new());
    }
    if len > MAX_FRAME {
        return None;
    }
    let mut buf = vec![0u8; len];
    if !read_exact(h, &mut buf) {
        return None;
    }
    Some(String::from_utf8_lossy(&buf).into_owned())
}

fn write_all(h: HANDLE, buf: &[u8]) -> bool {
    let mut sent = 0usize;
    while sent < buf.len() {
        let mut n: u32 = 0;
        let ok = unsafe {
            WriteFile(
                h,
                buf[sent..].as_ptr().cast(),
                (buf.len() - sent) as u32,
                &mut n,
                ptr::null_mut(),
            )
        };
        if ok == 0 || n == 0 {
            return false;
        }
        sent += n as usize;
    }
    true
}

fn write_frame(h: HANDLE, payload: &[u8]) -> bool {
    write_all(h, &(payload.len() as u32).to_le_bytes()) && write_all(h, payload)
}

// ---- minimal ptcl reader ----

/// Split a command line into words, honouring `"quotes"` and balanced `{braces}`.
/// (No `$`/`[]` substitution yet — that is the full evaluator, a later slice.)
fn read_words(line: &str) -> Vec<String> {
    let cs: Vec<char> = line.chars().collect();
    let mut words = Vec::new();
    let mut i = 0;
    while i < cs.len() {
        while i < cs.len() && cs[i].is_whitespace() {
            i += 1;
        }
        if i >= cs.len() {
            break;
        }
        let mut w = String::new();
        match cs[i] {
            '"' => {
                i += 1;
                while i < cs.len() && cs[i] != '"' {
                    w.push(cs[i]);
                    i += 1;
                }
                if i < cs.len() {
                    i += 1;
                }
            }
            '{' => {
                let mut depth = 1;
                i += 1;
                while i < cs.len() && depth > 0 {
                    match cs[i] {
                        '{' => {
                            depth += 1;
                            w.push('{');
                        }
                        '}' => {
                            depth -= 1;
                            if depth > 0 {
                                w.push('}');
                            }
                        }
                        c => w.push(c),
                    }
                    i += 1;
                }
            }
            _ => {
                while i < cs.len() && !cs[i].is_whitespace() {
                    w.push(cs[i]);
                    i += 1;
                }
            }
        }
        words.push(w);
    }
    words
}

/// Collapse a message to one line (responses are line-oriented: status line +
/// payload lines, so a diagnostic must not contain embedded newlines).
fn oneline(s: &str) -> String {
    s.replace('\r', "").replace('\n', " ")
}

fn err(msg: impl std::fmt::Display) -> String {
    format!("error {}", oneline(&msg.to_string()))
}

/// One diagnostic line: `LINE COL SEV MESSAGE` (MESSAGE is the rest of the line).
fn diag(line: usize, col: usize, sev: &str, msg: &str) -> String {
    format!("{} {} {} {}", line, col, sev, oneline(msg))
}

// ---- dispatch ----

fn handle(req: &str, base_args: &[String]) -> (String, bool) {
    let words = read_words(req);
    let Some(verb) = words.first() else {
        return (String::new(), false);
    };
    match verb.as_str() {
        "ping" => ("pong".to_string(), false),
        "version" => (format!("newm2-daemon {}", env!("CARGO_PKG_VERSION")), false),
        "shutdown" => ("bye".to_string(), true),
        "check" => (cmd_check(words.get(1), base_args), false),
        "analyze" => (cmd_analyze(words.get(1), base_args), false),
        "complete" => (cmd_complete(words.get(1), words.get(2), words.get(3), base_args), false),
        "build" => (cmd_build(words.get(1), words.get(2), base_args), false),
        "run" => (cmd_run(words.get(1), base_args), false),
        "dump" => (cmd_dump(words.get(1), words.get(2), base_args), false),
        other => (err(format!("unknown command: {other}")), false),
    }
}

fn options(base_args: &[String]) -> Result<crate::DriverOptions, String> {
    crate::DriverOptions::parse(base_args)
}

/// Newline-joined `LINE COL SEV MESSAGE` lines, one per diagnostic.
fn diags_list(res: &SemaResult) -> String {
    let mut lines: Vec<String> = Vec::new();
    for d in &res.diagnostics {
        let sev = match d.severity {
            Severity::Error => "error",
            Severity::Warning => "warning",
        };
        lines.push(diag(d.span.start.line, d.span.start.column, sev, &d.message));
    }
    lines.join("\n")
}

/// `check <file>` -> `ok` (clean) or `errors\n<LINE COL SEV MSG lines>`.
/// Parse + sema only, no codegen — the as-you-type fast path.
fn cmd_check(file: Option<&String>, base_args: &[String]) -> String {
    let Some(file) = file else {
        return err("check: missing file");
    };
    let opts = match options(base_args) {
        Ok(o) => o,
        Err(e) => return err(e),
    };
    let graph = match crate::build_graph_from_entry(Path::new(file), &opts) {
        Ok(g) => g,
        Err(e) => return format!("errors\n{}", diag(0, 0, "error", &e.to_string())),
    };
    let res = crate::check_graph(&graph, &opts);
    let list = diags_list(&res);
    if list.is_empty() {
        "ok".to_string()
    } else {
        format!("errors\n{list}")
    }
}

/// `analyze <file>` -> `ok` or `errors\n<LINE COL SEV MSG lines>`. Runs sema
/// (errors) PLUS the static NEW/DISPOSE pass (warnings: leak, double-DISPOSE,
/// use-after-DISPOSE), merged + sorted by source position.
fn cmd_analyze(file: Option<&String>, base_args: &[String]) -> String {
    let Some(file) = file else {
        return err("analyze: missing file");
    };
    let opts = match options(base_args) {
        Ok(o) => o,
        Err(e) => return err(e),
    };
    let graph = match crate::build_graph_from_entry(Path::new(file), &opts) {
        Ok(g) => g,
        Err(e) => return format!("errors\n{}", diag(0, 0, "error", &e.to_string())),
    };
    let res = crate::check_graph(&graph, &opts);
    let warns = newm2_sema::analyze_new_dispose(&graph);
    let mut all: Vec<&newm2_sema::Diagnostic> = res.diagnostics.iter().chain(warns.iter()).collect();
    all.sort_by_key(|d| (d.span.start.line, d.span.start.column));
    let lines: Vec<String> = all
        .iter()
        .map(|d| {
            let sev = match d.severity {
                Severity::Error => "error",
                Severity::Warning => "warning",
            };
            diag(d.span.start.line, d.span.start.column, sev, &d.message)
        })
        .collect();
    if lines.is_empty() {
        "ok".to_string()
    } else {
        format!("errors\n{}", lines.join("\n"))
    }
}

/// `complete <file> <line> <col>` -> completion candidates, one per line as
/// `name<TAB>kind<TAB>detail`; `ok` when there are none. `line` is 1-based,
/// `col` is 0-based (chars before the cursor on that line). Reuses the warm
/// graph + sema path; the heavy logic lives in `crate::complete_core`.
fn cmd_complete(
    file: Option<&String>,
    line: Option<&String>,
    col: Option<&String>,
    base_args: &[String],
) -> String {
    let Some(file) = file else {
        return err("complete: missing file");
    };
    let Some(line) = line.and_then(|s| s.parse::<usize>().ok()) else {
        return err("complete: bad line");
    };
    let Some(col) = col.and_then(|s| s.parse::<usize>().ok()) else {
        return err("complete: bad col");
    };
    let opts = match options(base_args) {
        Ok(o) => o,
        Err(e) => return err(e),
    };
    let cands = crate::complete_core(file, line, col, &opts);
    if cands.is_empty() {
        return "ok".to_string();
    }
    cands
        .iter()
        .map(|c| format!("{}\t{}\t{}", c.name, c.kind, oneline(&c.detail)))
        .collect::<Vec<_>>()
        .join("\n")
}

/// The outcome of an AOT build, shared by `build` and `run`.
enum Built {
    Exe(PathBuf),
    Diags(String), // sema errors as a ptcl diag list
    Failed(String), // load / codegen / link failure
}

fn do_build(file: &str, out: Option<&str>, opts: &crate::DriverOptions) -> Built {
    let entry = Path::new(file);
    let graph = match crate::build_graph_from_entry(entry, opts) {
        Ok(g) => g,
        Err(e) => return Built::Failed(e.to_string()),
    };
    let sema = crate::check_graph(&graph, opts);
    if sema.has_errors() {
        return Built::Diags(diags_list(&sema));
    }
    let mode = MemoryMode::NoGc;
    let cgopts = CodegenOptions { memory_mode: mode, opt_level: 0, aot: true, m2_heap: opts.m2_heap, protect_heap: opts.protect_heap };
    let lowered: Vec<_> = graph
        .topo_order
        .iter()
        .filter_map(|&mid| lower_module_opts(&graph, mid, &sema, mode, opts.runtime_checks))
        .collect();
    let lowered_refs: Vec<_> = lowered.iter().collect();
    let exe_path: PathBuf = match out {
        Some(o) => PathBuf::from(o),
        None => {
            let stem = entry.file_stem().and_then(|s| s.to_str()).unwrap_or("a");
            entry.with_file_name(format!("{stem}.exe"))
        }
    };
    let obj_path = exe_path.with_extension("obj");
    if let Err(e) = newm2_llvm::emit_aot_object(&lowered_refs, &sema, cgopts, &obj_path) {
        return Built::Failed(format!("codegen: {e}"));
    }
    let import_libs = crate::collect_import_libs(&lowered);
    let gui = opts.gui || crate::entry_has_gui_pragma(&graph);
    match crate::link_executable(&obj_path, &exe_path, &[], &import_libs, gui) {
        Ok(()) => Built::Exe(exe_path),
        Err(e) => Built::Failed(format!("link: {e}")),
    }
}

/// `build <file> [out]` -> `ok <exe>` / `errors <diag-list>` / `error <msg>`.
fn cmd_build(file: Option<&String>, out: Option<&String>, base_args: &[String]) -> String {
    let Some(file) = file else {
        return err("build: missing file");
    };
    let opts = match options(base_args) {
        Ok(o) => o,
        Err(e) => return err(e),
    };
    match do_build(file, out.map(|s| s.as_str()), &opts) {
        Built::Exe(p) => format!("ok {}", p.display()),
        Built::Diags(d) => format!("errors\n{d}"),
        Built::Failed(m) => err(m),
    }
}

/// `run <file>` -> AOT-build to a temp exe, spawn it, capture stdout+stderr.
/// `ok <program-output>` / `errors <diag-list>` / `error <msg>`.
fn cmd_run(file: Option<&String>, base_args: &[String]) -> String {
    let Some(file) = file else {
        return err("run: missing file");
    };
    let opts = match options(base_args) {
        Ok(o) => o,
        Err(e) => return err(e),
    };
    let stem = Path::new(file).file_stem().and_then(|s| s.to_str()).unwrap_or("prog");
    let tmp = std::env::temp_dir().join(format!("newm2_run_{stem}.exe"));
    let tmp_s = tmp.display().to_string();
    match do_build(file, Some(&tmp_s), &opts) {
        Built::Exe(exe) => match std::process::Command::new(&exe).output() {
            Ok(o) => {
                let mut s = String::from_utf8_lossy(&o.stdout).into_owned();
                let e = String::from_utf8_lossy(&o.stderr);
                if !e.is_empty() {
                    s.push_str(&e);
                }
                format!("ok\n{s}")
            }
            Err(e) => err(format!("run: spawn: {e}")),
        },
        Built::Diags(d) => format!("errors\n{d}"),
        Built::Failed(m) => err(m),
    }
}

/// `dump <view> <file>` -> the inspector text (tokens/ast/ir).
fn cmd_dump(view: Option<&String>, file: Option<&String>, base_args: &[String]) -> String {
    let (Some(view), Some(file)) = (view, file) else {
        return err("dump: usage: dump <tokens|ast|ir> <file>");
    };
    let opts = match options(base_args) {
        Ok(o) => o,
        Err(e) => return err(&e),
    };
    match view.as_str() {
        "tokens" => dump_tokens(file, &opts),
        "ast" => dump_ast(file, &opts),
        "ir" => dump_ir(file, &opts),
        other => err(&format!("dump: unknown view: {other}")),
    }
}

fn read_src(file: &str) -> Result<String, String> {
    std::fs::read(file)
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .map_err(|e| format!("read {file}: {e}"))
}

fn dump_tokens(file: &str, opts: &crate::DriverOptions) -> String {
    let s = match read_src(file) {
        Ok(s) => s,
        Err(e) => return err(&e),
    };
    let pp = match preprocess(&s, &opts.env) {
        Ok(p) => p,
        Err(e) => return err(&e),
    };
    match tokenize(&pp) {
        Ok(t) => format_tokens(&t),
        Err(e) => err(&e),
    }
}

fn dump_ast(file: &str, opts: &crate::DriverOptions) -> String {
    let s = match read_src(file) {
        Ok(s) => s,
        Err(e) => return err(&e),
    };
    let pp = match preprocess(&s, &opts.env) {
        Ok(p) => p,
        Err(e) => return err(&e),
    };
    let tokens = match tokenize(&pp) {
        Ok(t) => t,
        Err(e) => return err(&e),
    };
    match parse_module(&tokens) {
        Ok(m) => format_module(&m),
        Err(e) => err(&e),
    }
}

fn dump_ir(file: &str, opts: &crate::DriverOptions) -> String {
    let graph = match crate::build_graph_from_entry(Path::new(file), opts) {
        Ok(g) => g,
        Err(e) => return err(&e.to_string()),
    };
    let sema = crate::check_graph(&graph, opts);
    let mut out = String::new();
    for &mid in &graph.topo_order {
        if let Some(ir) = lower_module(&graph, mid, &sema, MemoryMode::NoGc) {
            out.push_str(&format_ir(&ir));
        }
    }
    if out.is_empty() {
        return err("dump ir: no lowerable modules");
    }
    out
}
