//! NewM2 loader — module graph, DEF/IMPL pairing, symbol-file cache.
//!
//! Responsibilities:
//! - Resolve `IMPORT` clauses against the search path.
//! - Pair DEFINITION MODULE with IMPLEMENTATION MODULE.
//! - Track LOCAL MODULE nested in procedures.
//! - Hash DEF separately to drive incremental rebuilds: change a
//!   `.def` invalidates every importer; change a `.mod` body
//!   invalidates nothing else.
//! - Symbol-file cache keyed by
//!   `(def-source hash, transitive DEF hashes, compiler version,
//!    codegen flags, memory-mode)`.

pub mod cache;
pub mod graph;
pub mod loader;
pub mod print;
pub mod search_path;
pub mod win32_finder;

pub use cache::{Cache, CacheKey, ContentHash, MemoryMode, hash_source};
pub use graph::{ModuleGraph, ModuleId, ModuleNode};
pub use loader::{
    INTRINSIC_MODULES,
    LoadError,
    build_module_graph,
    build_module_graph_with_env,
    build_module_graph_with_env_and_pack,
    build_module_graph_with_extra_roots,
    parse_file,
    parse_file_with_env,
};
pub use print::format_graph;
pub use search_path::SearchPath;

#[cfg(test)]
mod tests {
    use super::*;
    use newm2_lexer::Env;
    use newm2_parser::ast;
    use std::fs;

    fn tmpdir(name: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("newm2-loader-{}", name));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn loads_three_module_chain() {
        let dir = tmpdir("chain");
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\nFROM Foo IMPORT a;\nBEGIN\nEND Hello.\n",
        )
        .unwrap();
        fs::write(
            dir.join("Foo.def"),
            "DEFINITION MODULE Foo;\nFROM Bar IMPORT b;\nCONST a = 1;\nEND Foo.\n",
        )
        .unwrap();
        fs::write(
            dir.join("Bar.def"),
            "DEFINITION MODULE Bar;\nCONST b = 2;\nEND Bar.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let g = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap();
        assert_eq!(g.modules.len(), 3);
        assert_eq!(g.topo_order.len(), 3);
        // Topo order: Bar before Foo before Hello.
        let names: Vec<&str> =
            g.topo_order.iter().map(|i| g.modules[i.0].name.as_str()).collect();
        assert_eq!(names, vec!["Bar", "Foo", "Hello"]);
    }

    #[test]
    fn allows_circular_imports() {
        // Circular imports are legal in ISO Modula-2 (IOChan ↔ IOLink). The
        // loader must break the cycle and still produce a usable graph.
        let dir = tmpdir("cycle");
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\nFROM A IMPORT x;\nBEGIN\nEND Hello.\n",
        )
        .unwrap();
        fs::write(
            dir.join("A.def"),
            "DEFINITION MODULE A;\nFROM B IMPORT y;\nCONST x = 1;\nEND A.\n",
        )
        .unwrap();
        fs::write(
            dir.join("B.def"),
            "DEFINITION MODULE B;\nFROM A IMPORT x;\nCONST y = 2;\nEND B.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let g = build_module_graph(&dir.join("Hello.mod"), &sp).expect("circular imports allowed");
        assert!(g.modules.len() >= 3, "expected Hello, A, B in the graph");
    }

    #[test]
    fn system_intrinsic_resolves_without_disk_file() {
        let dir = tmpdir("intrinsic");
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\nFROM SYSTEM IMPORT ADDRESS;\nBEGIN\nEND Hello.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let g = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap();
        let sys = g.lookup("SYSTEM").expect("SYSTEM present");
        assert!(g.get(sys).is_intrinsic);
        assert!(g.get(sys).def_path.is_none());
    }

    #[test]
    fn coroutines_intrinsic_resolves_without_disk_file() {
        let dir = tmpdir("coroutines_intrinsic");
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\nIMPORT COROUTINES;\nBEGIN\nEND Hello.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let g = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap();
        let coroutines = g.lookup("COROUTINES").expect("COROUTINES present");
        assert!(g.get(coroutines).is_intrinsic);
        assert!(g.get(coroutines).def_path.is_none());
    }

    #[test]
    fn unknown_import_errors() {
        let dir = tmpdir("unknown");
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\nFROM Nope IMPORT x;\nBEGIN\nEND Hello.\n",
        )
        .unwrap();
        let sp = SearchPath::new();
        let err = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap_err();
        assert!(err.to_string().contains("Nope"), "{err}");
    }

    #[test]
    fn enumerates_local_modules() {
        let dir = tmpdir("local");
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\n\
             PROCEDURE P();\n\
                 MODULE Inner;\n\
                 CONST x = 1;\n\
                 END Inner;\n\
             BEGIN END P;\n\
             BEGIN END Hello.\n",
        )
        .unwrap();
        let sp = SearchPath::new();
        let g = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap();
        let hello = g.lookup("Hello").unwrap();
        assert_eq!(g.get(hello).local_modules, vec!["Inner".to_string()]);
    }

    #[test]
    fn env_aware_graph_builder_honors_value_conditions() {
        let dir = tmpdir("value-env");
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\nCONST x = %IF Flavor = debug %THEN 1 %ELSE 2 %END;\nBEGIN\nEND Hello.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let env = Env::empty().with_value("Flavor", "debug");
        let g = build_module_graph_with_env(&dir.join("Hello.mod"), &sp, &env).unwrap();
        let hello = g.lookup("Hello").unwrap();
        let module = g.get(hello).impl_ast.as_ref().unwrap();
        let ast::Decl::Const(item) = &module.decls[0] else {
            panic!("expected CONST declaration");
        };
        assert!(matches!(item.value, ast::Expr::Integer(1, _)));
    }

    #[test]
    fn graph_builder_can_resolve_imports_from_win32_finder() {
        let dir = tmpdir("win32-finder");
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\nIMPORT Foo;\nBEGIN\nEND Hello.\n",
        )
        .unwrap();

        // The finder indexes generated `*_types.def` files under a NewM2 root.
        let newm2_root = dir.join("library").join("NewM2");
        fs::create_dir_all(&newm2_root).unwrap();
        fs::write(
            newm2_root.join("Foo_types.def"),
            "DEFINITION MODULE Foo;\nTYPE T = INTEGER;\nEND Foo.\n",
        )
        .unwrap();
        let finder = crate::win32_finder::build_win32_finder(&newm2_root).unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let g = build_module_graph_with_env_and_pack(
            &dir.join("Hello.mod"),
            &sp,
            &Env::target_default(),
            Some(&finder),
        )
        .unwrap();

        let foo = g.lookup("Foo").expect("Foo should resolve via the finder");
        assert!(g.get(foo).def_ast.is_some());
    }

    #[test]
    fn win32_finder_is_authoritative_over_same_named_filesystem_def() {
        // The baked-in Win32 finder is consulted before the filesystem search
        // path (see `resolve_or_load`): a generated Win32 module always resolves
        // to our generated def and can never be shadowed by a same-named file
        // elsewhere on the path (e.g. an ADW reference def). This is the
        // deliberate "WIN32 is authoritative" rule.
        let dir = tmpdir("finder-authoritative");
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\nIMPORT Timers;\nBEGIN\nEND Hello.\n",
        )
        .unwrap();

        // A same-named def sitting on the filesystem search path.
        let fs_lib = dir.join("library").join("advapidef");
        fs::create_dir_all(&fs_lib).unwrap();
        fs::write(
            fs_lib.join("Timers.def"),
            "DEFINITION MODULE Timers;\nCONST from_filesystem = 1;\nEND Timers.\n",
        )
        .unwrap();

        // The generated def the finder indexes.
        let newm2_root = dir.join("library").join("NewM2");
        fs::create_dir_all(&newm2_root).unwrap();
        fs::write(
            newm2_root.join("Timers_types.def"),
            "DEFINITION MODULE Timers;\nCONST from_finder = 2;\nEND Timers.\n",
        )
        .unwrap();
        let finder = crate::win32_finder::build_win32_finder(&newm2_root).unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        sp.push(&fs_lib);
        let g = build_module_graph_with_env_and_pack(
            &dir.join("Hello.mod"),
            &sp,
            &Env::target_default(),
            Some(&finder),
        )
        .unwrap();

        let timers = g.lookup("Timers").unwrap();
        let ast = g.get(timers).def_ast.as_ref().unwrap();
        let rendered = newm2_parser::format_module(ast);
        assert!(rendered.contains("from_finder"), "finder def should win: {rendered}");
        assert!(!rendered.contains("from_filesystem"), "{rendered}");
    }

    #[test]
    fn implementation_with_case_mismatched_def_is_rejected() {
        // An IMPLEMENTATION module must pair with its *exactly* named DEF.
        // Modula-2 is case-sensitive, so a def whose module name differs only by
        // case is a *different* module — pairing it would be wrong and silently
        // dropping it would lose the interface. It must be a hard error, not a
        // skip.
        let dir = tmpdir("impl_case_mismatch");
        fs::write(dir.join("Foo.mod"), "IMPLEMENTATION MODULE Foo;\nEND Foo.\n").unwrap();
        fs::write(dir.join("Foo.def"), "DEFINITION MODULE foo;\nEND foo.\n").unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let err = build_module_graph(&dir.join("Foo.mod"), &sp)
            .expect_err("case-mismatched impl/def must be rejected");
        assert!(err.message.contains("module name mismatch"), "got: {}", err.message);
    }

    #[test]
    fn program_with_case_colliding_library_def_stays_unpaired() {
        // A self-contained PROGRAM named `realconv` must not be force-paired with
        // a differently-cased library def `RealConv.def` reached via the
        // case-insensitive filesystem. A program has no def — leave it unpaired,
        // with no error. (guards B1's narrowing to programs only.)
        let dir = tmpdir("program_case_collision");
        fs::write(dir.join("realconv.mod"), "MODULE realconv;\nBEGIN\nEND realconv.\n").unwrap();
        fs::write(dir.join("RealConv.def"), "DEFINITION MODULE RealConv;\nEND RealConv.\n").unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let g = build_module_graph(&dir.join("realconv.mod"), &sp)
            .expect("program with case-colliding library def should load");
        let mid = g.lookup("realconv").unwrap();
        assert!(
            g.modules[mid.0].def_ast.is_none(),
            "program must stay unpaired with the case-colliding library def"
        );
    }
}
