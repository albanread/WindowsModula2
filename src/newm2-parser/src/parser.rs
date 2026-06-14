//! Recursive-descent parser for Modula-2 (PIM 4 + ISO 10514-1 + ADW).
//!
//! Entry points:
//! - [`parse_module`] takes a slice of tokens and returns a top-level
//!   `Module` AST node. Decides between DEFINITION / IMPLEMENTATION /
//!   PROGRAM from the first keyword.
//!
//! Error model: the first parse error is fatal. Position information
//! carries through to diagnostics.

use crate::ast::*;
use newm2_lexer::{Keyword, Span, StringLiteral, Token, TokenKind};

#[derive(Debug, Clone)]
pub struct ParseError {
    pub message: String,
    pub span: Span,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "parse error at line {}, column {}: {}",
            self.span.start.line, self.span.start.column, self.message
        )
    }
}

impl std::error::Error for ParseError {}

pub fn parse_module(tokens: &[Token]) -> Result<Module, ParseError> {
    parse_module_with_source(tokens, "")
}

pub fn parse_module_with_source(tokens: &[Token], source: &str) -> Result<Module, ParseError> {
    let mut p = Parser::new(tokens, source);
    let m = p.parse_module()?;
    p.expect_eof()?;
    Ok(m)
}

/// Reconstruct a token's source spelling from its kind alone — used only when
/// the parser was given no source (the `parse_module` convenience entry), where
/// an exact source slice is unavailable.
fn token_spelling(kind: &TokenKind) -> String {
    use TokenKind::*;
    match kind {
        Ident(s) => s.clone(),
        Keyword(k) => k.as_str().to_string(),
        Integer(n) => n.to_string(),
        Real(r) => r.to_string(),
        Char(c) => format!("'{}'", c.value),
        String(s) => format!("{:?}", s.value),
        Pragma(s) => format!("<*{s}*>"),
        Plus => "+".into(), Minus => "-".into(), Star => "*".into(), Slash => "/".into(),
        Amp => "&".into(), Tilde => "~".into(), Equal => "=".into(), Hash => "#".into(),
        Less => "<".into(), LessEq => "<=".into(), Greater => ">".into(), GreaterEq => ">=".into(),
        NotEqual => "<>".into(), Assign => ":=".into(), Dot => ".".into(), DotDot => "..".into(),
        Comma => ",".into(), Semicolon => ";".into(), Colon => ":".into(),
        LParen => "(".into(), RParen => ")".into(), LBracket => "[".into(), RBracket => "]".into(),
        LBrace => "{".into(), RBrace => "}".into(), Pipe => "|".into(), Caret => "^".into(),
        At => "@".into(), Eof => std::string::String::new(),
    }
}

struct Parser<'a> {
    toks: &'a [Token],
    source: &'a str,
    pos: usize,
}

impl<'a> Parser<'a> {
    fn new(toks: &'a [Token], source: &'a str) -> Self {
        Self { toks, source, pos: 0 }
    }

    fn peek(&self) -> &Token {
        &self.toks[self.pos]
    }

    fn peek_kind(&self) -> &TokenKind {
        &self.toks[self.pos].kind
    }

    /// The raw source spelling of the current token. Tokens no longer carry
    /// their text; we slice it from the source where available (exact), and
    /// fall back to reconstructing it from the kind when the parser was given
    /// no source (the `parse_module` convenience entry passes `""`).
    fn peek_text(&self) -> std::borrow::Cow<'a, str> {
        let t = &self.toks[self.pos];
        let (s, e) = (t.span.start.offset, t.span.end.offset);
        let src = self.source;
        if s <= e && e <= src.len() {
            std::borrow::Cow::Borrowed(&src[s..e])
        } else {
            std::borrow::Cow::Owned(token_spelling(&t.kind))
        }
    }

    fn peek_at(&self, offset: usize) -> Option<&Token> {
        self.toks.get(self.pos + offset)
    }

    fn bump(&mut self) -> &Token {
        let t = &self.toks[self.pos];
        if !matches!(t.kind, TokenKind::Eof) {
            self.pos += 1;
        }
        t
    }

    fn err<T>(&self, message: impl Into<String>) -> Result<T, ParseError> {
        Err(ParseError { message: message.into(), span: self.peek().span })
    }

    fn err_at<T>(&self, span: Span, message: impl Into<String>) -> Result<T, ParseError> {
        Err(ParseError { message: message.into(), span })
    }

    fn expect_eof(&self) -> Result<(), ParseError> {
        match self.peek_kind() {
            TokenKind::Eof => Ok(()),
            _ => self.err(format!("expected end of input, found {:?}", self.peek_kind())),
        }
    }

    fn at_kw(&self, kw: Keyword) -> bool {
        matches!(self.peek_kind(), TokenKind::Keyword(k) if *k == kw)
    }

    fn at_kind(&self, kind: &TokenKind) -> bool {
        std::mem::discriminant(self.peek_kind()) == std::mem::discriminant(kind)
    }

    /// `...` — the variadic-parameter marker — lexes as `DotDot` then `Dot`.
    fn at_ellipsis(&self) -> bool {
        matches!(self.peek_kind(), TokenKind::DotDot)
            && matches!(self.toks.get(self.pos + 1).map(|t| &t.kind), Some(TokenKind::Dot))
    }

    fn eat_ellipsis(&mut self) {
        self.bump(); // DotDot
        self.bump(); // Dot
    }

    fn eat_kw(&mut self, kw: Keyword) -> bool {
        if self.at_kw(kw) {
            self.bump();
            true
        } else {
            false
        }
    }

    fn expect_kw(&mut self, kw: Keyword) -> Result<Span, ParseError> {
        if let TokenKind::Keyword(k) = self.peek_kind()
            && *k == kw
        {
            let span = self.peek().span;
            self.bump();
            return Ok(span);
        }
        self.err(format!("expected keyword {} ({:?})", kw.as_str(), kw))
    }

    fn expect_ident(&mut self) -> Result<(String, Span), ParseError> {
        match self.peek_kind() {
            TokenKind::Ident(name) => {
                let n = name.clone();
                let s = self.peek().span;
                self.bump();
                Ok((n, s))
            }
            _ => self.err(format!("expected identifier, found {:?}", self.peek_kind())),
        }
    }

    fn expect_string_literal(&mut self) -> Result<(StringLiteral, Span), ParseError> {
        match self.peek_kind() {
            TokenKind::String(lit) => {
                let lit = lit.clone();
                let span = self.peek().span;
                self.bump();
                Ok((lit, span))
            }
            _ => self.err(format!("expected string literal, found {:?}", self.peek_kind())),
        }
    }

    fn expect_kind(&mut self, kind: TokenKind, what: &str) -> Result<Span, ParseError> {
        if std::mem::discriminant(self.peek_kind())
            == std::mem::discriminant(&kind)
        {
            let s = self.peek().span;
            self.bump();
            return Ok(s);
        }
        self.err(format!("expected {what}, found {:?}", self.peek_kind()))
    }

    fn eat_kind(&mut self, kind: &TokenKind) -> bool {
        if self.at_kind(kind) {
            self.bump();
            true
        } else {
            false
        }
    }

    /// Consume any leading pragmas, returning them in declaration order.
    fn collect_pragmas(&mut self) -> Vec<Pragma> {
        let mut out = Vec::new();
        while let TokenKind::Pragma(body) = self.peek_kind() {
            let body = body.clone();
            let span = self.peek().span;
            self.bump();
            out.push(Pragma { body, span });
        }
        out
    }

    // ----- Module ------------------------------------------------------

    fn parse_module(&mut self) -> Result<Module, ParseError> {
        let start_pragmas = self.collect_pragmas();
        // ADW dialect: `UNSAFEGUARDED` qualifier may prefix the module
        // header (e.g. `UNSAFEGUARDED DEFINITION MODULE Foo;`). It
        // documents that the module bypasses ISO guard checks. We
        // accept and ignore it for now.
        self.eat_soft_kw("UNSAFEGUARDED");
        let start_tok = self.peek().clone();
        let kind = match start_tok.kind {
            TokenKind::Keyword(Keyword::Definition) => {
                self.bump();
                self.expect_kw(Keyword::Module)?;
                ModuleKind::Definition
            }
            TokenKind::Keyword(Keyword::Implementation) => {
                self.bump();
                self.expect_kw(Keyword::Module)?;
                ModuleKind::Implementation
            }
            TokenKind::Keyword(Keyword::Module) => {
                self.bump();
                ModuleKind::Program
            }
            _ => {
                return self.err(format!(
                    "expected DEFINITION/IMPLEMENTATION/MODULE, found {:?}",
                    start_tok.kind
                ));
            }
        };
        let (name, _) = self.expect_ident()?;
        // Optional priority `[expr]` (PIM).
        let priority = if self.eat_kind(&TokenKind::LBracket) {
            let e = self.parse_expr()?;
            self.expect_kind(TokenKind::RBracket, "']'")?;
            Some(e)
        } else {
            None
        };
        // Module-header pragmas (e.g., `<* … *>` immediately after the
        // name/priority).
        let mut pragmas = start_pragmas;
        pragmas.extend(self.collect_pragmas());
        self.expect_kind(TokenKind::Semicolon, "';'")?;
        // IMPORT clauses.
        let imports = self.parse_imports()?;
        // DEFINITION modules: declarations only, no body.
        // IMPLEMENTATION / PROGRAM / LOCAL: declarations + optional body.
        let (decls, body) = if kind == ModuleKind::Definition {
            let decls = self.parse_top_decls(/* allow_bodies = */ false)?;
            (decls, None)
        } else {
            let decls = self.parse_top_decls(/* allow_bodies = */ true)?;
            let body = if self.eat_kw(Keyword::Begin) {
                let stmts = self.parse_stmt_seq()?;
                let block = self.finish_block(stmts, start_tok.span)?;
                Some(block)
            } else {
                None
            };
            (decls, body)
        };
        let end_span = self.expect_kw(Keyword::End)?;
        let (end_name, end_name_span) = self.expect_ident()?;
        if end_name != name {
            return self.err_at(
                end_name_span,
                format!("module name mismatch: header '{name}' vs END '{end_name}'"),
            );
        }
        self.expect_kind(TokenKind::Dot, "'.'")?;
        let span = Span { start: start_tok.span.start, end: end_span.end };
        Ok(Module { kind, name, priority, pragmas, imports, decls, body, span })
    }

    fn parse_imports(&mut self) -> Result<Vec<Import>, ParseError> {
        let mut out = Vec::new();
        loop {
            // Skip stray pragmas between imports.
            while matches!(self.peek_kind(), TokenKind::Pragma(_)) {
                self.bump();
            }
            match self.peek_kind() {
                TokenKind::Keyword(Keyword::From) => {
                    let start = self.peek().span;
                    self.bump();
                    let (module, _) = self.expect_ident()?;
                    self.expect_kw(Keyword::Import)?;
                    // ADW wildcard: `FROM Mod IMPORT *;`. We record the
                    // import with an empty name list as the wildcard
                    // marker (sema decides).
                    let names = if self.eat_kind(&TokenKind::Star) {
                        Vec::new()
                    } else {
                        self.parse_ident_list()?
                    };
                    let semi = self.expect_kind(TokenKind::Semicolon, "';'")?;
                    out.push(Import::From {
                        module,
                        names,
                        span: Span { start: start.start, end: semi.end },
                    });
                }
                TokenKind::Keyword(Keyword::Import) => {
                    let start = self.peek().span;
                    self.bump();
                    let mut names = Vec::new();
                    loop {
                        let (n, ns) = self.expect_ident()?;
                        let alias = if self.eat_kind(&TokenKind::Assign) {
                            let (a, _) = self.expect_ident()?;
                            Some(a)
                        } else {
                            None
                        };
                        names.push(ImportName { name: n, alias, span: ns });
                        if !self.eat_kind(&TokenKind::Comma) {
                            break;
                        }
                    }
                    let semi = self.expect_kind(TokenKind::Semicolon, "';'")?;
                    out.push(Import::Plain {
                        names,
                        span: Span { start: start.start, end: semi.end },
                    });
                }
                _ => break,
            }
        }
        Ok(out)
    }

    fn parse_ident_list(&mut self) -> Result<Vec<String>, ParseError> {
        let mut out = Vec::new();
        let (n, _) = self.expect_ident()?;
        out.push(n);
        while self.eat_kind(&TokenKind::Comma) {
            let (n, _) = self.expect_ident()?;
            out.push(n);
        }
        Ok(out)
    }

    // ----- Top-level declarations -------------------------------------

    fn parse_top_decls(&mut self, allow_bodies: bool) -> Result<Vec<Decl>, ParseError> {
        let mut out = Vec::new();
        loop {
            // Pragmas between declarations are attached as their own
            // pseudo-decl so they survive ordering.
            while let TokenKind::Pragma(body) = self.peek_kind() {
                let body = body.clone();
                let span = self.peek().span;
                self.bump();
                out.push(Decl::Pragma(Pragma { body, span }));
            }
            match self.peek_kind() {
                TokenKind::Keyword(Keyword::Const) => {
                    self.bump();
                    loop {
                        // Pragmas between CONST decls (ADW formatting).
                        while let TokenKind::Pragma(body) = self.peek_kind() {
                            let body = body.clone();
                            let span = self.peek().span;
                            self.bump();
                            out.push(Decl::Pragma(Pragma { body, span }));
                        }
                        if let Some(d) = self.parse_const_decl_opt()? {
                            out.push(Decl::Const(d));
                        } else {
                            break;
                        }
                    }
                }
                TokenKind::Keyword(Keyword::Type) => {
                    self.bump();
                    loop {
                        while let TokenKind::Pragma(body) = self.peek_kind() {
                            let body = body.clone();
                            let span = self.peek().span;
                            self.bump();
                            out.push(Decl::Pragma(Pragma { body, span }));
                        }
                        if let Some(d) = self.parse_type_decl_opt()? {
                            out.push(Decl::Type(d));
                        } else {
                            break;
                        }
                    }
                }
                TokenKind::Keyword(Keyword::Var) => {
                    self.bump();
                    loop {
                        while let TokenKind::Pragma(body) = self.peek_kind() {
                            let body = body.clone();
                            let span = self.peek().span;
                            self.bump();
                            out.push(Decl::Pragma(Pragma { body, span }));
                        }
                        if let Some(d) = self.parse_var_decl_opt()? {
                            out.push(Decl::Var(d));
                        } else {
                            break;
                        }
                    }
                }
                TokenKind::Keyword(Keyword::Procedure) => {
                    let d = self.parse_procedure_decl(allow_bodies)?;
                    out.push(Decl::Procedure(d));
                }
                TokenKind::Keyword(Keyword::Module) if allow_bodies => {
                    // LOCAL MODULE — recurse into nested module.
                    let m = self.parse_local_module()?;
                    out.push(Decl::LocalModule(Box::new(m)));
                }
                TokenKind::Keyword(Keyword::Export) => {
                    let start = self.peek().span;
                    self.bump();
                    let qualified = self.eat_kw(Keyword::Qualified);
                    let names = self.parse_ident_list()?;
                    let semi = self.expect_kind(TokenKind::Semicolon, "';'")?;
                    out.push(Decl::Export {
                        qualified,
                        names,
                        span: Span { start: start.start, end: semi.end },
                    });
                }
                // ADW / ISO 10514-2 OO: `[ABSTRACT] CLASS Name; …
                // END Name;`. Parsed into a `Decl::Class` AST node.
                TokenKind::Keyword(Keyword::Abstract)
                    if matches!(
                        self.peek_at(1).map(|t| &t.kind),
                        Some(TokenKind::Ident(n)) if n == "CLASS"
                    ) =>
                {
                    let c = self.parse_class_decl(allow_bodies)?;
                    out.push(Decl::Class(c));
                }
                TokenKind::Ident(name) if name == "CLASS" => {
                    let c = self.parse_class_decl(allow_bodies)?;
                    out.push(Decl::Class(c));
                }
                // `INTERFACE Name [ "iid" ]; INHERIT Base; <methods> END Name;`
                // — a COM vtable-only class (see docs/design/com-interfaces.md).
                TokenKind::Ident(name) if name == "INTERFACE" => {
                    let c = self.parse_class_decl(allow_bodies)?;
                    out.push(Decl::Class(c));
                }
                // ADW top-level static check: `ASSERT(expr);`. Treated as
                // a no-op declaration at parse time.
                TokenKind::Ident(name) if name == "ASSERT" => {
                    self.bump();
                    if self.at_kind(&TokenKind::LParen) {
                        self.bump();
                        let mut depth = 1usize;
                        while depth > 0 {
                            match self.peek_kind() {
                                TokenKind::LParen => {
                                    depth += 1;
                                    self.bump();
                                }
                                TokenKind::RParen => {
                                    depth -= 1;
                                    self.bump();
                                }
                                TokenKind::Eof => break,
                                _ => {
                                    self.bump();
                                }
                            }
                        }
                    }
                    self.eat_kind(&TokenKind::Semicolon);
                }
                _ => break,
            }
        }
        Ok(out)
    }

    /// Parse a `[ABSTRACT] CLASS Name; [FORWARD;] | { ... } END Name;`
    /// declaration into a structural [`ClassDecl`].
    fn parse_class_decl(&mut self, allow_bodies: bool) -> Result<ClassDecl, ParseError> {
        let start = self.peek().span;
        let is_abstract_kw = self.eat_kw(Keyword::Abstract);
        let kind = if self.eat_soft_kw("INTERFACE") {
            ClassKind::Interface
        } else if self.eat_soft_kw("CLASS") {
            ClassKind::Class
        } else {
            return self.err("expected CLASS or INTERFACE");
        };
        // An INTERFACE is implicitly abstract (vtable-only; no concrete body).
        let is_abstract = is_abstract_kw || kind == ClassKind::Interface;
        let (name, _) = self.expect_ident()?;
        let exported = self.eat_kind(&TokenKind::Star);
        // Optional COM IID: `[ "xxxxxxxx-...." ]` right after the name.
        let iid = self.parse_optional_iid()?;
        self.expect_kind(TokenKind::Semicolon, "';'")?;

        // Forward declaration: `[ABSTRACT] CLASS Name; FORWARD;`.
        if self.eat_kw(Keyword::Forward) {
            self.expect_kind(TokenKind::Semicolon, "';'")?;
            let end = self.toks[self.pos.saturating_sub(1)].span.end;
            return Ok(ClassDecl {
                name,
                kind,
                is_abstract,
                is_forward: true,
                iid,
                implements: Vec::new(),
                inherit: None,
                reveal: Vec::new(),
                members: Vec::new(),
                exported,
                span: Span { start: start.start, end },
            });
        }

        // Optional INHERIT clause.
        let inherit = if self.eat_soft_kw("INHERIT") {
            let base = self.parse_qual_name()?;
            self.expect_kind(TokenKind::Semicolon, "';'")?;
            Some(base)
        } else {
            None
        };

        // Optional IMPLEMENTS clause (producer side): a comma list of interfaces.
        let implements = if self.eat_soft_kw("IMPLEMENTS") {
            let mut v = vec![self.parse_qual_name()?];
            while self.eat_kind(&TokenKind::Comma) {
                v.push(self.parse_qual_name()?);
            }
            self.expect_kind(TokenKind::Semicolon, "';'")?;
            v
        } else {
            Vec::new()
        };

        // Optional REVEAL clause.
        let reveal = if self.eat_soft_kw("REVEAL") {
            let names = self.parse_reveal_list()?;
            self.expect_kind(TokenKind::Semicolon, "';'")?;
            names
        } else {
            Vec::new()
        };

        // Body: methods, abstract methods, fields, pragmas.
        let mut members = Vec::new();
        loop {
            while let TokenKind::Pragma(body) = self.peek_kind() {
                let body = body.clone();
                let span = self.peek().span;
                self.bump();
                members.push(ClassMember::Pragma(Pragma { body, span }));
            }
            match self.peek_kind() {
                TokenKind::Keyword(Keyword::End) => break,
                TokenKind::Keyword(Keyword::Var) => {
                    self.bump();
                    // Stop the field list at the next class-member boundary — a
                    // method (PROCEDURE / ABSTRACT / the OVERRIDE soft keyword),
                    // a pragma, or END — so OVERRIDE isn't misread as a field
                    // name.
                    while !self.at_class_member_boundary() {
                        match self.parse_var_decl_opt()? {
                            Some(v) => members.push(ClassMember::Field(v)),
                            None => break,
                        }
                    }
                }
                TokenKind::Keyword(Keyword::Abstract)
                    if matches!(
                        self.peek_at(1).map(|t| &t.kind),
                        Some(TokenKind::Keyword(Keyword::Procedure))
                    ) =>
                {
                    self.bump(); // ABSTRACT
                    let m = self.parse_method_decl(
                        /* is_abstract = */ true,
                        /* is_override = */ false,
                        allow_bodies,
                    )?;
                    members.push(ClassMember::Method(m));
                }
                TokenKind::Ident(n)
                    if n == "OVERRIDE"
                        && matches!(
                            self.peek_at(1).map(|t| &t.kind),
                            Some(TokenKind::Keyword(Keyword::Procedure))
                        ) =>
                {
                    self.bump(); // OVERRIDE
                    let m = self.parse_method_decl(
                        /* is_abstract = */ false,
                        /* is_override = */ true,
                        allow_bodies,
                    )?;
                    members.push(ClassMember::Method(m));
                }
                TokenKind::Keyword(Keyword::Procedure) => {
                    // INTERFACE methods are implicitly abstract (vtable-only, no
                    // body) even in a PROGRAM/IMPLEMENTATION module.
                    let abstract_method = kind == ClassKind::Interface;
                    let m = self.parse_method_decl(abstract_method, false, allow_bodies)?;
                    members.push(ClassMember::Method(m));
                }
                TokenKind::Eof => return self.err("unterminated CLASS block"),
                other => {
                    return self.err(format!(
                        "unexpected token {other:?} in CLASS body"
                    ));
                }
            }
        }
        self.expect_kw(Keyword::End)?;
        let (end_name, end_name_span) = self.expect_ident()?;
        if end_name != name {
            return self.err_at(
                end_name_span,
                format!("class name mismatch: header '{name}' vs END '{end_name}'"),
            );
        }
        let semi = self.expect_kind(TokenKind::Semicolon, "';'")?;
        Ok(ClassDecl {
            name,
            kind,
            is_abstract,
            is_forward: false,
            iid,
            implements,
            inherit,
            reveal,
            members,
            exported,
            span: Span { start: start.start, end: semi.end },
        })
    }

    /// Parse an optional COM IID annotation `[ "xxxxxxxx-...." ]` that may follow
    /// an interface/class name. Returns the GUID string, or None if absent.
    fn parse_optional_iid(&mut self) -> Result<Option<String>, ParseError> {
        if !self.eat_kind(&TokenKind::LBracket) {
            return Ok(None);
        }
        let guid = match self.peek_kind() {
            TokenKind::String(lit) => {
                let s = lit.value.clone();
                self.bump();
                s
            }
            _ => return self.err("expected a GUID string literal in the IID annotation"),
        };
        self.expect_kind(TokenKind::RBracket, "']'")?;
        Ok(Some(guid))
    }

    /// Parse a method declaration body for a class. The `ABSTRACT` /
    /// `OVERRIDE` prefix has already been consumed by the caller.
    fn parse_method_decl(
        &mut self,
        is_abstract: bool,
        is_override: bool,
        allow_body: bool,
    ) -> Result<MethodDecl, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::Procedure)?;
        let (name, _) = self.expect_ident()?;
        let params = if self.eat_kind(&TokenKind::LParen) {
            let mut ps = Vec::new();
            if !self.at_kind(&TokenKind::RParen) {
                loop {
                    ps.push(self.parse_param()?);
                    if !self.eat_kind(&TokenKind::Semicolon)
                        && !self.eat_kind(&TokenKind::Comma)
                    {
                        break;
                    }
                }
            }
            self.expect_kind(TokenKind::RParen, "')'")?;
            ps
        } else {
            Vec::new()
        };
        let return_ty = if self.eat_kind(&TokenKind::Colon) {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        let attrs = self.parse_proc_attrs()?;
        let pragmas = self.collect_pragmas();
        self.expect_kind(TokenKind::Semicolon, "';'")?;

        // ABSTRACT methods never have a body. Concrete methods only
        // carry a body in IMPLEMENTATION / PROGRAM modules.
        let mut body = None;
        if !is_abstract && allow_body {
            if matches!(
                self.peek_kind(),
                TokenKind::Keyword(Keyword::Const)
                    | TokenKind::Keyword(Keyword::Type)
                    | TokenKind::Keyword(Keyword::Var)
                    | TokenKind::Keyword(Keyword::Procedure)
                    | TokenKind::Keyword(Keyword::Begin)
            ) {
                let decls = self.parse_top_decls(true)?;
                let body_block = if self.eat_kw(Keyword::Begin) {
                    let stmts = self.parse_stmt_seq()?;
                    self.finish_block(stmts, start)?
                } else {
                    Block {
                        stmts: Vec::new(),
                        except: Vec::new(),
                        finally: None,
                        span: start,
                    }
                };
                self.expect_kw(Keyword::End)?;
                let (end_name, end_name_span) = self.expect_ident()?;
                if end_name != name {
                    return self.err_at(
                        end_name_span,
                        format!(
                            "method name mismatch: header '{name}' vs END '{end_name}'"
                        ),
                    );
                }
                self.expect_kind(TokenKind::Semicolon, "';'")?;
                body = Some(ProcBody { decls, body: body_block });
            }
        }
        let end = self.toks[self.pos.saturating_sub(1)].span.end;
        Ok(MethodDecl {
            name,
            is_abstract,
            is_override,
            params,
            return_ty,
            attrs,
            body,
            pragmas,
            span: Span { start: start.start, end },
        })
    }

    fn parse_const_decl_opt(&mut self) -> Result<Option<ConstDecl>, ParseError> {
        match self.peek_kind() {
            TokenKind::Ident(_) => {
                let (name, name_span) = self.expect_ident()?;
                let exported = self.eat_kind(&TokenKind::Star);
                // ADW typed constant: `name : type = value;`. The type
                // is informational at parse time.
                if self.eat_kind(&TokenKind::Colon) {
                    let _ty = self.parse_type_expr()?;
                }
                self.expect_kind(TokenKind::Equal, "'='")?;
                let value = self.parse_expr()?;
                let end = self.expect_kind(TokenKind::Semicolon, "';'")?;
                Ok(Some(ConstDecl {
                    name,
                    value,
                    exported,
                    span: Span { start: name_span.start, end: end.end },
                }))
            }
            _ => Ok(None),
        }
    }

    fn parse_type_decl_opt(&mut self) -> Result<Option<TypeDecl>, ParseError> {
        match self.peek_kind() {
            // ADW `ASSERT(expr);` can appear between TYPE declarations
            // at top level. Don't consume it as a TYPE decl — bail out
            // and let the top-decl loop handle it on its next iteration.
            TokenKind::Ident(name)
                if name == "ASSERT"
                    && matches!(self.peek_at(1).map(|t| &t.kind), Some(TokenKind::LParen)) =>
            {
                Ok(None)
            }
            // `INTERFACE`/`CLASS` are soft keywords beginning a top-level
            // declaration (a COM interface or an OO class). When one appears in
            // the middle of a `TYPE` section — as winapi-gen emits, structs
            // then interfaces — it is NOT a type-alias name; bail so the
            // top-decl loop dispatches it as a class/interface. The `Ident Name`
            // shape (a soft keyword followed by the declared name) is what
            // distinguishes it from a genuine variable/type literally so named.
            TokenKind::Ident(name)
                if (name == "INTERFACE" || name == "CLASS")
                    && matches!(self.peek_at(1).map(|t| &t.kind), Some(TokenKind::Ident(_))) =>
            {
                Ok(None)
            }
            TokenKind::Ident(_) => {
                let (name, name_span) = self.expect_ident()?;
                let exported = self.eat_kind(&TokenKind::Star);
                if self.eat_kind(&TokenKind::Semicolon) {
                    // Opaque: `TYPE T;`.
                    return Ok(Some(TypeDecl {
                        name,
                        def: None,
                        exported,
                        span: name_span,
                    }));
                }
                self.expect_kind(TokenKind::Equal, "'='")?;
                let ty = self.parse_type_expr()?;
                let end = self.expect_kind(TokenKind::Semicolon, "';'")?;
                Ok(Some(TypeDecl {
                    name,
                    def: Some(ty),
                    exported,
                    span: Span { start: name_span.start, end: end.end },
                }))
            }
            _ => Ok(None),
        }
    }

    /// True when the parser is at the start of a class member that ends a field
    /// (`VAR`) list: a method (`PROCEDURE`/`ABSTRACT`/the `OVERRIDE` soft
    /// keyword), a pragma, `END`, or end of input.
    fn at_class_member_boundary(&self) -> bool {
        match self.peek_kind() {
            TokenKind::Keyword(Keyword::End | Keyword::Procedure | Keyword::Abstract) => true,
            TokenKind::Ident(n) => n == "OVERRIDE",
            TokenKind::Pragma(_) | TokenKind::Eof => true,
            _ => false,
        }
    }

    fn parse_var_decl_opt(&mut self) -> Result<Option<VarDecl>, ParseError> {
        // `CLASS` is a soft keyword: `CLASS Name` (an Ident followed by another
        // Ident) begins a class declaration, so it ends the VAR section rather
        // than naming a variable. A genuine variable literally named `CLASS`
        // would be followed by `:`/`,`/`*`, not an identifier, so this stays
        // precise. (`ABSTRACT CLASS` is a real keyword and already stops here.)
        if matches!(self.peek_kind(), TokenKind::Ident(n) if n == "CLASS")
            && matches!(self.peek_at(1).map(|t| &t.kind), Some(TokenKind::Ident(_)))
        {
            return Ok(None);
        }
        match self.peek_kind() {
            TokenKind::Ident(_) => {
                let pragmas = self.collect_pragmas();
                let (first, first_span) = self.expect_ident()?;
                let mut names = vec![first];
                let exported = self.eat_kind(&TokenKind::Star);
                // ADW external linkage: `name ["link-name" [EXTERNAL]]`
                // — opaque content; we skip everything until the
                // matching `]` so attribute words inside the brackets
                // don't confuse later parsing.
                if self.at_kind(&TokenKind::LBracket)
                    && matches!(self.peek_at(1).map(|t| &t.kind), Some(TokenKind::String(_)))
                {
                    self.skip_brackets();
                }
                while self.eat_kind(&TokenKind::Comma) {
                    let (n, _) = self.expect_ident()?;
                    names.push(n);
                    self.eat_kind(&TokenKind::Star);
                    if self.at_kind(&TokenKind::LBracket)
                        && matches!(self.peek_at(1).map(|t| &t.kind), Some(TokenKind::String(_)))
                    {
                        self.skip_brackets();
                    }
                }
                // PIM address binding `[expr]` (only when not a string).
                let address = if self.at_kind(&TokenKind::LBracket) {
                    self.bump();
                    let e = self.parse_expr()?;
                    self.expect_kind(TokenKind::RBracket, "']'")?;
                    Some(e)
                } else {
                    None
                };
                self.expect_kind(TokenKind::Colon, "':'")?;
                let ty = self.parse_type_expr()?;
                // Optional initializer `= expr` (ADW extension).
                if self.eat_kind(&TokenKind::Equal) {
                    let _ = self.parse_expr()?;
                }
                let end = self.expect_kind(TokenKind::Semicolon, "';'")?;
                Ok(Some(VarDecl {
                    names,
                    ty,
                    address,
                    pragmas,
                    exported,
                    span: Span { start: first_span.start, end: end.end },
                }))
            }
            _ => Ok(None),
        }
    }

    fn parse_procedure_decl(&mut self, allow_body: bool) -> Result<ProcDecl, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::Procedure)?;
        // Builtin/inline qualifiers between PROCEDURE and the name, e.g.
        // `PROCEDURE __BUILTIN__ alloca (...)`. Skip them; the procedure is
        // declared and bound like any other.
        while matches!(
            &self.peek().kind,
            TokenKind::Ident(s) if s == "__BUILTIN__" || s == "__INLINE__"
        ) {
            self.bump();
        }
        let (name, _) = self.expect_ident()?;
        let exported = self.eat_kind(&TokenKind::Star);
        let external_linkage = self.parse_proc_external_linkage()?;
        // Parameters.
        let mut is_variadic = false;
        let params = if self.eat_kind(&TokenKind::LParen) {
            let mut ps = Vec::new();
            if !self.at_kind(&TokenKind::RParen) {
                loop {
                    // `...` marks a C-style variadic procedure (e.g. printf).
                    if self.at_ellipsis() {
                        self.eat_ellipsis();
                        is_variadic = true;
                        break;
                    }
                    ps.push(self.parse_param()?);
                    if !self.eat_kind(&TokenKind::Semicolon)
                        && !self.eat_kind(&TokenKind::Comma)
                    {
                        break;
                    }
                }
            }
            self.expect_kind(TokenKind::RParen, "')'")?;
            ps
        } else {
            Vec::new()
        };
        // Return type.
        let return_ty = if self.eat_kind(&TokenKind::Colon) {
            Some(self.parse_type_expr()?)
        } else {
            None
        };
        // ADW square-bracket procedure attributes.
        let mut attrs = self.parse_proc_attrs()?;
        if is_variadic {
            attrs.push(ProcAttr { name: "VARARGS".to_string(), args: Vec::new(), span: start });
        }
        // Optional pragmas before semicolon.
        let pragmas = self.collect_pragmas();
        // FORWARD? assignment to external symbol? `= IdentForward;` (ADW)
        let mut is_forward = false;
        let mut body: Option<ProcBody> = None;
        if self.eat_kw(Keyword::Forward) {
            is_forward = true;
            self.expect_kind(TokenKind::Semicolon, "';'")?;
        } else if self.eat_kind(&TokenKind::Equal) {
            // `PROCEDURE Foo (...) = QualName;` ADW alias to an existing
            // (possibly qualified) procedure name.
            let _ = self.parse_qual_name()?;
            self.expect_kind(TokenKind::Semicolon, "';'")?;
        } else {
            self.expect_kind(TokenKind::Semicolon, "';'")?;
            // `PROCEDURE foo ; FORWARD ;` — a forward declaration in which the
            // FORWARD directive follows the header's semicolon (PIM/ISO), as
            // opposed to the ADW `PROCEDURE foo FORWARD;` form handled above.
            if self.eat_kw(Keyword::Forward) {
                self.expect_kind(TokenKind::Semicolon, "';'")?;
                let end_pos = self.toks[self.pos.saturating_sub(1)].span.end;
                return Ok(ProcDecl {
                    name,
                    external_linkage,
                    params,
                    return_ty,
                    attrs,
                    body: None,
                    asm_body: None,
                    is_forward: true,
                    pragmas,
                    exported,
                    span: Span { start: start.start, end: end_pos },
                });
            }
            // `PROCEDURE name; ASM … END name;` — Intel assembly body.
            if self.at_kw(Keyword::Asm) {
                self.bump(); // consume ASM
                let body_start = self.peek().span.start.offset;
                let mut body_end = body_start;
                let mut depth: usize = 0;
                loop {
                    if self.pos >= self.toks.len() {
                        return self.err_at(start, "unterminated ASM block — expected END".to_string());
                    }
                    if self.at_kw(Keyword::Asm) {
                        depth += 1;
                        self.bump();
                        continue;
                    }
                    if self.at_kw(Keyword::End) {
                        if depth == 0 {
                            body_end = self.peek().span.start.offset;
                            self.bump(); // END
                            // Expect the procedure name and semicolon.
                            if let TokenKind::Ident(end_name) = self.peek().kind.clone() {
                                if end_name != name {
                                    let sp = self.peek().span;
                                    return self.err_at(sp, format!(
                                        "procedure name mismatch: header '{}' vs END '{}'",
                                        name, end_name
                                    ));
                                }
                                self.bump();
                            }
                            self.expect_kind(TokenKind::Semicolon, "';'")?;
                            break;
                        }
                        depth -= 1;
                        self.bump();
                        continue;
                    }
                    self.bump();
                }
                let asm_body = self.source[body_start..body_end].to_string();
                let end_pos = self.toks[self.pos.saturating_sub(1)].span.end;
                return Ok(ProcDecl {
                    name, external_linkage, params, return_ty, attrs,
                    body: None, asm_body: Some(asm_body),
                    is_forward: false, pragmas, exported,
                    span: Span { start: start.start, end: end_pos },
                });
            }
            // ADW `MACRO;` trailer marks an inline procedure. The body
            // immediately follows even when the surrounding module is a
            // DEFINITION MODULE (the body is what gets inlined). Flip
            // `allow_body` locally so we parse it.
            let mut allow_body = allow_body;
            if self.eat_soft_kw("MACRO") {
                self.expect_kind(TokenKind::Semicolon, "';'")?;
                allow_body = true;
            }
            if allow_body {
                // Procedure body if the next decl context has BEGIN/END.
                // Peek for nested decls / BEGIN.
                if matches!(
                    self.peek_kind(),
                    TokenKind::Keyword(Keyword::Const)
                        | TokenKind::Keyword(Keyword::Type)
                        | TokenKind::Keyword(Keyword::Var)
                        | TokenKind::Keyword(Keyword::Procedure)
                        | TokenKind::Keyword(Keyword::Module)
                        | TokenKind::Keyword(Keyword::Begin)
                        | TokenKind::Keyword(Keyword::End)
                        | TokenKind::Keyword(Keyword::Export)
                ) {
                    let decls = self.parse_top_decls(true)?;
                    let body_block = if self.eat_kw(Keyword::Begin) {
                        let stmts = self.parse_stmt_seq()?;
                        self.finish_block(stmts, start)?
                    } else {
                        Block {
                            stmts: Vec::new(),
                            except: Vec::new(),
                            finally: None,
                            span: start,
                        }
                    };
                    self.expect_kw(Keyword::End)?;
                    let (end_name, end_name_span) = self.expect_ident()?;
                    if end_name != name {
                        return self.err_at(
                            end_name_span,
                            format!(
                                "procedure name mismatch: header '{name}' vs END '{end_name}'"
                            ),
                        );
                    }
                    self.expect_kind(TokenKind::Semicolon, "';'")?;
                    body = Some(ProcBody { decls, body: body_block });
                }
            }
        }
        let end_pos = self.toks[self.pos.saturating_sub(1)].span.end;
        Ok(ProcDecl {
            name,
            external_linkage,
            params,
            return_ty,
            attrs,
            body,
            asm_body: None,
            is_forward,
            pragmas,
            exported,
            span: Span { start: start.start, end: end_pos },
        })
    }

    fn parse_proc_external_linkage(&mut self) -> Result<Option<ProcExternalLinkage>, ParseError> {
        if !self.at_kind(&TokenKind::LBracket)
            || !matches!(self.peek_at(1).map(|t| &t.kind), Some(TokenKind::String(_)))
        {
            return Ok(None);
        }

        let start = self.expect_kind(TokenKind::LBracket, "'['")?;
        let (link_name, _) = self.expect_string_literal()?;
        let is_external = self.eat_soft_kw("EXTERNAL");
        let dll_name = if self.eat_kw(Keyword::From) {
            Some(self.expect_string_literal()?.0)
        } else {
            None
        };
        let end = self.expect_kind(TokenKind::RBracket, "']'")?;
        Ok(Some(ProcExternalLinkage {
            link_name,
            dll_name,
            is_external,
            span: Span { start: start.start, end: end.end },
        }))
    }

    fn parse_param(&mut self) -> Result<Param, ParseError> {
        let pragmas = self.collect_pragmas();
        // ADW param modes:
        //   VAR             — by reference, in/out
        //   VAR OUT name    — write-only reference (soft keyword OUT)
        //   VAR INOUT name  — explicit in/out reference (soft keyword)
        //   OUT name        — bare OUT (rarer)
        //   CONST name      — read-only reference (ADW)
        //   <none>          — value
        let mode = if self.eat_kw(Keyword::Var) {
            // Accept optional soft-keyword annotation directly after VAR.
            let _ = self.eat_soft_kw("OUT") || self.eat_soft_kw("INOUT");
            ParamMode::Var
        } else if self.eat_soft_kw("OUT") || self.eat_soft_kw("INOUT") {
            // OUT/INOUT — VAR-like (by reference).
            ParamMode::Var
        } else if self.eat_kw(Keyword::Const) || self.eat_soft_kw("CONST") {
            // CONST — a read-only value parameter.
            ParamMode::Const
        } else {
            ParamMode::Value
        };
        // NB: `VALUE` is *not* a param-mode keyword. It is a
        // type-level modifier handled in parse_type_expr.
        let first_span = self.peek().span;
        let mut names = vec![self.expect_ident()?.0];
        while self.eat_kind(&TokenKind::Comma) {
            names.push(self.expect_ident()?.0);
        }
        self.expect_kind(TokenKind::Colon, "':'")?;
        let ty = self.parse_type_expr()?;
        let end = self.toks[self.pos.saturating_sub(1)].span.end;
        Ok(Param {
            mode,
            names,
            ty,
            pragmas,
            span: Span { start: first_span.start, end },
        })
    }

    /// Consume an identifier with the given spelling (case-sensitive)
    /// when it appears as a "soft keyword" — i.e. not in the reserved
    /// keyword table but treated specially in a particular context.
    fn eat_soft_kw(&mut self, expected: &str) -> bool {
        if let TokenKind::Ident(name) = self.peek_kind()
            && name == expected
        {
            self.bump();
            return true;
        }
        false
    }

    /// Skip a balanced `[ … ]` group at the current position, consuming
    /// the opening `[`, every token between, and the matching `]`.
    /// Used for ADW external-linkage bracket pairs whose contents are
    /// opaque to the parser.
    fn skip_brackets(&mut self) {
        if !self.eat_kind(&TokenKind::LBracket) {
            return;
        }
        let mut depth = 1usize;
        while depth > 0 {
            match self.peek_kind() {
                TokenKind::LBracket => {
                    depth += 1;
                    self.bump();
                }
                TokenKind::RBracket => {
                    depth -= 1;
                    self.bump();
                }
                TokenKind::Eof => break,
                _ => {
                    self.bump();
                }
            }
        }
    }

    /// Look ahead from the current position past the opening `[` and
    /// matching `]`, return true iff a `..` token appears at depth 0.
    /// Used to decide whether `T[…]` is a subrange (`[lo..hi]`) or
    /// something else.
    fn bracketed_run_contains_dotdot(&self) -> bool {
        let mut depth = 0i32;
        let mut i = self.pos;
        // The current token is the `[`. We scan past it and look until
        // the matching `]` is found at depth 0.
        if !matches!(self.toks.get(i).map(|t| &t.kind), Some(TokenKind::LBracket)) {
            return false;
        }
        i += 1;
        while i < self.toks.len() {
            match &self.toks[i].kind {
                TokenKind::LBracket | TokenKind::LParen | TokenKind::LBrace => depth += 1,
                TokenKind::RBracket if depth == 0 => return false,
                TokenKind::RBracket | TokenKind::RParen | TokenKind::RBrace => depth -= 1,
                TokenKind::DotDot if depth == 0 => return true,
                TokenKind::Eof => return false,
                _ => {}
            }
            i += 1;
        }
        false
    }

    fn parse_proc_attrs(&mut self) -> Result<Vec<ProcAttr>, ParseError> {
        if !self.at_kind(&TokenKind::LBracket) {
            return Ok(Vec::new());
        }
        let _ = self.bump();
        let mut out = Vec::new();
        loop {
            // Skip pragmas inside the attr list.
            while matches!(self.peek_kind(), TokenKind::Pragma(_)) {
                self.bump();
            }
            if self.at_kind(&TokenKind::RBracket) {
                break;
            }
            // Attribute names can collide with reserved keywords (e.g.
            // `[EXPORT]`, `[CONST]`). Accept either token kind.
            let (name, name_span) = match self.peek_kind() {
                TokenKind::Ident(n) => {
                    let n = n.clone();
                    let s = self.peek().span;
                    self.bump();
                    (n, s)
                }
                TokenKind::Keyword(kw) => {
                    let n = kw.as_str().to_string();
                    let s = self.peek().span;
                    self.bump();
                    (n, s)
                }
                _ => return self.err("expected attribute name"),
            };
            let mut args = Vec::new();
            if self.eat_kind(&TokenKind::LParen) {
                if !self.at_kind(&TokenKind::RParen) {
                    loop {
                        // Collect raw text of arg tokens until ',' or ')'.
                        args.push(self.collect_attr_arg()?);
                        if !self.eat_kind(&TokenKind::Comma) {
                            break;
                        }
                    }
                }
                self.expect_kind(TokenKind::RParen, "')'")?;
            }
            out.push(ProcAttr {
                name,
                args,
                span: name_span,
            });
            if !self.eat_kind(&TokenKind::Comma) {
                break;
            }
        }
        self.expect_kind(TokenKind::RBracket, "']'")?;
        Ok(out)
    }

    fn collect_attr_arg(&mut self) -> Result<String, ParseError> {
        // Argument is one or more tokens up to ',' or ')'. We just
        // concatenate their text representations separated by spaces.
        let mut out = String::new();
        let mut depth = 0usize;
        loop {
            match self.peek_kind() {
                TokenKind::Comma | TokenKind::RParen if depth == 0 => break,
                TokenKind::LParen => {
                    depth += 1;
                    if !out.is_empty() {
                        out.push(' ');
                    }
                    out.push_str(&self.peek_text());
                    self.bump();
                }
                TokenKind::RParen => {
                    depth -= 1;
                    if !out.is_empty() {
                        out.push(' ');
                    }
                    out.push_str(&self.peek_text());
                    self.bump();
                }
                TokenKind::Eof => break,
                _ => {
                    if !out.is_empty() {
                        out.push(' ');
                    }
                    out.push_str(&self.peek_text());
                    self.bump();
                }
            }
        }
        Ok(out)
    }

    fn parse_local_module(&mut self) -> Result<Module, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::Module)?;
        let (name, _) = self.expect_ident()?;
        let priority = if self.eat_kind(&TokenKind::LBracket) {
            let e = self.parse_expr()?;
            self.expect_kind(TokenKind::RBracket, "']'")?;
            Some(e)
        } else {
            None
        };
        let pragmas = self.collect_pragmas();
        self.expect_kind(TokenKind::Semicolon, "';'")?;
        let imports = self.parse_imports()?;
        let decls = self.parse_top_decls(true)?;
        let body = if self.eat_kw(Keyword::Begin) {
            let stmts = self.parse_stmt_seq()?;
            Some(self.finish_block(stmts, start)?)
        } else {
            None
        };
        self.expect_kw(Keyword::End)?;
        let (end_name, end_name_span) = self.expect_ident()?;
        if end_name != name {
            return self.err_at(
                end_name_span,
                format!("local module name mismatch: header '{name}' vs END '{end_name}'"),
            );
        }
        let semi = self.expect_kind(TokenKind::Semicolon, "';'")?;
        Ok(Module {
            kind: ModuleKind::Local,
            name,
            priority,
            pragmas,
            imports,
            decls,
            body,
            span: Span { start: start.start, end: semi.end },
        })
    }

    fn parse_reveal_list(&mut self) -> Result<Vec<String>, ParseError> {
        let mut names = Vec::new();
        loop {
            // ADW class reveal lists may annotate members as READONLY.
            self.eat_soft_kw("READONLY");
            names.push(self.expect_ident()?.0);
            if !self.eat_kind(&TokenKind::Comma) {
                break;
            }
        }
        Ok(names)
    }

    // ----- Types -------------------------------------------------------

    fn parse_type_expr(&mut self) -> Result<TypeExpr, ParseError> {
        // ADW: `VALUE T` is a type-level modifier meaning "pass by
        // value" (used at call sites to override the default by-ref
        // calling convention for large records). The modifier is
        // informational at the AST level.
        self.eat_soft_kw("VALUE");
        let start = self.peek().span;
        let ty = self.parse_type_expr_inner(start)?;
        // ADW trailing `BIG` is an extended-size modifier on any type.
        self.eat_soft_kw("BIG");
        Ok(ty)
    }

    fn parse_type_expr_inner(&mut self, start: Span) -> Result<TypeExpr, ParseError> {
        match self.peek_kind() {
            TokenKind::Keyword(Keyword::Array) => {
                self.bump();
                // `ARRAY OF base` (open) or `ARRAY idx1, idx2, … OF base`.
                if self.eat_kw(Keyword::Of) {
                    let base = self.parse_type_expr()?;
                    let end = self.toks[self.pos.saturating_sub(1)].span.end;
                    return Ok(TypeExpr::OpenArray(
                        Box::new(base),
                        Span { start: start.start, end },
                    ));
                }
                let mut indices = vec![self.parse_type_expr()?];
                while self.eat_kind(&TokenKind::Comma) {
                    indices.push(self.parse_type_expr()?);
                }
                self.expect_kw(Keyword::Of)?;
                let base = self.parse_type_expr()?;
                let end = self.toks[self.pos.saturating_sub(1)].span.end;
                Ok(TypeExpr::Array(
                    indices,
                    Box::new(base),
                    Span { start: start.start, end },
                ))
            }
            TokenKind::Keyword(Keyword::Record) => {
                self.bump();
                let rec = self.parse_record_body(start)?;
                Ok(TypeExpr::Record(rec))
            }
            TokenKind::Keyword(Keyword::Pointer) => {
                self.bump();
                self.expect_kw(Keyword::To)?;
                let base = self.parse_type_expr()?;
                let end = self.toks[self.pos.saturating_sub(1)].span.end;
                Ok(TypeExpr::Pointer(Box::new(base), Span { start: start.start, end }))
            }
            TokenKind::Keyword(Keyword::Procedure) => {
                self.bump();
                let params = if self.eat_kind(&TokenKind::LParen) {
                    let mut ps = Vec::new();
                    if !self.at_kind(&TokenKind::RParen) {
                        loop {
                            let pragmas = self.collect_pragmas();
                            let mode = if self.eat_kw(Keyword::Var) {
                                let _ = self.eat_soft_kw("OUT") || self.eat_soft_kw("INOUT");
                                ParamMode::Var
                            } else if self.eat_kw(Keyword::Const)
                                || self.eat_soft_kw("OUT")
                                || self.eat_soft_kw("INOUT")
                                || self.eat_soft_kw("CONST")
                            {
                                ParamMode::Var
                            } else {
                                ParamMode::Value
                            };
                            let ty = self.parse_type_expr()?;
                            ps.push(ProcTypeParam { mode, ty, pragmas });
                            if !self.eat_kind(&TokenKind::Comma)
                                && !self.eat_kind(&TokenKind::Semicolon)
                            {
                                break;
                            }
                        }
                    }
                    self.expect_kind(TokenKind::RParen, "')'")?;
                    ps
                } else {
                    Vec::new()
                };
                let return_ty = if self.eat_kind(&TokenKind::Colon) {
                    Some(Box::new(self.parse_type_expr()?))
                } else {
                    None
                };
                let attrs = self.parse_proc_attrs()?;
                let end = self.toks[self.pos.saturating_sub(1)].span.end;
                Ok(TypeExpr::Proc(ProcType {
                    params,
                    return_ty,
                    attrs,
                    span: Span { start: start.start, end },
                }))
            }
            TokenKind::Keyword(Keyword::Set) => {
                self.bump();
                self.expect_kw(Keyword::Of)?;
                let elem = self.parse_type_expr()?;
                let end = self.toks[self.pos.saturating_sub(1)].span.end;
                Ok(TypeExpr::Set {
                    packed: false,
                    element: Box::new(elem),
                    span: Span { start: start.start, end },
                })
            }
            TokenKind::Keyword(Keyword::Packedset) => {
                self.bump();
                self.expect_kw(Keyword::Of)?;
                let elem = self.parse_type_expr()?;
                let end = self.toks[self.pos.saturating_sub(1)].span.end;
                Ok(TypeExpr::Set {
                    packed: true,
                    element: Box::new(elem),
                    span: Span { start: start.start, end },
                })
            }
            TokenKind::LParen => {
                // Enumeration: `(red, green, blue)` or ADW form with
                // explicit ordinal values `(red = 0, green = 1, …)`.
                self.bump();
                let mut names = Vec::new();
                let mut values: Vec<Option<Expr>> = Vec::new();
                if !self.at_kind(&TokenKind::RParen) {
                    loop {
                        names.push(self.expect_ident()?.0);
                        // Optional explicit ordinal value (an ADW / C-enum form,
                        // `name = expr`). Carried through so sema can assign the
                        // member its real — possibly sparse — ordinal.
                        if self.eat_kind(&TokenKind::Equal) {
                            values.push(Some(self.parse_expr()?));
                        } else {
                            values.push(None);
                        }
                        if !self.eat_kind(&TokenKind::Comma) {
                            break;
                        }
                    }
                }
                let end = self.expect_kind(TokenKind::RParen, "')'")?;
                // ADW: trailing `BIG` indicates an extended-size enum.
                // We consume and discard.
                self.eat_soft_kw("BIG");
                Ok(TypeExpr::Enum(names, values, Span { start: start.start, end: end.end }))
            }
            TokenKind::LBracket => {
                // Subrange `[a..b]`.
                self.bump();
                let lo = self.parse_expr()?;
                self.expect_kind(TokenKind::DotDot, "'..'")?;
                let hi = self.parse_expr()?;
                let end = self.expect_kind(TokenKind::RBracket, "']'")?;
                Ok(TypeExpr::Subrange(
                    Box::new(lo),
                    Box::new(hi),
                    Span { start: start.start, end: end.end },
                ))
            }
            TokenKind::Ident(_) => {
                let qn = self.parse_qual_name()?;
                // ADW/ISO: `HostType[lo..hi]` is a host-constrained subrange.
                // We only commit to the subrange form if a `..` appears
                // before the matching `]` — otherwise `[…]` is something
                // else (a procedure attribute list, an index list, etc.)
                // and belongs to the caller's context.
                if self.at_kind(&TokenKind::LBracket) && self.bracketed_run_contains_dotdot() {
                    self.bump();
                    let lo = self.parse_expr()?;
                    self.expect_kind(TokenKind::DotDot, "'..'")?;
                    let hi = self.parse_expr()?;
                    let end = self.expect_kind(TokenKind::RBracket, "']'")?;
                    return Ok(TypeExpr::Subrange(
                        Box::new(lo),
                        Box::new(hi),
                        Span { start: qn.span.start, end: end.end },
                    ));
                }
                Ok(TypeExpr::Named(qn))
            }
            other => self.err(format!("expected type expression, found {other:?}")),
        }
    }

    fn parse_record_body(&mut self, start: Span) -> Result<RecordType, ParseError> {
        // ADW alignment attribute right after RECORD, e.g.
        // `RECORD [ALIGN 16]`. Opaque to the parser.
        if self.at_kind(&TokenKind::LBracket) {
            self.skip_brackets();
        }
        let mut fields = Vec::new();
        let mut variant: Option<VariantPart> = None;
        loop {
            // Skip pragmas between fields.
            while matches!(self.peek_kind(), TokenKind::Pragma(_)) {
                self.bump();
            }
            match self.peek_kind() {
                TokenKind::Keyword(Keyword::End) => break,
                // ADW BITFIELDS sub-section: each field has an optional
                // `BY <expr>` bit-width modifier. Closed with END.
                TokenKind::Ident(name) if name == "BITFIELDS" => {
                    self.bump();
                    self.parse_bitfields_section(&mut fields)?;
                    self.eat_kind(&TokenKind::Semicolon);
                    continue;
                }
                TokenKind::Keyword(Keyword::Case) => {
                    self.bump();
                    let v = self.parse_variant_part()?;
                    // ADW allows ordinary fields to follow a variant
                    // part within the same record. Optional `;` after.
                    self.eat_kind(&TokenKind::Semicolon);
                    variant = Some(v);
                    // Continue collecting fields rather than breaking.
                    continue;
                }
                TokenKind::Ident(_) => {
                    let pragmas = self.collect_pragmas();
                    let (first, first_span) = self.expect_ident()?;
                    let mut names = vec![first];
                    let exported = self.eat_kind(&TokenKind::Star);
                    // ADW record-field external linkage: `name ["link"]`.
                    if self.at_kind(&TokenKind::LBracket)
                        && matches!(self.peek_at(1).map(|t| &t.kind), Some(TokenKind::String(_)))
                    {
                        self.bump();
                        self.bump();
                        self.expect_kind(TokenKind::RBracket, "']'")?;
                    }
                    while self.eat_kind(&TokenKind::Comma) {
                        names.push(self.expect_ident()?.0);
                        self.eat_kind(&TokenKind::Star);
                        if self.at_kind(&TokenKind::LBracket)
                            && matches!(self.peek_at(1).map(|t| &t.kind), Some(TokenKind::String(_)))
                        {
                            self.bump();
                            self.bump();
                            self.expect_kind(TokenKind::RBracket, "']'")?;
                        }
                    }
                    self.expect_kind(TokenKind::Colon, "':'")?;
                    let ty = self.parse_type_expr()?;
                    let end = if self.eat_kind(&TokenKind::Semicolon) {
                        self.toks[self.pos - 1].span.end
                    } else {
                        // Final field can omit ';' before END.
                        self.peek().span.start
                    };
                    fields.push(RecordField {
                        names,
                        ty,
                        pragmas,
                        exported,
                        span: Span { start: first_span.start, end },
                    });
                }
                _ => break,
            }
        }
        let end = self.expect_kw(Keyword::End)?;
        Ok(RecordType { fields, variant, span: Span { start: start.start, end: end.end } })
    }

    /// Parse an ADW `BITFIELDS …; …; END` sub-section, appending each
    /// field (with its optional `BY <expr>` bit-width modifier
    /// discarded) onto the surrounding record's field list.
    fn parse_bitfields_section(
        &mut self,
        fields: &mut Vec<RecordField>,
    ) -> Result<(), ParseError> {
        loop {
            while matches!(self.peek_kind(), TokenKind::Pragma(_)) {
                self.bump();
            }
            if self.at_kw(Keyword::End) {
                self.bump();
                return Ok(());
            }
            let (first, first_span) = self.expect_ident()?;
            let mut names = vec![first];
            while self.eat_kind(&TokenKind::Comma) {
                names.push(self.expect_ident()?.0);
            }
            self.expect_kind(TokenKind::Colon, "':'")?;
            let ty = self.parse_type_expr()?;
            // Optional `BY <expr>` bit-width. `BY` is the reserved
            // keyword (the FOR-loop step keyword); it does dual duty.
            if self.eat_kw(Keyword::By) {
                let _ = self.parse_expr()?;
            }
            let end = if self.eat_kind(&TokenKind::Semicolon) {
                self.toks[self.pos - 1].span.end
            } else {
                self.peek().span.start
            };
            fields.push(RecordField {
                names,
                ty,
                pragmas: Vec::new(),
                exported: false,
                span: Span { start: first_span.start, end },
            });
        }
    }

    fn parse_variant_part(&mut self) -> Result<VariantPart, ParseError> {
        let start = self.toks[self.pos - 1].span; // CASE
        // tag := ident ':' type | ':' type | type (anonymous, no colon)
        let mut tag_name = None;
        let mut tag_type = None;
        if self.eat_kind(&TokenKind::Colon) {
            // ADW anonymous form: `CASE : type OF`.
            tag_type = Some(self.parse_qual_name()?);
        } else if let TokenKind::Ident(name) = self.peek_kind() {
            let save = self.pos;
            let name_cloned = name.clone();
            self.bump();
            if self.eat_kind(&TokenKind::Colon) {
                tag_name = Some(name_cloned);
                tag_type = Some(self.parse_qual_name()?);
            } else {
                self.pos = save;
                tag_type = Some(self.parse_qual_name()?);
            }
        }
        self.expect_kw(Keyword::Of)?;
        // ADW allows a leading `|` before the first variant arm.
        self.eat_kind(&TokenKind::Pipe);
        let mut arms = Vec::new();
        let mut else_arm: Option<Vec<RecordField>> = None;
        loop {
            if self.at_kw(Keyword::End) || self.at_kw(Keyword::Else) {
                break;
            }
            // Tolerate empty variant arms — a leading run of `|` or a `||`
            // between arms (e.g. `CASE tag OF ||| 0: ... | 1: ...`).
            if self.eat_kind(&TokenKind::Pipe) {
                continue;
            }
            arms.push(self.parse_variant_arm()?);
            if !self.eat_kind(&TokenKind::Pipe) {
                break;
            }
        }
        if self.eat_kw(Keyword::Else) {
            let mut fields = Vec::new();
            while matches!(self.peek_kind(), TokenKind::Ident(_) | TokenKind::Pragma(_)) {
                let pragmas = self.collect_pragmas();
                let (first, first_span) = self.expect_ident()?;
                let mut names = vec![first];
                let exported = self.eat_kind(&TokenKind::Star);
                while self.eat_kind(&TokenKind::Comma) {
                    names.push(self.expect_ident()?.0);
                    self.eat_kind(&TokenKind::Star);
                }
                self.expect_kind(TokenKind::Colon, "':'")?;
                let ty = self.parse_type_expr()?;
                let end = if self.eat_kind(&TokenKind::Semicolon) {
                    self.toks[self.pos - 1].span.end
                } else {
                    self.peek().span.start
                };
                fields.push(RecordField {
                    names,
                    ty,
                    pragmas,
                    exported,
                    span: Span { start: first_span.start, end },
                });
            }
            else_arm = Some(fields);
        }
        // The variant part itself ends with its own END (PIM
        // grammar). The outer RECORD then has another END.
        let end = self.expect_kw(Keyword::End)?;
        Ok(VariantPart {
            tag_name,
            tag_type,
            arms,
            else_arm,
            span: Span { start: start.start, end: end.end },
        })
    }

    fn parse_variant_arm(&mut self) -> Result<VariantArm, ParseError> {
        let start = self.peek().span;
        let mut labels = Vec::new();
        loop {
            let lo = self.parse_expr()?;
            if self.eat_kind(&TokenKind::DotDot) {
                let hi = self.parse_expr()?;
                labels.push(CaseLabel::Range(lo, hi));
            } else {
                labels.push(CaseLabel::Single(lo));
            }
            if !self.eat_kind(&TokenKind::Comma) {
                break;
            }
        }
        self.expect_kind(TokenKind::Colon, "':'")?;
        let mut fields = Vec::new();
        let mut nested: Option<Box<VariantPart>> = None;
        loop {
            match self.peek_kind() {
                TokenKind::Keyword(Keyword::End)
                | TokenKind::Keyword(Keyword::Else)
                | TokenKind::Pipe => break,
                TokenKind::Keyword(Keyword::Case) => {
                    self.bump();
                    nested = Some(Box::new(self.parse_variant_part()?));
                    // The nested variant's END may be followed by `;`
                    // before the next outer arm separator or END.
                    self.eat_kind(&TokenKind::Semicolon);
                    break;
                }
                TokenKind::Ident(name) if name == "BITFIELDS" => {
                    self.bump();
                    self.parse_bitfields_section(&mut fields)?;
                    self.eat_kind(&TokenKind::Semicolon);
                    continue;
                }
                TokenKind::Ident(_) | TokenKind::Pragma(_) => {
                    let pragmas = self.collect_pragmas();
                    // A trailing pragma in the arm (e.g. `<*END*>`) may
                    // not be followed by another field; gracefully end
                    // the arm if so.
                    if !matches!(self.peek_kind(), TokenKind::Ident(_)) {
                        if !pragmas.is_empty() {
                            // Drop the pragmas onto the previous field
                            // is not necessary; we accept them as
                            // arm-trailers and discard.
                        }
                        break;
                    }
                    let (first, first_span) = self.expect_ident()?;
                    let mut names = vec![first];
                    let exported = self.eat_kind(&TokenKind::Star);
                    while self.eat_kind(&TokenKind::Comma) {
                        names.push(self.expect_ident()?.0);
                        self.eat_kind(&TokenKind::Star);
                    }
                    self.expect_kind(TokenKind::Colon, "':'")?;
                    let ty = self.parse_type_expr()?;
                    let end = if self.eat_kind(&TokenKind::Semicolon) {
                        self.toks[self.pos - 1].span.end
                    } else {
                        self.peek().span.start
                    };
                    fields.push(RecordField {
                        names,
                        ty,
                        pragmas,
                        exported,
                        span: Span { start: first_span.start, end },
                    });
                }
                _ => break,
            }
        }
        let end = self.peek().span;
        Ok(VariantArm {
            labels,
            fields,
            variant: nested,
            span: Span { start: start.start, end: end.start },
        })
    }

    // ----- Expressions -------------------------------------------------

    fn parse_expr(&mut self) -> Result<Expr, ParseError> {
        self.parse_relational()
    }

    fn parse_relational(&mut self) -> Result<Expr, ParseError> {
        let start = self.peek().span;
        let mut left = self.parse_simple()?;
        loop {
            let op = match self.peek_kind() {
                TokenKind::Equal => BinaryOp::Eq,
                TokenKind::NotEqual | TokenKind::Hash => BinaryOp::Ne,
                TokenKind::Less => BinaryOp::Lt,
                TokenKind::LessEq => BinaryOp::Le,
                TokenKind::Greater => BinaryOp::Gt,
                TokenKind::GreaterEq => BinaryOp::Ge,
                TokenKind::Keyword(Keyword::In) => BinaryOp::In,
                _ => break,
            };
            self.bump();
            let right = self.parse_simple()?;
            let end = self.toks[self.pos.saturating_sub(1)].span.end;
            left = Expr::Binary(
                op,
                Box::new(left),
                Box::new(right),
                Span { start: start.start, end },
            );
        }
        Ok(left)
    }

    fn parse_simple(&mut self) -> Result<Expr, ParseError> {
        let start = self.peek().span;
        let sign = match self.peek_kind() {
            TokenKind::Plus => {
                self.bump();
                Some(UnaryOp::Pos)
            }
            TokenKind::Minus => {
                self.bump();
                Some(UnaryOp::Neg)
            }
            _ => None,
        };
        let mut left = self.parse_term()?;
        if let Some(op) = sign {
            let end = self.toks[self.pos.saturating_sub(1)].span.end;
            left = Expr::Unary(op, Box::new(left), Span { start: start.start, end });
        }
        loop {
            let op = match self.peek_kind() {
                TokenKind::Plus => BinaryOp::Add,
                TokenKind::Minus => BinaryOp::Sub,
                TokenKind::Keyword(Keyword::Or) => BinaryOp::Or,
                _ => break,
            };
            self.bump();
            let right = self.parse_term()?;
            let end = self.toks[self.pos.saturating_sub(1)].span.end;
            left = Expr::Binary(
                op,
                Box::new(left),
                Box::new(right),
                Span { start: start.start, end },
            );
        }
        Ok(left)
    }

    fn parse_term(&mut self) -> Result<Expr, ParseError> {
        let start = self.peek().span;
        let mut left = self.parse_factor()?;
        loop {
            let op = match self.peek_kind() {
                TokenKind::Star => BinaryOp::Mul,
                TokenKind::Slash => BinaryOp::Div,
                TokenKind::Keyword(Keyword::Div) => BinaryOp::DivKw,
                TokenKind::Keyword(Keyword::Mod) => BinaryOp::Mod,
                TokenKind::Keyword(Keyword::Rem) => BinaryOp::Rem,
                TokenKind::Keyword(Keyword::And) => BinaryOp::And,
                TokenKind::Amp => BinaryOp::And,
                // ADW bitwise word operators — keyword variants.
                TokenKind::Keyword(Keyword::Bor) => BinaryOp::Bor,
                TokenKind::Keyword(Keyword::Band) => BinaryOp::Band,
                TokenKind::Keyword(Keyword::Bxor) => BinaryOp::Bxor,
                TokenKind::Keyword(Keyword::Shl) => BinaryOp::Shl,
                TokenKind::Keyword(Keyword::Shr) => BinaryOp::Shr,
                // ADW bitwise word operators — ident variants (legacy).
                TokenKind::Ident(name)
                    if matches!(
                        name.as_str(),
                        "BAND" | "BOR" | "BXOR" | "SHL" | "SHR"
                    ) =>
                {
                    match name.as_str() {
                        "BOR" => BinaryOp::Bor,
                        "BAND" => BinaryOp::Band,
                        "BXOR" => BinaryOp::Bxor,
                        "SHL" => BinaryOp::Shl,
                        "SHR" => BinaryOp::Shr,
                        _ => BinaryOp::And,
                    }
                }
                _ => break,
            };
            self.bump();
            let right = self.parse_factor()?;
            let end = self.toks[self.pos.saturating_sub(1)].span.end;
            left = Expr::Binary(
                op,
                Box::new(left),
                Box::new(right),
                Span { start: start.start, end },
            );
        }
        Ok(left)
    }

    fn parse_factor(&mut self) -> Result<Expr, ParseError> {
        let start = self.peek().span;
        match self.peek_kind() {
            TokenKind::Integer(v) => {
                let v = *v;
                self.bump();
                Ok(Expr::Integer(v, start))
            }
            TokenKind::Real(v) => {
                let v = *v;
                self.bump();
                Ok(Expr::Real(v, start))
            }
            TokenKind::Char(c) => {
                let c = c.clone();
                self.bump();
                Ok(Expr::Char(c, start))
            }
            TokenKind::String(s) => {
                let s = s.clone();
                self.bump();
                Ok(Expr::String(s, start))
            }
            TokenKind::Keyword(Keyword::Not) | TokenKind::Tilde => {
                self.bump();
                let e = self.parse_factor()?;
                let end = self.toks[self.pos.saturating_sub(1)].span.end;
                Ok(Expr::Unary(
                    UnaryOp::Not,
                    Box::new(e),
                    Span { start: start.start, end },
                ))
            }
            // ADW bitwise unary not — keyword variant.
            TokenKind::Keyword(Keyword::Bnot) => {
                self.bump();
                let e = self.parse_factor()?;
                let end = self.toks[self.pos.saturating_sub(1)].span.end;
                Ok(Expr::Unary(
                    UnaryOp::Not,
                    Box::new(e),
                    Span { start: start.start, end },
                ))
            }
            // ADW bitwise unary not — ident variant (legacy).
            TokenKind::Ident(name) if name == "BNOT" => {
                self.bump();
                let e = self.parse_factor()?;
                let end = self.toks[self.pos.saturating_sub(1)].span.end;
                Ok(Expr::Unary(
                    UnaryOp::Not,
                    Box::new(e),
                    Span { start: start.start, end },
                ))
            }
            TokenKind::LParen => {
                self.bump();
                let e = self.parse_expr()?;
                self.expect_kind(TokenKind::RParen, "')'")?;
                Ok(e)
            }
            TokenKind::LBrace => {
                self.parse_set_constructor(None)
            }
            // Compile-time location builtins (C style). `__LINE__` becomes
            // the current source line; `__FILE__`/`__FUNCTION__` become string
            // constants. Their values are load-bearing only in assertion-failure
            // paths, so a placeholder string is sufficient for the file/function
            // forms (the parser has no filename).
            TokenKind::Ident(name)
                if matches!(name.as_str(), "__LINE__" | "__FILE__" | "__FUNCTION__") =>
            {
                let which = name.clone();
                self.bump();
                return Ok(match which.as_str() {
                    "__LINE__" => Expr::Integer(start.start.line as u64, start),
                    _ => Expr::String(
                        StringLiteral {
                            value: String::new(),
                            flavor: newm2_lexer::LiteralFlavor::Default,
                        },
                        start,
                    ),
                });
            }
            TokenKind::Ident(_) => {
                // `{` after a dotted identifier run = qualified set constructor
                // `T{...}` or `M.T{...}`.
                if self.dotted_ident_run_followed_by_lbrace() {
                    let qn = self.parse_qual_name()?;
                    return self.parse_set_constructor(Some(qn));
                }
                // Convert an identifier base into a Designator and continue with
                // selectors / call.
                let base = self.parse_designator_base()?;
                let dz = self.parse_designator_tail(base)?;
                let dz_end = dz.span.end;
                let expr = Expr::Designator(dz);
                if self.at_kind(&TokenKind::LParen) {
                    // Function call.
                    self.bump();
                    let mut args = Vec::new();
                    if !self.at_kind(&TokenKind::RParen) {
                        loop {
                            let arg = self.parse_expr()?;
                            // ADW inline type-cast `expr : Type` inside
                            // an argument position. The type is
                            // informational at parse time; we discard it.
                            if self.eat_kind(&TokenKind::Colon) {
                                let _ = self.parse_type_expr()?;
                            }
                            args.push(arg);
                            if !self.eat_kind(&TokenKind::Comma) {
                                break;
                            }
                        }
                    }
                    let end = self.expect_kind(TokenKind::RParen, "')'")?;
                    Ok(Expr::Call(
                        Box::new(expr),
                        args,
                        Span { start: start.start, end: end.end },
                    ))
                } else {
                    let _ = dz_end;
                    Ok(expr)
                }
            }
            other => self.err(format!("expected expression, found {other:?}")),
        }
    }

    fn parse_qual_name(&mut self) -> Result<QualName, ParseError> {
        let (first, first_span) = self.expect_ident()?;
        let mut segments = vec![first];
        let mut end = first_span.end;
        while self.at_kind(&TokenKind::Dot) {
            // Lookahead: only consume `.` if followed by an identifier.
            // (Otherwise `.` is the module-end terminator.)
            if let Some(next) = self.peek_at(1)
                && matches!(next.kind, TokenKind::Ident(_))
            {
                self.bump();
                let (n, ns) = self.expect_ident()?;
                segments.push(n);
                end = ns.end;
            } else {
                break;
            }
        }
        Ok(QualName { segments, span: Span { start: first_span.start, end } })
    }

    fn parse_designator_base(&mut self) -> Result<QualName, ParseError> {
        let (name, span) = self.expect_ident()?;
        Ok(QualName {
            segments: vec![name],
            span,
        })
    }

    fn dotted_ident_run_followed_by_lbrace(&self) -> bool {
        if !matches!(self.peek_kind(), TokenKind::Ident(_)) {
            return false;
        }

        let mut offset = 1;
        loop {
            match (
                self.peek_at(offset).map(|t| &t.kind),
                self.peek_at(offset + 1).map(|t| &t.kind),
            ) {
                (Some(TokenKind::Dot), Some(TokenKind::Ident(_))) => offset += 2,
                _ => break,
            }
        }

        matches!(self.peek_at(offset).map(|t| &t.kind), Some(TokenKind::LBrace))
    }

    fn parse_designator_tail(&mut self, base: QualName) -> Result<Designator, ParseError> {
        let start = base.span;
        let mut selectors = Vec::new();
        let mut end = start.end;
        loop {
            match self.peek_kind() {
                TokenKind::Dot
                    if matches!(
                        self.peek_at(1).map(|t| &t.kind),
                        Some(TokenKind::Ident(_))
                    ) =>
                {
                    self.bump();
                    let (n, ns) = self.expect_ident()?;
                    selectors.push(Selector::Field(n, ns));
                    end = ns.end;
                }
                TokenKind::LBracket => {
                    let s = self.peek().span;
                    self.bump();
                    let mut indices = Vec::new();
                    if !self.at_kind(&TokenKind::RBracket) {
                        loop {
                            indices.push(self.parse_expr()?);
                            if !self.eat_kind(&TokenKind::Comma) {
                                break;
                            }
                        }
                    }
                    let e = self.expect_kind(TokenKind::RBracket, "']'")?;
                    selectors.push(Selector::Index(indices, Span { start: s.start, end: e.end }));
                    end = e.end;
                }
                TokenKind::Caret => {
                    let s = self.peek().span;
                    self.bump();
                    selectors.push(Selector::Deref(s));
                    end = s.end;
                }
                _ => break,
            }
        }
        Ok(Designator { base, selectors, span: Span { start: start.start, end } })
    }

    fn parse_set_constructor(&mut self, type_name: Option<QualName>) -> Result<Expr, ParseError> {
        let start = self.peek().span;
        self.expect_kind(TokenKind::LBrace, "'{'")?;
        let mut elements = Vec::new();
        if !self.at_kind(&TokenKind::RBrace) {
            loop {
                let lo = self.parse_expr()?;
                if self.eat_kind(&TokenKind::DotDot) {
                    let hi = self.parse_expr()?;
                    elements.push(SetElem::Range(lo, hi));
                } else {
                    elements.push(SetElem::Single(lo));
                }
                if !self.eat_kind(&TokenKind::Comma) {
                    break;
                }
            }
        }
        let end = self.expect_kind(TokenKind::RBrace, "'}'")?;
        Ok(Expr::Set {
            type_name,
            elements,
            span: Span { start: start.start, end: end.end },
        })
    }

    // ----- Statements --------------------------------------------------

    fn parse_stmt_seq(&mut self) -> Result<Vec<Stmt>, ParseError> {
        let mut out = Vec::new();
        loop {
            // Skip ADW pragmas between statements.
            while matches!(self.peek_kind(), TokenKind::Pragma(_)) {
                self.bump();
            }
            // Allow empty statements between semicolons.
            if matches!(
                self.peek_kind(),
                TokenKind::Keyword(Keyword::End)
                    | TokenKind::Keyword(Keyword::Else)
                    | TokenKind::Keyword(Keyword::Elsif)
                    | TokenKind::Keyword(Keyword::Until)
                    | TokenKind::Keyword(Keyword::Except)
                    | TokenKind::Keyword(Keyword::Finally)
                    | TokenKind::Pipe
                    | TokenKind::Eof
            ) {
                break;
            }
            let s = self.parse_statement()?;
            out.push(s);
            if !self.eat_kind(&TokenKind::Semicolon) {
                break;
            }
        }
        Ok(out)
    }

    fn parse_statement(&mut self) -> Result<Stmt, ParseError> {
        let start = self.peek().span;
        match self.peek_kind() {
            TokenKind::Keyword(Keyword::If) => self.parse_if(),
            TokenKind::Keyword(Keyword::Case) => self.parse_case(),
            TokenKind::Keyword(Keyword::While) => self.parse_while(),
            TokenKind::Keyword(Keyword::Repeat) => self.parse_repeat(),
            TokenKind::Keyword(Keyword::For) => self.parse_for(),
            TokenKind::Keyword(Keyword::Loop) => self.parse_loop(),
            TokenKind::Keyword(Keyword::With) => self.parse_with(),
            TokenKind::Keyword(Keyword::Exit) => {
                self.bump();
                Ok(Stmt::Exit(start))
            }
            TokenKind::Keyword(Keyword::Return) => {
                self.bump();
                let val = if matches!(
                    self.peek_kind(),
                    TokenKind::Semicolon
                        | TokenKind::Keyword(Keyword::End)
                        | TokenKind::Keyword(Keyword::Else)
                        | TokenKind::Keyword(Keyword::Elsif)
                        | TokenKind::Keyword(Keyword::Until)
                        | TokenKind::Keyword(Keyword::Except)
                        | TokenKind::Keyword(Keyword::Finally)
                        | TokenKind::Pipe
                ) {
                    None
                } else {
                    Some(self.parse_expr()?)
                };
                let end = self.toks[self.pos.saturating_sub(1)].span.end;
                Ok(Stmt::Return(val, Span { start: start.start, end }))
            }
            TokenKind::Keyword(Keyword::Retry) => {
                self.bump();
                Ok(Stmt::Retry(start))
            }
            TokenKind::Ident(name) if name == "FUNC" => {
                // ADW: `FUNC name(args);` discards the function's
                // return value — treated as a procedure-call wrapper.
                self.bump();
                let base = self.parse_designator_base()?;
                let dz = self.parse_designator_tail(base)?;
                let call_start = start;
                if self.at_kind(&TokenKind::LParen) {
                    self.bump();
                    let mut args = Vec::new();
                    if !self.at_kind(&TokenKind::RParen) {
                        loop {
                            args.push(self.parse_expr()?);
                            if !self.eat_kind(&TokenKind::Comma) {
                                break;
                            }
                        }
                    }
                    let end = self.expect_kind(TokenKind::RParen, "')'")?;
                    let call = Expr::Call(
                        Box::new(Expr::Designator(dz)),
                        args,
                        Span { start: call_start.start, end: end.end },
                    );
                    Ok(Stmt::Call(call, Span { start: call_start.start, end: end.end }))
                } else {
                    Ok(Stmt::Call(Expr::Designator(dz), call_start))
                }
            }
            TokenKind::Ident(_) => {
                let base = self.parse_designator_base()?;
                let dz = self.parse_designator_tail(base)?;
                if self.eat_kind(&TokenKind::Assign) {
                    let value = self.parse_expr()?;
                    let end = self.toks[self.pos.saturating_sub(1)].span.end;
                    Ok(Stmt::Assign {
                        target: dz,
                        value,
                        span: Span { start: start.start, end },
                    })
                } else if self.at_kind(&TokenKind::LParen) {
                    // Procedure call as statement.
                    self.bump();
                    let mut args = Vec::new();
                    if !self.at_kind(&TokenKind::RParen) {
                        loop {
                            args.push(self.parse_expr()?);
                            if !self.eat_kind(&TokenKind::Comma) {
                                break;
                            }
                        }
                    }
                    let end = self.expect_kind(TokenKind::RParen, "')'")?;
                    let call = Expr::Call(
                        Box::new(Expr::Designator(dz)),
                        args,
                        Span { start: start.start, end: end.end },
                    );
                    Ok(Stmt::Call(call, Span { start: start.start, end: end.end }))
                } else {
                    // Bare procedure call.
                    Ok(Stmt::Call(Expr::Designator(dz), start))
                }
            }
            _ => self.err(format!("expected statement, found {:?}", self.peek_kind())),
        }
    }

    fn parse_if(&mut self) -> Result<Stmt, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::If)?;
        let mut arms = Vec::new();
        let cond = self.parse_expr()?;
        self.expect_kw(Keyword::Then)?;
        let body = self.parse_stmt_seq()?;
        arms.push((cond, body));
        while self.eat_kw(Keyword::Elsif) {
            let c = self.parse_expr()?;
            self.expect_kw(Keyword::Then)?;
            let b = self.parse_stmt_seq()?;
            arms.push((c, b));
        }
        let else_arm = if self.eat_kw(Keyword::Else) {
            Some(self.parse_stmt_seq()?)
        } else {
            None
        };
        let end = self.expect_kw(Keyword::End)?;
        Ok(Stmt::If {
            arms,
            else_arm,
            span: Span { start: start.start, end: end.end },
        })
    }

    fn parse_case(&mut self) -> Result<Stmt, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::Case)?;
        let scrutinee = self.parse_expr()?;
        self.expect_kw(Keyword::Of)?;
        let mut arms = Vec::new();
        // Leading `|` is permitted in some dialects.
        let _ = self.eat_kind(&TokenKind::Pipe);
        loop {
            if matches!(
                self.peek_kind(),
                TokenKind::Keyword(Keyword::End) | TokenKind::Keyword(Keyword::Else)
            ) {
                break;
            }
            arms.push(self.parse_case_arm()?);
            if !self.eat_kind(&TokenKind::Pipe) {
                break;
            }
        }
        let else_arm = if self.eat_kw(Keyword::Else) {
            Some(self.parse_stmt_seq()?)
        } else {
            None
        };
        let end = self.expect_kw(Keyword::End)?;
        Ok(Stmt::Case {
            scrutinee,
            arms,
            else_arm,
            span: Span { start: start.start, end: end.end },
        })
    }

    fn parse_case_arm(&mut self) -> Result<CaseArm, ParseError> {
        let start = self.peek().span;
        let mut labels = Vec::new();
        loop {
            let lo = self.parse_expr()?;
            if self.eat_kind(&TokenKind::DotDot) {
                let hi = self.parse_expr()?;
                labels.push(CaseLabel::Range(lo, hi));
            } else {
                labels.push(CaseLabel::Single(lo));
            }
            if !self.eat_kind(&TokenKind::Comma) {
                break;
            }
        }
        self.expect_kind(TokenKind::Colon, "':'")?;
        let body = self.parse_stmt_seq()?;
        let end = self.toks[self.pos.saturating_sub(1)].span.end;
        Ok(CaseArm { labels, body, span: Span { start: start.start, end } })
    }

    fn parse_while(&mut self) -> Result<Stmt, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::While)?;
        let cond = self.parse_expr()?;
        self.expect_kw(Keyword::Do)?;
        let body = self.parse_stmt_seq()?;
        let end = self.expect_kw(Keyword::End)?;
        Ok(Stmt::While(cond, body, Span { start: start.start, end: end.end }))
    }

    fn parse_repeat(&mut self) -> Result<Stmt, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::Repeat)?;
        let body = self.parse_stmt_seq()?;
        self.expect_kw(Keyword::Until)?;
        let cond = self.parse_expr()?;
        let end = self.toks[self.pos.saturating_sub(1)].span.end;
        Ok(Stmt::Repeat(body, cond, Span { start: start.start, end }))
    }

    fn parse_for(&mut self) -> Result<Stmt, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::For)?;
        let (var, _) = self.expect_ident()?;
        self.expect_kind(TokenKind::Assign, "':='")?;
        let s = self.parse_expr()?;
        self.expect_kw(Keyword::To)?;
        let e = self.parse_expr()?;
        let step = if self.eat_kw(Keyword::By) { Some(self.parse_expr()?) } else { None };
        self.expect_kw(Keyword::Do)?;
        let body = self.parse_stmt_seq()?;
        let end = self.expect_kw(Keyword::End)?;
        Ok(Stmt::For {
            var,
            start: s,
            end: e,
            step,
            body,
            span: Span { start: start.start, end: end.end },
        })
    }

    fn parse_loop(&mut self) -> Result<Stmt, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::Loop)?;
        let body = self.parse_stmt_seq()?;
        let end = self.expect_kw(Keyword::End)?;
        Ok(Stmt::Loop(body, Span { start: start.start, end: end.end }))
    }

    fn parse_with(&mut self) -> Result<Stmt, ParseError> {
        let start = self.peek().span;
        self.expect_kw(Keyword::With)?;
        let base = self.parse_designator_base()?;
        let dz = self.parse_designator_tail(base)?;
        self.expect_kw(Keyword::Do)?;
        let body = self.parse_stmt_seq()?;
        let end = self.expect_kw(Keyword::End)?;
        Ok(Stmt::With(dz, body, Span { start: start.start, end: end.end }))
    }

    /// Finish a Block by handling EXCEPT and FINALLY trailers, then END.
    fn finish_block(&mut self, stmts: Vec<Stmt>, start: Span) -> Result<Block, ParseError> {
        let mut except = Vec::new();
        let mut finally: Option<Vec<Stmt>> = None;
        if self.eat_kw(Keyword::Except) {
            // EXCEPT [arm-list-with-named-handlers]?
            // Two ISO forms:
            //   EXCEPT … END             (catch-all)
            //   EXCEPT name : stmts | name : stmts END
            // Plus FINALLY can chain.
            if self.peek_eq_or_finally_or_end() {
                except.push(ExceptArm {
                    names: Vec::new(),
                    body: self.parse_stmt_seq()?,
                    span: start,
                });
            } else {
                // We optimistically support both shapes; if no `|` shows up,
                // fall back to catch-all parse.
                let save = self.pos;
                match self.parse_except_arms() {
                    Ok(arms) => except = arms,
                    Err(_) => {
                        self.pos = save;
                        except.push(ExceptArm {
                            names: Vec::new(),
                            body: self.parse_stmt_seq()?,
                            span: start,
                        });
                    }
                }
            }
        }
        if self.eat_kw(Keyword::Finally) {
            finally = Some(self.parse_stmt_seq()?);
        }
        // We leave the END consumption to the caller, since modules and
        // procedures also consume END for the structural delimiter.
        Ok(Block { stmts, except, finally, span: start })
    }

    fn peek_eq_or_finally_or_end(&self) -> bool {
        matches!(
            self.peek_kind(),
            TokenKind::Keyword(Keyword::End) | TokenKind::Keyword(Keyword::Finally)
        )
    }

    fn parse_except_arms(&mut self) -> Result<Vec<ExceptArm>, ParseError> {
        let mut out = Vec::new();
        loop {
            let start = self.peek().span;
            let mut names = Vec::new();
            // Each arm: `name {, name} ':' stmts`.
            if matches!(self.peek_kind(), TokenKind::Ident(_)) {
                let qn = self.parse_qual_name()?;
                names.push(qn);
                while self.eat_kind(&TokenKind::Comma) {
                    let qn = self.parse_qual_name()?;
                    names.push(qn);
                }
                self.expect_kind(TokenKind::Colon, "':'")?;
            }
            let body = self.parse_stmt_seq()?;
            out.push(ExceptArm { names, body, span: start });
            if !self.eat_kind(&TokenKind::Pipe) {
                break;
            }
        }
        Ok(out)
    }
}
