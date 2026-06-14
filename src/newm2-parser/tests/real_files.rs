//! Corpus test: parse every `.def` in the in-scope reference folders.

use newm2_lexer::{Env, preprocess, tokenize};
use newm2_parser::parse_module;
use std::path::{Path, PathBuf};

fn reference_root() -> Option<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = manifest.parent()?.parent()?.parent()?.join("ADW reference");
    if root.exists() { Some(root) } else { None }
}

/// Confirmed ADW source typos. Not lexer/parser bugs in NewM2.
const KNOWN_ADW_TYPOS: &[&str] = &["PropIdl.def"];

fn parse_folder(folder: &Path) -> (usize, Vec<(PathBuf, String)>) {
    let mut count = 0;
    let mut failures: Vec<(PathBuf, String)> = Vec::new();
    for entry in std::fs::read_dir(folder).expect("readdir") {
        let entry = entry.expect("dirent");
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("def") {
            continue;
        }
        if let Some(name) = path.file_name().and_then(|n| n.to_str())
            && KNOWN_ADW_TYPOS.contains(&name)
        {
            continue;
        }
        let src = std::fs::read(&path).expect("read");
        let s = String::from_utf8_lossy(&src);
        let pp = match preprocess(&s, &Env::target_default()) {
            Ok(p) => p,
            Err(e) => {
                failures.push((path.clone(), format!("preprocess: {e}")));
                continue;
            }
        };
        let toks = match tokenize(&pp) {
            Ok(t) => t,
            Err(e) => {
                failures.push((path.clone(), format!("tokenize: {e}")));
                continue;
            }
        };
        match parse_module(&toks) {
            Ok(_) => count += 1,
            Err(e) => failures.push((path.clone(), format!("parse: {e}"))),
        }
    }
    (count, failures)
}

#[test]
fn iochan_def_parses() {
    let Some(root) = reference_root() else {
        eprintln!("skipping: ADW reference tree not present");
        return;
    };
    let p = root.join("isodef").join("IOChan.def");
    let src = std::fs::read(&p).expect("read");
    let s = String::from_utf8_lossy(&src);
    let pp = preprocess(&s, &Env::target_default()).expect("preprocess");
    let toks = tokenize(&pp).expect("lex");
    let m = parse_module(&toks).expect("parse IOChan");
    assert_eq!(m.name, "IOChan");
}

#[test]
fn full_def_corpus_parses() {
    let Some(root) = reference_root() else {
        eprintln!("skipping: ADW reference tree not present");
        return;
    };
    let folders = ["isodef", "def", "gldef", "win32def", "win32apidef", "advapidef"];
    let mut total_pass = 0;
    let mut total_fail = Vec::new();
    for f in folders {
        let path = root.join(f);
        if !path.exists() {
            eprintln!("note: {} not found, skipping", path.display());
            continue;
        }
        let (passed, failures) = parse_folder(&path);
        println!("{}: {} pass, {} fail", f, passed, failures.len());
        total_pass += passed;
        total_fail.extend(failures);
    }
    if !total_fail.is_empty() {
        let limit = 30usize.min(total_fail.len());
        for (p, e) in &total_fail[..limit] {
            eprintln!("FAIL {}: {e}", p.display());
        }
        if total_fail.len() > limit {
            eprintln!("... and {} more", total_fail.len() - limit);
        }
        panic!(
            "{} of {} reference-tree .def files failed to parse",
            total_fail.len(),
            total_pass + total_fail.len()
        );
    }
    assert!(total_pass > 100, "expected 100+ .def files, got {total_pass}");
}
