//! AST for Modula-2 (PIM 4 + ISO 10514-1 + ADW dialect).
//!
//! The shape favours a flat `enum`-per-category and `Box` indirection where
//! cycles would otherwise appear. Spans are attached to most nodes for
//! diagnostics; in many trivial-leaf cases the parent's span is used.
//!
//! ADW-specific constructs are first-class:
//!   - `<* … *>` pragmas attached to modules, declarations, and parameters.
//!   - Square-bracket procedure attribute lists (`[Pass(DI,CX), …]`).
//!
//! ISO 10514-1 constructs (`EXCEPT`, `FINALLY`, `RAISE`, `RETRY`) are
//! parsed; sema responsibility is deferred to the semantic-analysis stage.

use newm2_lexer::{CharLiteral, Span, StringLiteral};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Module {
    pub kind: ModuleKind,
    pub name: String,
    pub priority: Option<Expr>,
    pub pragmas: Vec<Pragma>,
    pub imports: Vec<Import>,
    pub decls: Vec<Decl>,
    pub body: Option<Block>,
    pub span: Span,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ModuleKind {
    Definition,
    Implementation,
    Program,
    /// `LOCAL MODULE` nested inside a procedure body.
    Local,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Import {
    /// `FROM Foo IMPORT a, b, c;`
    From { module: String, names: Vec<String>, span: Span },
    /// `IMPORT Foo, Bar;` or `IMPORT alias := Mod;` (ISO).
    Plain { names: Vec<ImportName>, span: Span },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportName {
    pub name: String,
    pub alias: Option<String>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Decl {
    Const(ConstDecl),
    Type(TypeDecl),
    Var(VarDecl),
    Procedure(ProcDecl),
    Pragma(Pragma),
    /// Nested `LOCAL MODULE m; … END m;` inside a procedure body or
    /// implementation module's declaration section.
    LocalModule(Box<Module>),
    /// `EXPORT QUALIFIED a, b, c;` — PIM-2 style explicit export.
    Export { qualified: bool, names: Vec<String>, span: Span },
    /// `[ABSTRACT] CLASS Name; ...` — ISO 10514-2 OO extension as
    /// implemented by ADW for the Win32 COM bindings.
    Class(ClassDecl),
}

/// `[ABSTRACT] CLASS Name; [FORWARD;] [INHERIT Base;] [REVEAL m1, m2;]
/// { ... members ... } END Name;`
/// Whether a `ClassDecl` was introduced by `CLASS` or `INTERFACE`. An
/// `INTERFACE` is a COM-style vtable-only class: fieldless, all-abstract, its
/// slot ordinals owned by its declaration + `INHERIT` chain (see
/// docs/design/com-interfaces.md). It reuses the whole `ClassDecl`/vtable engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ClassKind {
    Class,
    Interface,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClassDecl {
    pub name: String,
    pub kind: ClassKind,
    pub is_abstract: bool,
    /// `ABSTRACT CLASS Name; FORWARD;` — just an opaque declaration,
    /// no body, INHERIT/REVEAL/members are not present.
    pub is_forward: bool,
    /// The COM IID, from an `["xxxxxxxx-...."]` annotation after the name.
    pub iid: Option<String>,
    /// `CLASS C IMPLEMENTS I1, I2;` — the interfaces a coclass provides
    /// (producer side; empty for a plain class or an interface).
    pub implements: Vec<QualName>,
    /// `INHERIT Base;` — single inheritance. None ⇒ no explicit base.
    pub inherit: Option<QualName>,
    /// `REVEAL name1, name2;` — names from the base class to expose
    /// (the ADW dialect uses this to mark which inherited methods are
    /// callable from outside the class's own module).
    pub reveal: Vec<String>,
    pub members: Vec<ClassMember>,
    pub exported: bool,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ClassMember {
    /// Instance variable declaration inside a class body.
    Field(VarDecl),
    /// Either an abstract method (no body), a concrete method
    /// (potentially with body when in an IMPL module), or an
    /// `OVERRIDE PROCEDURE` of an inherited method.
    Method(MethodDecl),
    Pragma(Pragma),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MethodDecl {
    pub name: String,
    pub is_abstract: bool,
    pub is_override: bool,
    pub params: Vec<Param>,
    pub return_ty: Option<TypeExpr>,
    pub attrs: Vec<ProcAttr>,
    pub body: Option<ProcBody>,
    pub pragmas: Vec<Pragma>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConstDecl {
    pub name: String,
    pub value: Expr,
    pub exported: bool,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypeDecl {
    pub name: String,
    /// `None` indicates an opaque type (DEF-only declaration like
    /// `TYPE T;` with no `=` body).
    pub def: Option<TypeExpr>,
    pub exported: bool,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VarDecl {
    pub names: Vec<String>,
    pub ty: TypeExpr,
    /// PIM allows `VAR x [addr] : T;` to bind a variable to a fixed
    /// address. ADW supports this.
    pub address: Option<Expr>,
    pub pragmas: Vec<Pragma>,
    pub exported: bool,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcDecl {
    pub name: String,
    pub external_linkage: Option<ProcExternalLinkage>,
    pub params: Vec<Param>,
    pub return_ty: Option<TypeExpr>,
    pub attrs: Vec<ProcAttr>,
    pub body: Option<ProcBody>,
    /// Raw Intel assembly body, set when `PROCEDURE name; ASM … END name;`
    /// syntax is used.  Mutually exclusive with `body`.
    pub asm_body: Option<String>,
    pub is_forward: bool,
    pub pragmas: Vec<Pragma>,
    pub exported: bool,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcExternalLinkage {
    pub link_name: StringLiteral,
    pub dll_name: Option<StringLiteral>,
    pub is_external: bool,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcBody {
    pub decls: Vec<Decl>,
    pub body: Block,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Param {
    pub mode: ParamMode,
    pub names: Vec<String>,
    pub ty: TypeExpr,
    pub pragmas: Vec<Pragma>,
    pub span: Span,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ParamMode {
    Value,
    Var,
    /// `CONST` (ADW): a read-only parameter. It accepts any expression (like a
    /// value parameter) but may not be assigned to in the body.
    Const,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcAttr {
    pub name: String,
    pub args: Vec<String>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum TypeExpr {
    /// `INTEGER`, `MyType`, `M.T`.
    Named(QualName),
    /// `[a..b]`.
    Subrange(Box<Expr>, Box<Expr>, Span),
    /// `(red, green, blue)`, or with explicit ordinal values
    /// `(ok = 0, warn = 5, …)`. The second vec is parallel to the first:
    /// `values[i]` is the explicit value expression for `names[i]`, or
    /// `None` when the member takes the next sequential ordinal.
    Enum(Vec<String>, Vec<Option<Expr>>, Span),
    /// `ARRAY indexT { , indexT } OF baseT`. Each index type is itself
    /// a `TypeExpr` (typically a subrange or named ordinal type).
    Array(Vec<TypeExpr>, Box<TypeExpr>, Span),
    /// `ARRAY OF baseT` (open / dynamic).
    OpenArray(Box<TypeExpr>, Span),
    /// `RECORD … END`.
    Record(RecordType),
    /// `POINTER TO T`.
    Pointer(Box<TypeExpr>, Span),
    /// `PROCEDURE (paramT, …) [: returnT]`.
    Proc(ProcType),
    /// `SET OF T` or `PACKEDSET OF T`.
    Set { packed: bool, element: Box<TypeExpr>, span: Span },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordType {
    pub fields: Vec<RecordField>,
    pub variant: Option<VariantPart>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecordField {
    pub names: Vec<String>,
    pub ty: TypeExpr,
    pub pragmas: Vec<Pragma>,
    pub exported: bool,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VariantPart {
    /// `CASE tag : T OF` — optional tag name (anonymous variant
    /// allowed by some dialects).
    pub tag_name: Option<String>,
    pub tag_type: Option<QualName>,
    pub arms: Vec<VariantArm>,
    pub else_arm: Option<Vec<RecordField>>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VariantArm {
    pub labels: Vec<CaseLabel>,
    pub fields: Vec<RecordField>,
    pub variant: Option<Box<VariantPart>>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcType {
    pub params: Vec<ProcTypeParam>,
    pub return_ty: Option<Box<TypeExpr>>,
    pub attrs: Vec<ProcAttr>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcTypeParam {
    pub mode: ParamMode,
    pub ty: TypeExpr,
    pub pragmas: Vec<Pragma>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QualName {
    pub segments: Vec<String>,
    pub span: Span,
}

impl QualName {
    pub fn simple(name: String, span: Span) -> Self {
        Self { segments: vec![name], span }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Expr {
    Integer(u64, Span),
    Real(f64, Span),
    Char(CharLiteral, Span),
    String(StringLiteral, Span),
    /// `NIL` — treated as an expression keyword.
    Nil(Span),
    /// `TRUE` / `FALSE` — predefined identifiers (sema decides).
    Designator(Designator),
    /// `M.f(x, y)` or `arr[i]` etc. lifted to expression position via
    /// the designator wrapper.
    Call(Box<Expr>, Vec<Expr>, Span),
    Binary(BinaryOp, Box<Expr>, Box<Expr>, Span),
    Unary(UnaryOp, Box<Expr>, Span),
    /// `{ … }` set constructor.
    Set { type_name: Option<QualName>, elements: Vec<SetElem>, span: Span },
}

/// A *designator* — a name optionally followed by `.f`, `[i,…]`, or `^`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Designator {
    pub base: QualName,
    pub selectors: Vec<Selector>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Selector {
    Field(String, Span),
    Index(Vec<Expr>, Span),
    Deref(Span),
    /// ISO type guard: `expr(T)`. Disambiguated at sema time from a
    /// function call when the operand is a type name.
    TypeGuard(QualName, Span),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BinaryOp {
    Add,
    Sub,
    Mul,
    /// Integer or set `/`.
    Div,
    DivKw,
    Mod,
    Rem,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
    In,
    // ADW bitwise operators (integer bitwise operations)
    Bor,
    Band,
    Bxor,
    // ADW shift operators
    Shl,
    Shr,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum UnaryOp {
    Pos,
    Neg,
    Not,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SetElem {
    Single(Expr),
    Range(Expr, Expr),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Block {
    pub stmts: Vec<Stmt>,
    /// `EXCEPT` arms (ISO).
    pub except: Vec<ExceptArm>,
    /// `FINALLY` body (ISO).
    pub finally: Option<Vec<Stmt>>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExceptArm {
    pub names: Vec<QualName>,
    pub body: Vec<Stmt>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Stmt {
    Empty(Span),
    Assign { target: Designator, value: Expr, span: Span },
    Call(Expr, Span),
    If {
        arms: Vec<(Expr, Vec<Stmt>)>,
        else_arm: Option<Vec<Stmt>>,
        span: Span,
    },
    Case {
        scrutinee: Expr,
        arms: Vec<CaseArm>,
        else_arm: Option<Vec<Stmt>>,
        span: Span,
    },
    /// OO `GUARD selector AS [x:]T DO … {| …} [ELSE …] END` — discriminate on the
    /// selector's dynamic class type, binding a read-only narrowed view per arm.
    Guard {
        selector: Expr,
        arms: Vec<GuardArm>,
        else_arm: Option<Vec<Stmt>>,
        span: Span,
    },
    While(Expr, Vec<Stmt>, Span),
    Repeat(Vec<Stmt>, Expr, Span),
    For {
        var: String,
        start: Expr,
        end: Expr,
        step: Option<Expr>,
        body: Vec<Stmt>,
        span: Span,
    },
    Loop(Vec<Stmt>, Span),
    With(Designator, Vec<Stmt>, Span),
    Exit(Span),
    Return(Option<Expr>, Span),
    Raise(Option<Expr>, Span),
    Retry(Span),
    /// Anonymous block with EXCEPT/FINALLY (ISO).
    Block(Block),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaseArm {
    pub labels: Vec<CaseLabel>,
    pub body: Vec<Stmt>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum CaseLabel {
    Single(Expr),
    Range(Expr, Expr),
}

/// One arm of a `GUARD` statement: `[denoter ":"] guardedType DO body`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GuardArm {
    /// Optional read-only narrowed binding `x : T DO …` (`None` = no binding).
    pub denoter: Option<String>,
    pub denoter_span: Span,
    /// The guarded class/interface type name.
    pub guarded_type: QualName,
    pub body: Vec<Stmt>,
    pub span: Span,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pragma {
    pub body: String,
    pub span: Span,
}
