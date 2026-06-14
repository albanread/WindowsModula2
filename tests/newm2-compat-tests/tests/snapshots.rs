//! Phase-output snapshot tests. The fixture files live next to this
//! crate in `<crate root>/<name>.expected`. Each test:
//! 1. Runs the pipeline on a known reference-tree input.
//! 2. Compares the textual dump to the fixture.
//!
//! On a real change in output, `UPDATE_SNAPSHOTS=1 cargo test` rewrites
//! the fixtures so they can be reviewed in git.

use newm2_lexer::{Env, preprocess, tokenize};
use newm2_loader::{SearchPath, build_module_graph, format_graph};
use newm2_parser::{format_module, parse_module};
use std::path::PathBuf;

fn reference_root() -> Option<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = manifest.parent()?.parent()?.parent()?.join("ADW reference");
    if root.exists() { Some(root) } else { None }
}

fn fixture_path(name: &str) -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest.join(name)
}

fn dump_ast_of(path: &std::path::Path) -> String {
    let src = std::fs::read(path).expect("read");
    let s = String::from_utf8_lossy(&src);
    let pp = preprocess(&s, &Env::target_default()).expect("preprocess");
    let toks = tokenize(&pp).expect("tokenize");
    let m = parse_module(&toks).expect("parse");
    format_module(&m)
}

/// Compare `actual` to the named fixture. Under `UPDATE_SNAPSHOTS=1`,
/// rewrite the fixture instead of failing.
fn assert_snapshot(name: &str, actual: &str) {
    let path = fixture_path(name);
    let update = std::env::var("UPDATE_SNAPSHOTS").is_ok();
    if update {
        std::fs::write(&path, actual).expect("write fixture");
        return;
    }
    let expected = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read fixture {}: {e}", path.display()));
    if actual != expected {
        // Show first differing region.
        let mut a_lines = actual.lines();
        let mut e_lines = expected.lines();
        let mut lineno = 1;
        loop {
            match (a_lines.next(), e_lines.next()) {
                (Some(a), Some(e)) if a == e => {
                    lineno += 1;
                }
                (a, e) => {
                    panic!(
                        "snapshot {} mismatch at line {lineno}:\n  expected: {:?}\n  actual:   {:?}\n\nrun `UPDATE_SNAPSHOTS=1 cargo test` to refresh.",
                        path.display(),
                        e,
                        a,
                    );
                }
            }
        }
    }
}

#[test]
fn iochan_def_ast_snapshot() {
    let Some(root) = reference_root() else {
        eprintln!("skipping: ADW reference tree not present");
        return;
    };
    let actual = dump_ast_of(&root.join("isodef").join("IOChan.def"));
    assert_snapshot("iochan.expected", &actual);
}

#[test]
fn classes_def_ast_snapshot() {
    // Targeted minimal fixture exercising ISO 10514-2 OO:
    // FORWARD class, abstract class with abstract method, abstract
    // class with INHERIT + REVEAL + abstract method with VAR param.
    let path = fixture_path("fixtures").join("classes.def");
    let actual = dump_ast_of(&path);
    assert_snapshot("classes.expected", &actual);
}

#[test]
fn hello_module_graph_snapshot() {
    // Phase 2 exit criterion: a five-module hello-world graph rooted
    // at fixtures/hello.mod that pulls in IOChan, IOConsts, ChanConsts,
    // and the SYSTEM intrinsic.
    let Some(root) = reference_root() else {
        eprintln!("skipping: ADW reference tree not present");
        return;
    };
    let entry = fixture_path("fixtures").join("hello.mod");
    let mut sp = SearchPath::new();
    sp.push(entry.parent().unwrap());
    sp.push(root.join("isodef"));
    let g = build_module_graph(&entry, &sp).expect("graph");
    let actual = format_graph(&g);
    // Sanity: the graph contains exactly the expected five modules.
    assert_eq!(g.modules.len(), 5, "expected 5 modules, got {}", g.modules.len());
    assert!(g.lookup("Hello").is_some());
    assert!(g.lookup("IOChan").is_some());
    assert!(g.lookup("IOConsts").is_some());
    assert!(g.lookup("ChanConsts").is_some());
    let sys = g.lookup("SYSTEM").expect("SYSTEM present");
    assert!(g.get(sys).is_intrinsic);
    assert_snapshot("hello_graph.expected", &actual);
}

#[test]
fn shobjidl_def_ast_snapshot() {
    // Real-world OO file with 18 ABSTRACT CLASS declarations spanning
    // INHERIT chains, REVEAL lists, and abstract methods with mixed
    // parameter modes. Catches regressions in OO dump rendering
    // across the full ADW COM-interface pattern.
    let Some(root) = reference_root() else {
        eprintln!("skipping: ADW reference tree not present");
        return;
    };
    let actual = dump_ast_of(&root.join("win32apidef").join("ShObjIdl.def"));
    assert_snapshot("shobjidl.expected", &actual);
}
