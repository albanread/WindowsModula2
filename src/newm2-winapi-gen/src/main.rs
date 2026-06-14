//! `newm2-winapi-gen` — generate Win32 `.def` modules from windows_api.db.
//!
//!   newm2-winapi-gen --db <path> [--win32-base] [--namespace <NS>]...
//!                    [--out <dir> | --stdout] [--check]

use std::path::PathBuf;
use std::process::ExitCode;

use newm2_winapi_gen::{
    build_cross_index, db, generate_namespace_with_ifaces, generate_win32_base, module_name_for,
    parses, InterfaceIndex,
};

struct Args {
    db_path: String,
    namespaces: Vec<String>,
    all: bool,
    out: Option<PathBuf>,
    win32_base: bool,
    stdout: bool,
    check: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        db_path: String::new(),
        namespaces: Vec::new(),
        all: false,
        out: None,
        win32_base: false,
        stdout: false,
        check: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--db" => a.db_path = it.next().ok_or("--db expects a path")?,
            "--namespace" => a.namespaces.push(it.next().ok_or("--namespace expects a value")?),
            "--all" => a.all = true,
            "--out" => a.out = Some(PathBuf::from(it.next().ok_or("--out expects a dir")?)),
            "--win32-base" => a.win32_base = true,
            "--stdout" => a.stdout = true,
            "--check" => a.check = true,
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    if a.db_path.is_empty() {
        return Err("--db is required".into());
    }
    if a.out.is_none() {
        a.stdout = true;
    }
    Ok(a)
}

fn emit(args: &Args, module_name: &str, text: &str) -> Result<(), String> {
    if args.check {
        match parses(text) {
            Ok(()) => eprintln!("  check: {module_name} parses OK"),
            Err(e) => eprintln!("  check: {module_name} FAILED to parse: {e}"),
        }
    }
    if let Some(dir) = &args.out {
        std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
        let path = dir.join(format!("{module_name}_types.def"));
        std::fs::write(&path, text).map_err(|e| format!("write {}: {e}", path.display()))?;
        eprintln!("  wrote {}", path.display());
    }
    if args.stdout {
        println!("(* ===== {module_name}_types.def ===== *)");
        print!("{text}");
    }
    Ok(())
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
    let conn = db::open(&args.db_path).map_err(|e| format!("open db: {e}"))?;

    // Every namespace in the DB — used to build the cross-index from the WHOLE
    // surface so a targeted (single-namespace) regen still resolves its
    // cross-namespace struct/enum references (e.g. Direct2D fields that are
    // Graphics_Direct2D_Common.D2D_SIZE_F). Otherwise those degrade to ADDRESS.
    let all_namespaces =
        db::list_win32_namespaces(&conn).map_err(|e| format!("list namespaces: {e}"))?;
    let namespaces = if args.all { all_namespaces.clone() } else { args.namespaces.clone() };

    if args.win32_base || args.all {
        emit(&args, "WIN32", &generate_win32_base())?;
    }

    let index = build_cross_index(&conn, &all_namespaces).map_err(|e| format!("index: {e}"))?;
    // Cross-namespace interface index: absolute vtable ordinals + base
    // resolution span ALL interfaces in the DB, not just the ones being emitted
    // (a base like IUnknown may live in a namespace not on this run's list).
    let iface_index = InterfaceIndex::load(&conn).map_err(|e| format!("interface index: {e}"))?;
    let mut total_warnings = 0usize;
    for ns in &namespaces {
        let g = generate_namespace_with_ifaces(&conn, ns, &index, Some(&iface_index))
            .map_err(|e| format!("generate {ns}: {e}"))?;
        total_warnings += g.warnings.len();
        if !args.all {
            eprintln!("namespace {ns} -> module {} ({} warnings)", g.module_name, g.warnings.len());
            for w in g.warnings.iter().take(15) {
                eprintln!("    warn: {w}");
            }
            if g.warnings.len() > 15 {
                eprintln!("    ... {} more warnings", g.warnings.len() - 15);
            }
        }
        emit(&args, &module_name_for(ns), &g.text)?;
    }
    if args.all {
        eprintln!(
            "generated {} modules + WIN32 base ({} total resolver warnings)",
            namespaces.len(),
            total_warnings
        );
    }
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("newm2-winapi-gen: error: {e}");
            ExitCode::FAILURE
        }
    }
}
