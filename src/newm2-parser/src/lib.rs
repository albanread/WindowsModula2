//! NewM2 parser — the parsing stage of the compiler pipeline.
//!
//! Recursive descent over the Modula-2 grammar (PIM 4 + ISO 10514-1
//! + ADW dialect). Separate entry points for DEFINITION MODULE,
//! IMPLEMENTATION MODULE, and PROGRAM MODULE all decided by the first
//! token. LOCAL MODULE nests inside procedure declarations.

pub mod ast;
pub mod parser;
pub mod print;
pub mod types_out;

pub use parser::{ParseError, parse_module, parse_module_with_source};
pub use print::format_module;
pub use types_out::{TypesOutResult, format_types_module, format_types_module_with_env};

#[cfg(test)]
mod tests {
    use super::*;
    use newm2_lexer::{Env, LiteralFlavor, preprocess, tokenize};

    fn parse_src(src: &str) -> Result<ast::Module, ParseError> {
        let pp = preprocess(src, &Env::target_default()).expect("preprocess");
        let toks = tokenize(&pp).expect("lex");
        parse_module(&toks)
    }

    #[test]
    fn empty_definition_module() {
        let m = parse_src("DEFINITION MODULE Foo; END Foo.").unwrap();
        assert_eq!(m.name, "Foo");
        assert_eq!(m.kind, ast::ModuleKind::Definition);
        assert!(m.decls.is_empty());
    }

    #[test]
    fn implementation_module_with_body() {
        let m = parse_src("IMPLEMENTATION MODULE Foo; BEGIN END Foo.").unwrap();
        assert_eq!(m.kind, ast::ModuleKind::Implementation);
        assert!(m.body.is_some());
    }

    #[test]
    fn program_module() {
        let m = parse_src("MODULE Hello; BEGIN END Hello.").unwrap();
        assert_eq!(m.kind, ast::ModuleKind::Program);
    }

    #[test]
    fn from_import() {
        let m =
            parse_src("DEFINITION MODULE Foo; FROM Bar IMPORT a, b, c; END Foo.").unwrap();
        match &m.imports[0] {
            ast::Import::From { module, names, .. } => {
                assert_eq!(module, "Bar");
                assert_eq!(names, &["a".to_string(), "b".into(), "c".into()]);
            }
            _ => panic!("expected FROM-import"),
        }
    }

    #[test]
    fn const_decl() {
        let m = parse_src("DEFINITION MODULE Foo; CONST x = 42; END Foo.").unwrap();
        assert_eq!(m.decls.len(), 1);
        match &m.decls[0] {
            ast::Decl::Const(c) => {
                assert_eq!(c.name, "x");
            }
            _ => panic!("expected CONST"),
        }
    }

    #[test]
    fn const_string_literal_preserves_flavor() {
        let m = parse_src("DEFINITION MODULE Foo; CONST s = \"hi\"U; END Foo.").unwrap();
        match &m.decls[0] {
            ast::Decl::Const(c) => match &c.value {
                ast::Expr::String(s, _) => {
                    assert_eq!(s.value, "hi");
                    assert_eq!(s.flavor, LiteralFlavor::Uchar);
                }
                other => panic!("expected string literal, got {other:?}"),
            },
            _ => panic!("expected CONST"),
        }
    }

    #[test]
    fn opaque_type() {
        let m = parse_src("DEFINITION MODULE Foo; TYPE T; END Foo.").unwrap();
        match &m.decls[0] {
            ast::Decl::Type(t) => {
                assert_eq!(t.name, "T");
                assert!(t.def.is_none());
            }
            _ => panic!("expected TYPE"),
        }
    }

    #[test]
    fn record_type() {
        let m = parse_src(
            "DEFINITION MODULE Foo; TYPE T = RECORD a : INTEGER; b : CHAR END; END Foo.",
        )
        .unwrap();
        match &m.decls[0] {
            ast::Decl::Type(t) => match t.def.as_ref().unwrap() {
                ast::TypeExpr::Record(r) => {
                    assert_eq!(r.fields.len(), 2);
                    assert_eq!(r.fields[0].names, vec!["a".to_string()]);
                }
                _ => panic!("expected Record"),
            },
            _ => panic!("expected TYPE"),
        }
    }

    #[test]
    fn enum_type() {
        let m =
            parse_src("DEFINITION MODULE Foo; TYPE Color = (red, green, blue); END Foo.").unwrap();
        match &m.decls[0] {
            ast::Decl::Type(t) => match t.def.as_ref().unwrap() {
                ast::TypeExpr::Enum(v, _, _) => {
                    assert_eq!(v, &vec!["red".to_string(), "green".into(), "blue".into()]);
                }
                _ => panic!("expected Enum"),
            },
            _ => panic!("expected TYPE"),
        }
    }

    #[test]
    fn pointer_type() {
        let m =
            parse_src("DEFINITION MODULE Foo; TYPE P = POINTER TO INTEGER; END Foo.").unwrap();
        match &m.decls[0] {
            ast::Decl::Type(t) => match t.def.as_ref().unwrap() {
                ast::TypeExpr::Pointer(_, _) => {}
                _ => panic!("expected Pointer"),
            },
            _ => panic!("expected TYPE"),
        }
    }

    #[test]
    fn procedure_heading_simple() {
        let m =
            parse_src("DEFINITION MODULE Foo; PROCEDURE Hello(); END Foo.").unwrap();
        match &m.decls[0] {
            ast::Decl::Procedure(p) => {
                assert_eq!(p.name, "Hello");
                assert!(p.params.is_empty());
                assert!(p.return_ty.is_none());
            }
            _ => panic!("expected PROCEDURE"),
        }
    }

    #[test]
    fn procedure_with_var_param() {
        let m = parse_src(
            "DEFINITION MODULE Foo; PROCEDURE P(VAR x : INTEGER) : CHAR; END Foo.",
        )
        .unwrap();
        match &m.decls[0] {
            ast::Decl::Procedure(p) => {
                assert_eq!(p.params.len(), 1);
                assert_eq!(p.params[0].mode, ast::ParamMode::Var);
                assert!(p.return_ty.is_some());
            }
            _ => panic!("expected PROCEDURE"),
        }
    }

    #[test]
    fn procedure_with_adw_attrs() {
        let m = parse_src(
            "DEFINITION MODULE Foo; PROCEDURE P(x : INTEGER) [Pass(DI), Alters(AX)]; END Foo.",
        )
        .unwrap();
        match &m.decls[0] {
            ast::Decl::Procedure(p) => {
                assert_eq!(p.attrs.len(), 2);
                assert_eq!(p.attrs[0].name, "Pass");
                assert_eq!(p.attrs[1].name, "Alters");
            }
            _ => panic!("expected PROCEDURE"),
        }
    }

    #[test]
    fn procedure_preserves_external_linkage_metadata() {
        let m = parse_src(
            "DEFINITION MODULE Foo; PROCEDURE SendMessage[\"_SendMessageW@16\" EXTERNAL FROM \"user32.dll\"](x : INTEGER) : INTEGER; END Foo.",
        )
        .unwrap();
        match &m.decls[0] {
            ast::Decl::Procedure(p) => {
                let linkage = p.external_linkage.as_ref().expect("external linkage");
                assert_eq!(linkage.link_name.value, "_SendMessageW@16");
                assert_eq!(
                    linkage.dll_name.as_ref().map(|name| name.value.as_str()),
                    Some("user32.dll")
                );
                assert_eq!(linkage.link_name.flavor, LiteralFlavor::Default);
                assert!(linkage.is_external);
            }
            _ => panic!("expected PROCEDURE"),
        }
    }

    #[test]
    fn abstract_class_forward() {
        let m = parse_src(
            "DEFINITION MODULE Foo; ABSTRACT CLASS IFoo; FORWARD; END Foo.",
        )
        .unwrap();
        match &m.decls[0] {
            ast::Decl::Class(c) => {
                assert_eq!(c.name, "IFoo");
                assert!(c.is_abstract);
                assert!(c.is_forward);
                assert!(c.inherit.is_none());
            }
            _ => panic!("expected CLASS"),
        }
    }

    #[test]
    fn abstract_class_with_inherit_reveal_methods() {
        let m = parse_src(
            "DEFINITION MODULE Foo;\n\
             ABSTRACT CLASS IFoo;\n\
             INHERIT IUnknown;\n\
             REVEAL DoIt, DoOther;\n\
             ABSTRACT PROCEDURE DoIt(x : INTEGER) : BOOLEAN;\n\
             ABSTRACT PROCEDURE DoOther();\n\
             END IFoo;\n\
             END Foo.",
        )
        .unwrap();
        match &m.decls[0] {
            ast::Decl::Class(c) => {
                assert_eq!(c.name, "IFoo");
                assert!(c.is_abstract);
                assert!(!c.is_forward);
                assert_eq!(
                    c.inherit.as_ref().map(|q| q.segments.join(".")),
                    Some("IUnknown".to_string())
                );
                assert_eq!(c.reveal, vec!["DoIt".to_string(), "DoOther".into()]);
                assert_eq!(c.members.len(), 2);
                if let ast::ClassMember::Method(m) = &c.members[0] {
                    assert_eq!(m.name, "DoIt");
                    assert!(m.is_abstract);
                    assert!(!m.is_override);
                    assert_eq!(m.params.len(), 1);
                    assert!(m.return_ty.is_some());
                } else {
                    panic!("expected abstract method");
                }
            }
            _ => panic!("expected CLASS"),
        }
    }

    #[test]
    fn class_reveal_accepts_readonly_names() {
        let m = parse_src(
            "DEFINITION MODULE Foo; CLASS C; REVEAL Init, READONLY iDispatch; VAR iDispatch : INTEGER; END C; END Foo.",
        )
        .unwrap();
        match &m.decls[0] {
            ast::Decl::Class(c) => {
                assert_eq!(c.reveal, vec!["Init".to_string(), "iDispatch".to_string()]);
            }
            _ => panic!("expected CLASS"),
        }
    }

    #[test]
    fn types_out_emits_only_type_declarations() {
        let m = parse_src(
            "DEFINITION MODULE Foo; IMPORT Bar; CONST x = 1; TYPE T = POINTER TO Bar.Baz; PROCEDURE P(); END Foo.",
        )
        .unwrap();
        let out = format_types_module(&m);
        assert!(out.text.contains("DEFINITION MODULE Foo;"));
        assert!(out.text.contains("IMPORT Bar;"));
        assert!(out.text.contains("CONST\n    x = 1;"));
        assert!(out.text.contains("TYPE\n    T = POINTER TO Bar.Baz;"));
        assert!(out.text.contains("PROCEDURE P();"));
        assert!(out.text.contains("(* types-out summary: 1 type emitted; 1 const emitted; 1 procedure emitted *)"));
        assert!(out.text.contains("END Foo."));
        assert!(!out.warnings.iter().any(|warning| warning.contains("skipped CONST x")));
        assert!(!out.warnings.iter().any(|warning| warning.contains("skipped PROCEDURE P")));
    }

    #[test]
    fn types_out_preserves_module_pragmas() {
        let m = parse_src(
            "<*/NOPACK*> DEFINITION MODULE Foo; TYPE T = RECORD a : INTEGER; END; END Foo.",
        )
        .unwrap();
        let out = format_types_module(&m);
        assert!(out.text.contains("<*/NOPACK*>"));
        assert!(out.text.contains("a : INTEGER;"));
    }

    #[test]
    fn types_out_with_env_selects_non_mac_branch() {
        let m = parse_src(
            "DEFINITION MODULE Foo; TYPE <*IF MAC THEN*> T = ARRAY [0..127] OF CHAR; <*ELSE*> T = ARRAY [0..0] OF CHAR; <*END*> END Foo.",
        )
        .unwrap();
        let out = format_types_module_with_env(&m, &Env::target_default());
        assert!(!out.text.contains("<*IF MAC THEN*>"));
        assert!(out.text.contains("T = ARRAY [0..0] OF CHAR;"));
        assert!(!out.text.contains("T = ARRAY [0..127] OF CHAR;"));
    }

    #[test]
    fn types_out_summary_mentions_empty_type_only_surface() {
        let m = parse_src("DEFINITION MODULE Foo; TYPE T; PROCEDURE P(); END Foo.").unwrap();
        let out = format_types_module(&m);
        assert!(out.text.contains("(* types-out summary: 1 type emitted; 1 procedure emitted *)"));
    }

    #[test]
    fn types_out_emits_const_only_surface() {
        let m = parse_src("DEFINITION MODULE Foo; CONST Max = 42; END Foo.").unwrap();
        let out = format_types_module(&m);
        assert!(out.text.contains("CONST\n    Max = 42;"));
        assert!(out.text.contains("(* types-out summary: 0 types emitted; 1 const emitted *)"));
        assert!(!out.warnings.iter().any(|warning| warning.contains("skipped CONST Max")));
    }

    #[test]
    fn types_out_emits_procedure_linkage_heading() {
        let m = parse_src(
            "DEFINITION MODULE Foo; PROCEDURE SendMessage[\"_SendMessageW@16\" EXTERNAL FROM \"user32.dll\"](VAR x : INTEGER) : INTEGER [Pass(DI)]; END Foo.",
        )
        .unwrap();
        let out = format_types_module(&m);
        assert!(out.text.contains(
            "PROCEDURE SendMessage[\"_SendMessageW@16\" EXTERNAL FROM \"user32.dll\"](VAR x : INTEGER) : INTEGER [Pass(DI)];"
        ));
        assert!(out.text.contains("(* types-out summary: 0 types emitted; 1 procedure emitted *)"));
    }

    #[test]
    fn class_in_impl_module_with_concrete_method_body() {
        let m = parse_src(
            "IMPLEMENTATION MODULE Foo;\n\
             CLASS Bar;\n\
             PROCEDURE Hello() : INTEGER;\n\
             BEGIN\n\
                 RETURN 42\n\
             END Hello;\n\
             END Bar;\n\
             BEGIN END Foo.",
        )
        .unwrap();
        match &m.decls[0] {
            ast::Decl::Class(c) => {
                assert!(!c.is_abstract);
                if let ast::ClassMember::Method(meth) = &c.members[0] {
                    assert_eq!(meth.name, "Hello");
                    assert!(!meth.is_abstract);
                    assert!(meth.body.is_some());
                } else {
                    panic!("expected method");
                }
            }
            _ => panic!("expected CLASS"),
        }
    }

    #[test]
    fn direct_field_designator_keeps_single_name_base() {
        let m = parse_src(
            "MODULE Foo;\n\
             CLASS T;\n\
               VAR b: INTEGER;\n\
             END T;\n\
             VAR x: T;\n\
             BEGIN\n\
               x.b := 1\n\
             END Foo.",
        )
        .unwrap();

        let stmt = &m.body.as_ref().unwrap().stmts[0];
        let ast::Stmt::Assign { target, .. } = stmt else {
            panic!("expected assignment")
        };
        assert_eq!(target.base.segments, vec!["x".to_string()]);
        assert_eq!(target.selectors.len(), 1);
        match &target.selectors[0] {
            ast::Selector::Field(name, _) => assert_eq!(name, "b"),
            other => panic!("expected field selector, got {other:?}"),
        }
    }

    #[test]
    fn module_qualified_call_is_parsed_as_designator_selector_chain() {
        let m = parse_src(
            "MODULE Hello;\n\
             IMPORT STextIO;\n\
             BEGIN\n\
               STextIO.WriteLn\n\
             END Hello.",
        )
        .unwrap();

        let stmt = &m.body.as_ref().unwrap().stmts[0];
        let ast::Stmt::Call(ast::Expr::Designator(designator), _) = stmt else {
            panic!("expected bare designator call")
        };
        assert_eq!(designator.base.segments, vec!["STextIO".to_string()]);
        assert_eq!(designator.selectors.len(), 1);
        match &designator.selectors[0] {
            ast::Selector::Field(name, _) => assert_eq!(name, "WriteLn"),
            other => panic!("expected field selector, got {other:?}"),
        }
    }
}
