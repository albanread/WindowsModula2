//! Generate NewM2 Win32 `.def` modules (types + constants, and later procedure
//! bindings) from the windows_api SQLite database. The generator builds
//! `newm2_parser::ast::Module` values and renders them through the existing
//! `format_types_module` emitter, so output is structurally parser-valid.

pub mod build;
pub mod db;
pub mod emit;
pub mod policy;

pub use emit::{
    GenResult, InterfaceIndex, build_cross_index, generate_namespace,
    generate_namespace_with_ifaces, generate_win32_base, module_name_for,
};

/// Verify that generated `.def` text actually parses (preprocess + tokenize +
/// parse). Used by tests and the `--check` CLI flag.
pub fn parses(text: &str) -> Result<(), String> {
    use newm2_lexer::{Env, preprocess, tokenize};
    let pre = preprocess(text, &Env::target_default()).map_err(|e| e.to_string())?;
    let toks = tokenize(&pre).map_err(|e| e.to_string())?;
    newm2_parser::parse_module(&toks).map(|_| ()).map_err(|e| format!("{e:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn win32_base_parses() {
        let text = generate_win32_base();
        assert!(parses(&text).is_ok(), "WIN32 base failed to parse:\n{text}");
    }

    #[test]
    fn namespace_generation_parses() {
        // Hermetic: a minimal in-memory DB shaped like schema v6.
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE types (type_id INTEGER PRIMARY KEY, namespace_name TEXT, type_name TEXT, qualified_name TEXT, kind TEXT, abi_kind TEXT, size_bits INTEGER);
             CREATE TABLE constants (constant_name TEXT, namespace_name TEXT, value_kind TEXT, value_i64 INTEGER, value_u64 INTEGER, value_f64 REAL, value_text TEXT);
             CREATE TABLE enum_members (enum_type_id INTEGER, member_name TEXT, ordinal INTEGER, value_i64 INTEGER, value_u64 INTEGER, underlying_type TEXT, signedness TEXT, is_flags INTEGER);
             CREATE TABLE struct_fields (struct_type_id INTEGER, ordinal INTEGER, field_name TEXT, type_name TEXT, byte_offset INTEGER);
             CREATE TABLE functions (function_id INTEGER PRIMARY KEY, namespace_name TEXT, function_name TEXT, import_name TEXT, dll_name TEXT, return_type_id INTEGER);
             CREATE TABLE function_params (function_id INTEGER, ordinal INTEGER, param_name TEXT, type_id INTEGER);
             INSERT INTO types VALUES (1,'Test.NS','COORD','Test.NS.COORD','struct','sequential',128),(2,'Test.NS','MODE','Test.NS.MODE','enum',NULL,NULL),(3,'Test.NS','u32','u32','primitive',NULL,NULL),(4,'Test.NS','i32','i32','primitive',NULL,NULL);
             INSERT INTO struct_fields VALUES (1,0,'X','i16',0),(1,1,'Y','i16',2),(1,2,'h','Windows.Win32.Foundation.HANDLE',8);
             INSERT INTO enum_members VALUES (2,'MODE_A',0,0,0,'u32','unsigned',1),(2,'MODE_B',1,2,2,'u32','unsigned',1);
             INSERT INTO constants VALUES ('MAX_X','Test.NS','uint',NULL,255,NULL,NULL),('NEG','Test.NS','int',-1,NULL,NULL,NULL),('NAME','Test.NS','string',NULL,NULL,NULL,'hi');
             INSERT INTO functions VALUES (10,'Test.NS','DoThing','DoThing','KERNEL32.dll',4);
             INSERT INTO function_params VALUES (10,0,'count',3),(10,1,'type',3);",
        )
        .unwrap();

        let index = build_cross_index(&conn, &["Test.NS".to_string()]).unwrap();
        let g = generate_namespace(&conn, "Test.NS", &index).unwrap();
        assert!(parses(&g.text).is_ok(), "generated module did not parse:\n{}", g.text);
        // real record body + resolved field types
        assert!(g.text.contains("COORD = RECORD"), "missing record:\n{}", g.text);
        assert!(g.text.contains("X : INTEGER16"), "missing field:\n{}", g.text);
        assert!(g.text.contains("h : HANDLE"), "missing handle field:\n{}", g.text);
        assert!(g.text.contains("FROM WIN32 IMPORT HANDLE"), "missing import:\n{}", g.text);
        // constants + enum members + signed
        assert!(g.text.contains("MAX_X = 255"), "missing uint const:\n{}", g.text);
        assert!(g.text.contains("NEG = (-1)"), "missing signed const:\n{}", g.text);
        assert!(g.text.contains("NAME = \"hi\""), "missing string const:\n{}", g.text);
        assert!(g.text.contains("MODE_A = 0") && g.text.contains("MODE_B = 2"), "missing enum consts:\n{}", g.text);
        // procedure binding: EXTERNAL FROM, resolved params/return, reserved-word param escaped
        assert!(
            g.text.contains("PROCEDURE DoThing[\"DoThing\" EXTERNAL FROM \"KERNEL32.dll\"]"),
            "missing proc linkage:\n{}", g.text
        );
        assert!(g.text.contains("count : DWORD"), "missing param:\n{}", g.text);
        assert!(g.text.contains("type_ : DWORD"), "reserved-word param not escaped:\n{}", g.text);
        assert!(g.text.contains(") : INTEGER32"), "missing return type:\n{}", g.text);
    }
}
