//! Small helpers for constructing `newm2_parser::ast` nodes. The generator
//! never hand-formats `.def` text — it builds an `ast::Module` and renders it
//! through `newm2_parser::format_types_module`, so the output is structurally
//! guaranteed to match what the parser accepts.

use newm2_lexer::{LiteralFlavor, SourcePosition, Span, StringLiteral};
use newm2_parser::ast::*;

/// A zero-width placeholder span. Generated nodes have no source location.
pub fn sp() -> Span {
    Span { start: SourcePosition::START, end: SourcePosition::START }
}

pub fn named(name: &str) -> TypeExpr {
    TypeExpr::Named(QualName { segments: vec![name.to_string()], span: sp() })
}

pub fn pointer(base: TypeExpr) -> TypeExpr {
    TypeExpr::Pointer(Box::new(base), sp())
}

pub fn array(index: TypeExpr, base: TypeExpr) -> TypeExpr {
    TypeExpr::Array(vec![index], Box::new(base), sp())
}

pub fn subrange(lo: Expr, hi: Expr) -> TypeExpr {
    TypeExpr::Subrange(Box::new(lo), Box::new(hi), sp())
}

pub fn int_expr(v: u64) -> Expr {
    Expr::Integer(v, sp())
}

pub fn neg_int_expr(abs: u64) -> Expr {
    Expr::Unary(UnaryOp::Neg, Box::new(Expr::Integer(abs, sp())), sp())
}

pub fn real_expr(v: f64) -> Expr {
    Expr::Real(v, sp())
}

pub fn string_expr(s: &str) -> Expr {
    Expr::String(StringLiteral { value: s.to_string(), flavor: LiteralFlavor::Default }, sp())
}

pub fn const_decl(name: &str, value: Expr) -> Decl {
    Decl::Const(ConstDecl { name: name.to_string(), value, exported: false, span: sp() })
}

pub fn type_decl(name: &str, def: TypeExpr) -> Decl {
    Decl::Type(TypeDecl { name: name.to_string(), def: Some(def), exported: false, span: sp() })
}

pub fn opaque_type_decl(name: &str) -> Decl {
    Decl::Type(TypeDecl { name: name.to_string(), def: None, exported: false, span: sp() })
}

pub fn record(fields: Vec<RecordField>) -> TypeExpr {
    TypeExpr::Record(RecordType { fields, variant: None, span: sp() })
}

pub fn record_field(name: &str, ty: TypeExpr) -> RecordField {
    RecordField { names: vec![name.to_string()], ty, pragmas: vec![], exported: false, span: sp() }
}

pub fn import_from(module: &str, names: Vec<String>) -> Import {
    Import::From { module: module.to_string(), names, span: sp() }
}

pub fn import_plain(modules: Vec<String>) -> Import {
    Import::Plain {
        names: modules
            .into_iter()
            .map(|m| ImportName { name: m, alias: None, span: sp() })
            .collect(),
        span: sp(),
    }
}

pub fn string_lit(s: &str) -> StringLiteral {
    StringLiteral { value: s.to_string(), flavor: LiteralFlavor::Default }
}

/// `["<link>" EXTERNAL FROM "<dll>"]`.
pub fn external_linkage(link: &str, dll: &str) -> ProcExternalLinkage {
    ProcExternalLinkage {
        link_name: string_lit(link),
        dll_name: Some(string_lit(dll)),
        is_external: true,
        span: sp(),
    }
}

pub fn value_param(name: &str, ty: TypeExpr) -> Param {
    Param { mode: ParamMode::Value, names: vec![name.to_string()], ty, pragmas: vec![], span: sp() }
}

pub fn proc_decl(
    name: &str,
    linkage: Option<ProcExternalLinkage>,
    params: Vec<Param>,
    return_ty: Option<TypeExpr>,
) -> Decl {
    Decl::Procedure(ProcDecl {
        name: name.to_string(),
        external_linkage: linkage,
        params,
        return_ty,
        attrs: vec![],
        body: None,
        asm_body: None,
        is_forward: false,
        pragmas: vec![],
        exported: false,
        span: sp(),
    })
}

/// A bare `QualName` from path segments (e.g. `["System_Com", "IUnknown"]`).
pub fn qual_name(segments: Vec<String>) -> QualName {
    QualName { segments, span: sp() }
}

/// One abstract method of an INTERFACE, carrying its absolute vtable ordinal as
/// a `<* @N *>` pragma — the slot the M2 compiler will machine-check.
pub fn interface_method(
    name: &str,
    params: Vec<Param>,
    return_ty: Option<TypeExpr>,
    ordinal: usize,
) -> ClassMember {
    ClassMember::Method(MethodDecl {
        name: name.to_string(),
        is_abstract: true,
        is_override: false,
        params,
        return_ty,
        attrs: vec![],
        body: None,
        pragmas: vec![Pragma { body: format!("@{ordinal}"), span: sp() }],
        span: sp(),
    })
}

/// A COM `INTERFACE` declaration: a vtable-only abstract class with an optional
/// IID, an optional `INHERIT` base, and an ordered list of abstract methods.
pub fn interface_decl(
    name: &str,
    iid: Option<&str>,
    inherit: Option<QualName>,
    methods: Vec<ClassMember>,
) -> Decl {
    Decl::Class(ClassDecl {
        name: name.to_string(),
        kind: ClassKind::Interface,
        is_abstract: true,
        is_forward: false,
        iid: iid.map(|s| s.to_string()),
        implements: vec![],
        inherit,
        reveal: vec![],
        members: methods,
        // Classes/interfaces (unlike types/consts) need the explicit `*` export
        // marker to be visible to importers in this ADW dialect.
        exported: true,
        span: sp(),
    })
}

pub fn module(name: &str, imports: Vec<Import>, decls: Vec<Decl>) -> Module {
    Module {
        kind: ModuleKind::Definition,
        name: name.to_string(),
        priority: None,
        pragmas: vec![],
        imports,
        decls,
        body: None,
        span: sp(),
    }
}
