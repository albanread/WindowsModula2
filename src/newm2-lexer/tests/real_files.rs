//! Integration test: lex a handful of real `.def` files from the ADW
//! reference tree and confirm they tokenize without error.
//!
//! This is *compiler input*, not source material for NewM2's own runtime.

use newm2_lexer::{Env, preprocess, tokenize};
use std::path::{Path, PathBuf};

fn reference_root() -> Option<PathBuf> {
    // Plan locates the reference tree at E:\NewM2\ADW reference\.
    // Resolve from CARGO_MANIFEST_DIR up two levels to E:\NewM2\NewM2,
    // then up one more to E:\NewM2.
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = manifest.parent()?.parent()?.parent()?.join("ADW reference");
    if root.exists() { Some(root) } else { None }
}

fn lex_file(path: &Path) {
    let src = std::fs::read(path).expect("read");
    // .def files in the reference tree are Latin-1ish; lossy-decode for now.
    let s = String::from_utf8_lossy(&src);
    let pp = preprocess(&s, &Env::target_default()).unwrap_or_else(|e| {
        panic!("preprocess failed for {}: {e}", path.display())
    });
    let toks = tokenize(&pp).unwrap_or_else(|e| {
        panic!("tokenize failed for {}: {e}", path.display())
    });
    assert!(!toks.is_empty(), "{} produced no tokens", path.display());
}

#[test]
fn iochan_def_tokenizes() {
    let Some(root) = reference_root() else {
        eprintln!("skipping: ADW reference tree not present");
        return;
    };
    lex_file(&root.join("isodef").join("IOChan.def"));
}

#[test]
fn memutils_def_tokenizes() {
    // Stresses ADW `[Pass(...),Alters(...)]` procedure attributes and
    // inline `%IF IA32 %THEN Alters %ELSE Returns %END` inside brackets.
    let Some(root) = reference_root() else {
        eprintln!("skipping: ADW reference tree not present");
        return;
    };
    lex_file(&root.join("def").join("MemUtils.def"));
}

/// Files in the reference tree with confirmed ADW source typos.
/// These are *not* lexer bugs in NewM2.
///
/// - `PropIdl.def`: line 220 starts a variant-record arm with `!`
///   where `|` was clearly intended (every other arm in the same
///   record uses `|`).
const KNOWN_ADW_TYPOS: &[&str] = &["PropIdl.def"];

/// Run the lexer over every `.def` in the given folder, returning
/// (passed, failures).
fn lex_folder(folder: &Path) -> (usize, Vec<(PathBuf, String)>) {
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
        match tokenize(&pp) {
            Ok(_) => count += 1,
            Err(e) => failures.push((path.clone(), format!("tokenize: {e}"))),
        }
    }
    (count, failures)
}

#[test]
fn full_def_corpus_lexes() {
    let Some(root) = reference_root() else {
        eprintln!("skipping: ADW reference tree not present");
        return;
    };
    // In-scope folders per the plan §7 Phase 1.
    // comlibdef/ and cryptodef/ are deferred to Phase 14.
    let folders = ["isodef", "def", "gldef", "win32def", "win32apidef", "advapidef"];
    let mut total_pass = 0;
    let mut total_fail = Vec::new();
    for f in folders {
        let path = root.join(f);
        if !path.exists() {
            eprintln!("note: {} not found, skipping", path.display());
            continue;
        }
        let (passed, failures) = lex_folder(&path);
        println!("{}: {} pass, {} fail", f, passed, failures.len());
        total_pass += passed;
        total_fail.extend(failures);
    }
    if !total_fail.is_empty() {
        for (p, e) in &total_fail {
            eprintln!("FAIL {}: {e}", p.display());
        }
        panic!(
            "{} of {} reference-tree .def files failed to lex",
            total_fail.len(),
            total_pass + total_fail.len()
        );
    }
    assert!(total_pass > 100, "expected 100+ .def files, got {total_pass}");
}
