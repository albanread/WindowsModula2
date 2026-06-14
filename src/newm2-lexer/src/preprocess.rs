//! ADW conditional compilation: `%IF`/`%ELSIF`/`%ELSE`/`%END` with
//! `%AND`/`%OR`/`%NOT` operators over a fixed table of predefined
//! symbols.
//!
//! The preprocessor runs over raw source before lexing and returns a
//! new string where directives have been blanked and inactive branches
//! replaced byte-for-byte with whitespace, preserving line numbers and
//! column positions so downstream diagnostics keep their meaning.
//!
//! Directives can appear anywhere — top-level, inside parameter lists,
//! inside square-bracket procedure attribute lists. The preprocessor
//! is text-level and oblivious to syntactic context.

use crate::{LexError, SourcePosition};
use std::collections::HashMap;

/// The environment of predefined symbols.
#[derive(Debug, Clone)]
pub struct Env {
    pub symbols: HashMap<String, String>,
}

impl Env {
    /// Explicit ADW Win64 Unicode environment:
    /// AMD64 / Bits64 / WordSize=64 / Windows / Unicode,
    /// no IA32 / no Bits32 / no UNIX / no MAC,
    /// PROTECT mode, ALIGN8, no inline FPU, no DLL.
    pub fn adw_win64_unicode() -> Self {
        let mut m = HashMap::new();
        // Bitness
        m.insert("AMD64".into(), "true".into());
        m.insert("IA32".into(), "false".into());
        m.insert("Bits64".into(), "true".into());
        m.insert("Bits32".into(), "false".into());
        m.insert("WordSize".into(), "64".into());
        // OS
        m.insert("WINDOWS".into(), "true".into());
        m.insert("Windows".into(), "true".into());
        m.insert("UNIX".into(), "false".into());
        m.insert("MAC".into(), "false".into());
        // Modes
        m.insert("UNICODE".into(), "true".into());
        m.insert("DLL".into(), "false".into());
        m.insert("PROTECT".into(), "true".into());
        m.insert("ALIGN8".into(), "true".into());
        m.insert("InlineFpp".into(), "false".into());
        Env { symbols: m }
    }

    /// Default environment for NewM2's target.
    pub fn target_default() -> Self {
        Self::adw_win64_unicode()
    }

    pub fn empty() -> Self {
        Env { symbols: HashMap::new() }
    }

    pub fn with(mut self, name: &str, value: bool) -> Self {
        self.define_bool(name, value);
        self
    }

    pub fn with_value(mut self, name: &str, value: impl Into<String>) -> Self {
        self.define_value(name, value);
        self
    }

    pub fn define_bool(&mut self, name: &str, value: bool) {
        self.define_value(name, if value { "true" } else { "false" });
    }

    pub fn define_value(&mut self, name: &str, value: impl Into<String>) {
        self.symbols.insert(name.into(), value.into());
    }

    fn lookup_value(&self, name: &str) -> Option<&str> {
        self.symbols.get(name).map(String::as_str)
    }

    fn lookup_bool(&self, name: &str) -> bool {
        self.lookup_value(name).is_some_and(truthy_value)
    }

    fn lookup(&self, name: &str) -> bool {
        // Unknown identifiers default to FALSE — same convention ADW
        // documents. Code that asks `%IF FOO` where FOO is never defined
        // takes the FALSE branch.
        self.lookup_bool(name)
    }
}

fn truthy_value(value: &str) -> bool {
    !matches!(value, "" | "0") && !value.eq_ignore_ascii_case("false")
}

/// Run the preprocessor over `src`. Result has the same length and
/// line layout as `src`; bytes belonging to dead branches and directive
/// keywords are replaced with whitespace.
pub fn preprocess(src: &str, env: &Env) -> Result<String, LexError> {
    // Fast path: with no `%` byte anywhere, there is no directive to act on, so
    // the preprocessor would copy `src` through verbatim. Skip the byte-by-byte
    // pass, the `Env` clone, and the UTF-8 re-validation entirely. The large
    // generated Win32 `*_types.def` modules — most of the bytes in a compile —
    // are all directive-free, so this elides a whole source-sized pass for them.
    if !src.as_bytes().contains(&b'%') {
        return Ok(src.to_owned());
    }
    let mut p = Preproc::new(src.as_bytes(), env);
    p.run()?;
    Ok(String::from_utf8(p.out).expect("preprocessor never emits invalid UTF-8"))
}

/// State for one `%IF ... %END` block.
#[derive(Debug, Clone, Copy)]
struct BranchState {
    /// Whether the enclosing context is itself emitting source.
    parent_active: bool,
    /// Whether any branch in this `%IF` chain has been taken so far.
    /// Once true, no later `%ELSIF` or `%ELSE` branch may activate.
    any_taken: bool,
    /// Whether the current branch should emit source.
    current_take: bool,
}

struct Preproc<'a> {
    src: &'a [u8],
    out: Vec<u8>,
    pos: SourcePosition,
    env: Env,
    /// Stack of `%IF` branch states, innermost on top.
    stack: Vec<BranchState>,
}

impl<'a> Preproc<'a> {
    fn new(src: &'a [u8], env: &'a Env) -> Self {
        Self {
            src,
            out: Vec::with_capacity(src.len()),
            pos: SourcePosition::START,
            env: env.clone(),
            stack: Vec::new(),
        }
    }

    /// True when every level above us is emitting.
    fn active(&self) -> bool {
        self.stack.iter().all(|s| s.current_take)
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos.offset).copied()
    }

    fn peek_at(&self, ahead: usize) -> Option<u8> {
        self.src.get(self.pos.offset + ahead).copied()
    }

    fn advance(&mut self) {
        if let Some(c) = self.peek() {
            self.pos.offset += 1;
            if c == b'\n' {
                self.pos.line += 1;
                self.pos.column = 1;
            } else {
                self.pos.column += 1;
            }
        }
    }

    /// Emit a byte, mapping it to a space (or newline) if we're in a
    /// dead branch so that downstream positions remain valid.
    fn emit_byte(&mut self, c: u8) {
        if self.active() {
            self.out.push(c);
        } else if c == b'\n' {
            self.out.push(b'\n');
        } else {
            self.out.push(b' ');
        }
        self.advance();
    }

    /// Erase one byte unconditionally (used for directive characters).
    fn erase_byte(&mut self) {
        if let Some(c) = self.peek() {
            if c == b'\n' {
                self.out.push(b'\n');
            } else {
                self.out.push(b' ');
            }
            self.advance();
        }
    }

    fn run(&mut self) -> Result<(), LexError> {
        while let Some(c) = self.peek() {
            // Skip block comments verbatim so a `%IF` inside `(* … *)`
            // is not interpreted as a directive.
            if c == b'(' && self.peek_at(1) == Some(b'*') {
                self.copy_block_comment()?;
                continue;
            }
            // Skip line comments verbatim.
            if c == b'/' && self.peek_at(1) == Some(b'/') {
                while let Some(c2) = self.peek() {
                    self.emit_byte(c2);
                    if c2 == b'\n' {
                        break;
                    }
                }
                continue;
            }
            // Skip string literals verbatim.
            if c == b'"' || c == b'\'' {
                self.copy_string(c)?;
                continue;
            }
            // Copy pragmas verbatim, but let `VERSION:` pragmas update
            // the active file-local preprocessor environment.
            if c == b'<' && self.peek_at(1) == Some(b'*') {
                self.copy_pragma()?;
                continue;
            }
            // Directive?
            if c == b'%' {
                self.handle_directive()?;
                continue;
            }
            self.emit_byte(c);
        }
        if !self.stack.is_empty() {
            return Err(LexError {
                message: "unterminated %IF directive (missing %END)".into(),
                position: self.pos,
            });
        }
        Ok(())
    }

    fn copy_block_comment(&mut self) -> Result<(), LexError> {
        let start = self.pos;
        self.emit_byte(b'(');
        self.emit_byte(b'*');
        let mut depth = 1usize;
        while depth > 0 {
            match self.peek() {
                None => {
                    return Err(LexError {
                        message: "unterminated block comment".into(),
                        position: start,
                    });
                }
                Some(b'(') if self.peek_at(1) == Some(b'*') => {
                    self.emit_byte(b'(');
                    self.emit_byte(b'*');
                    depth += 1;
                }
                Some(b'<') if self.peek_at(1) == Some(b'*') => {
                    // A `<*` inside a block comment is a pragma only when its
                    // `*>` close precedes the comment's own `*)` close; otherwise
                    // it is literal comment text (e.g. `(* ... (* <* *) ... *)`),
                    // which is ignored. Without this, copy_pragma scans past the
                    // `*)` looking for a `*>` and consumes to EOF.
                    if self.pragma_closes_within_comment() {
                        self.copy_pragma()?;
                    } else {
                        self.emit_byte(b'<');
                    }
                }
                Some(b'*') if self.peek_at(1) == Some(b')') => {
                    self.emit_byte(b'*');
                    self.emit_byte(b')');
                    depth -= 1;
                }
                Some(c) => {
                    self.emit_byte(c);
                }
            }
        }
        Ok(())
    }

    fn copy_string(&mut self, quote: u8) -> Result<(), LexError> {
        let start = self.pos;
        self.emit_byte(quote);
        loop {
            match self.peek() {
                None | Some(b'\n') => {
                    return Err(LexError {
                        message: "unterminated string literal".into(),
                        position: start,
                    });
                }
                Some(c) if c == quote => {
                    self.emit_byte(c);
                    return Ok(());
                }
                Some(c) => {
                    self.emit_byte(c);
                }
            }
        }
    }

    /// At a `<*` inside a block comment: is this a real pragma (its `*>` close
    /// occurs before the comment's matching `*)`) or just literal comment text?
    fn pragma_closes_within_comment(&self) -> bool {
        let mut i = self.pos.offset + 2; // skip `<*`
        while i + 1 < self.src.len() {
            match (self.src[i], self.src[i + 1]) {
                (b'*', b'>') => return true,
                (b'*', b')') => return false,
                _ => i += 1,
            }
        }
        false
    }

    fn copy_pragma(&mut self) -> Result<(), LexError> {
        let start = self.pos;
        self.emit_byte(b'<');
        self.emit_byte(b'*');
        let body_start = self.pos.offset;
        loop {
            match self.peek() {
                None => {
                    return Err(LexError {
                        message: "unterminated pragma".into(),
                        position: start,
                    });
                }
                Some(b'*') if self.peek_at(1) == Some(b'>') => {
                    let body_end = self.pos.offset;
                    if self.active() {
                        self.apply_pragma_body(&self.src[body_start..body_end]);
                    }
                    self.emit_byte(b'*');
                    self.emit_byte(b'>');
                    return Ok(());
                }
                Some(c) => {
                    self.emit_byte(c);
                }
            }
        }
    }

    fn apply_pragma_body(&mut self, body: &[u8]) {
        let Ok(text) = std::str::from_utf8(body) else {
            return;
        };
        let trimmed = text.trim();
        let Some(rest) = trimmed.strip_prefix('/') else {
            return;
        };
        if let Some(names) = rest
            .strip_prefix("VERSION:")
            .or_else(|| rest.strip_prefix("VALIDVERSION:"))
            .or_else(|| rest.strip_prefix("VALIDVER:"))
        {
            if rest.starts_with("VERSION:") {
                self.apply_version_names(names);
            }
        }
    }

    fn apply_version_names(&mut self, names: &str) {
        for name in names.split(',') {
            let name = name.trim();
            if !name.is_empty() {
                self.env.define_bool(name, true);
            }
        }
    }

    /// At a `%` byte. Decide whether it's a directive (`%IF`, etc.) or
    /// just stray text. ADW reserves `%` as the directive prefix.
    fn handle_directive(&mut self) -> Result<(), LexError> {
        let start = self.pos;
        // Erase the '%'.
        self.erase_byte();
        // Read the directive keyword.
        let kw_start = self.pos.offset;
        while let Some(c) = self.peek() {
            if c.is_ascii_alphabetic() {
                self.erase_byte();
            } else {
                break;
            }
        }
        let kw =
            std::str::from_utf8(&self.src[kw_start..self.pos.offset]).unwrap_or("").to_string();
        match kw.as_str() {
            "IF" => {
                let cond = self.read_expr_then()?;
                let parent_active = self.active();
                let take = parent_active && cond;
                self.stack.push(BranchState {
                    parent_active,
                    any_taken: take,
                    current_take: take,
                });
            }
            "ELSIF" => {
                if self.stack.is_empty() {
                    return Err(LexError {
                        message: "%ELSIF outside of %IF".into(),
                        position: start,
                    });
                }
                let cond = self.read_expr_then()?;
                let top = self.stack.last_mut().unwrap();
                let take = top.parent_active && !top.any_taken && cond;
                top.current_take = take;
                top.any_taken = top.any_taken || take;
            }
            "ELSE" => {
                if self.stack.is_empty() {
                    return Err(LexError {
                        message: "%ELSE outside of %IF".into(),
                        position: start,
                    });
                }
                let top = self.stack.last_mut().unwrap();
                let take = top.parent_active && !top.any_taken;
                top.current_take = take;
                top.any_taken = top.any_taken || take;
            }
            "END" => {
                if self.stack.is_empty() {
                    return Err(LexError {
                        message: "%END outside of %IF".into(),
                        position: start,
                    });
                }
                self.stack.pop();
            }
            other => {
                return Err(LexError {
                    message: format!("unknown directive %{other}"),
                    position: start,
                });
            }
        }
        Ok(())
    }

    /// Read a directive expression up to `%THEN` (consuming `%THEN`).
    /// Returns the boolean value.
    fn read_expr_then(&mut self) -> Result<bool, LexError> {
        // Collect characters until we hit `%THEN`. Track parentheses so a
        // `%` inside grouping doesn't confuse us — though directives don't
        // nest inside their own expressions.
        let start = self.pos;
        let mut buf = String::new();
        loop {
            match self.peek() {
                None => {
                    return Err(LexError {
                        message: "unterminated %IF expression (missing %THEN)".into(),
                        position: start,
                    });
                }
                Some(b'%') => {
                    // Could be %THEN, %AND, %OR, %NOT.
                    let kw_start = self.pos.offset + 1;
                    let mut probe = self.pos.offset + 1;
                    while probe < self.src.len() && self.src[probe].is_ascii_alphabetic() {
                        probe += 1;
                    }
                    let kw = std::str::from_utf8(&self.src[kw_start..probe]).unwrap_or("");
                    if kw == "THEN" {
                        // Erase `%THEN` and stop.
                        for _ in 0..(probe - self.pos.offset) {
                            self.erase_byte();
                        }
                        return self.eval_expr(&buf, start);
                    } else {
                        // Translate into a buffer token. We treat
                        // %AND/%OR/%NOT as &&/||/!.
                        let replacement = match kw {
                            "AND" => " && ",
                            "OR" => " || ",
                            "NOT" => " ! ",
                            other => {
                                return Err(LexError {
                                    message: format!(
                                        "unexpected %{other} in %IF expression"
                                    ),
                                    position: self.pos,
                                });
                            }
                        };
                        buf.push_str(replacement);
                        for _ in 0..(probe - self.pos.offset) {
                            self.erase_byte();
                        }
                    }
                }
                Some(c) => {
                    buf.push(c as char);
                    self.erase_byte();
                }
            }
        }
    }

    fn eval_expr(&self, src: &str, start: SourcePosition) -> Result<bool, LexError> {
        let mut parser = ExprParser::new(src, &self.env);
        let value = parser.parse_expr().map_err(|m| LexError { message: m, position: start })?;
        parser.expect_eof().map_err(|m| LexError { message: m, position: start })?;
        Ok(value)
    }
}

/// Minimal recursive-descent evaluator for directive expressions.
///
/// Grammar (after `%AND`/`%OR`/`%NOT` → `&&`/`||`/`!` translation):
///   expr   := or
///   or     := and { '||' and }
///   and    := unary { '&&' unary }
///   unary  := '!' unary | primary
///   primary := comparison | '(' expr ')'
///   comparison := value [ ('=' | '#') value ]
///   value := identifier | string | number
struct ExprParser<'a> {
    src: &'a [u8],
    pos: usize,
    env: &'a Env,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ExprValue {
    Bool(bool),
    Ident(String),
    Text(String),
}

impl ExprValue {
    fn as_bool(&self) -> bool {
        match self {
            ExprValue::Bool(value) => *value,
            ExprValue::Ident(name) => truthy_value(name),
            ExprValue::Text(value) => truthy_value(value),
        }
    }

    fn as_compare_text(&self, env: &Env) -> String {
        match self {
            ExprValue::Bool(value) => {
                if *value { "true".into() } else { "false".into() }
            }
            ExprValue::Ident(name) => env.lookup_value(name).unwrap_or(name).to_string(),
            ExprValue::Text(value) => value.clone(),
        }
    }
}

impl<'a> ExprParser<'a> {
    fn new(src: &'a str, env: &'a Env) -> Self {
        Self { src: src.as_bytes(), pos: 0, env }
    }

    fn skip_ws(&mut self) {
        while let Some(c) = self.peek() {
            if c == b' ' || c == b'\t' || c == b'\r' || c == b'\n' {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos).copied()
    }

    fn bump(&mut self) -> Option<u8> {
        let c = self.peek();
        if c.is_some() {
            self.pos += 1;
        }
        c
    }

    fn matches(&mut self, s: &[u8]) -> bool {
        if self.src[self.pos..].starts_with(s) {
            self.pos += s.len();
            true
        } else {
            false
        }
    }

    fn parse_expr(&mut self) -> Result<bool, String> {
        self.parse_or()
    }

    fn parse_or(&mut self) -> Result<bool, String> {
        let mut left = self.parse_and()?;
        loop {
            self.skip_ws();
            if self.matches(b"||") {
                let right = self.parse_and()?;
                left = left || right;
            } else {
                return Ok(left);
            }
        }
    }

    fn parse_and(&mut self) -> Result<bool, String> {
        let mut left = self.parse_unary()?;
        loop {
            self.skip_ws();
            if self.matches(b"&&") {
                let right = self.parse_unary()?;
                left = left && right;
            } else {
                return Ok(left);
            }
        }
    }

    fn parse_unary(&mut self) -> Result<bool, String> {
        self.skip_ws();
        if self.matches(b"!") {
            let v = self.parse_unary()?;
            Ok(!v)
        } else {
            self.parse_primary()
        }
    }

    fn parse_primary(&mut self) -> Result<bool, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'(') => {
                self.bump();
                let v = self.parse_expr()?;
                self.skip_ws();
                if self.bump() != Some(b')') {
                    return Err("expected ')' in directive expression".into());
                }
                Ok(v)
            }
            Some(_) => self.parse_comparison().map(|value| value.as_bool()),
            None => Err("unexpected end of directive expression".into()),
        }
    }

    fn parse_comparison(&mut self) -> Result<ExprValue, String> {
        let left = self.parse_value()?;
        self.skip_ws();
        if self.matches(b"=") {
            let right = self.parse_value()?;
            return Ok(ExprValue::Bool(
                left.as_compare_text(self.env) == right.as_compare_text(self.env),
            ));
        }
        if self.matches(b"#") {
            let right = self.parse_value()?;
            return Ok(ExprValue::Bool(
                left.as_compare_text(self.env) != right.as_compare_text(self.env),
            ));
        }
        if let ExprValue::Ident(name) = left {
            return Ok(ExprValue::Bool(self.env.lookup(&name)));
        }
        Ok(left)
    }

    fn parse_value(&mut self) -> Result<ExprValue, String> {
        self.skip_ws();
        match self.peek() {
            Some(c) if c.is_ascii_alphabetic() || c == b'_' => self.parse_identifier_value(),
            Some(c) if c.is_ascii_digit() => self.parse_number_value(),
            Some(b'\'') | Some(b'"') => self.parse_string_value(),
            Some(c) => Err(format!("unexpected character {:?} in directive expression", c as char)),
            None => Err("unexpected end of directive expression".into()),
        }
    }

    fn parse_identifier_value(&mut self) -> Result<ExprValue, String> {
        let start = self.pos;
        while let Some(c2) = self.peek() {
            if c2.is_ascii_alphanumeric() || c2 == b'_' {
                self.pos += 1;
            } else {
                break;
            }
        }
        let name = std::str::from_utf8(&self.src[start..self.pos]).unwrap();
        Ok(ExprValue::Ident(name.to_string()))
    }

    fn parse_number_value(&mut self) -> Result<ExprValue, String> {
        let start = self.pos;
        while let Some(c) = self.peek() {
            if c.is_ascii_alphanumeric() || c == b'_' {
                self.pos += 1;
            } else {
                break;
            }
        }
        let value = std::str::from_utf8(&self.src[start..self.pos]).unwrap();
        Ok(ExprValue::Text(value.to_string()))
    }

    fn parse_string_value(&mut self) -> Result<ExprValue, String> {
        let quote = self.bump().ok_or_else(|| "unexpected end of directive expression".to_string())?;
        let start = self.pos;
        while let Some(c) = self.peek() {
            if c == quote {
                let value = std::str::from_utf8(&self.src[start..self.pos]).unwrap();
                self.pos += 1;
                return Ok(ExprValue::Text(value.to_string()));
            }
            self.pos += 1;
        }
        Err("unterminated string literal in directive expression".into())
    }

    fn expect_eof(&mut self) -> Result<(), String> {
        self.skip_ws();
        if self.pos == self.src.len() {
            Ok(())
        } else {
            Err(format!("trailing garbage in directive expression: {:?}", &self.src[self.pos..]))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pp(src: &str) -> String {
        preprocess(src, &Env::target_default()).unwrap()
    }

    #[test]
    fn no_directives_passthrough() {
        let s = "BEGIN x := 1; END";
        assert_eq!(pp(s), s);
    }

    #[test]
    fn if_amd64_true_keeps_branch() {
        let s = "%IF AMD64 %THEN keep %END";
        let out = pp(s);
        assert!(out.contains("keep"), "expected to keep AMD64 branch, got: {out:?}");
    }

    #[test]
    fn if_ia32_false_drops_branch() {
        let s = "%IF IA32 %THEN drop %END";
        let out = pp(s);
        assert!(!out.contains("drop"), "expected to drop IA32 branch, got: {out:?}");
    }

    #[test]
    fn else_branch_taken_when_if_false() {
        let s = "%IF IA32 %THEN drop %ELSE keep %END";
        let out = pp(s);
        assert!(!out.contains("drop"));
        assert!(out.contains("keep"));
    }

    #[test]
    fn elsif_chain_first_match_wins() {
        let s = "%IF IA32 %THEN A %ELSIF AMD64 %THEN B %ELSE C %END";
        let out = pp(s);
        assert!(!out.contains("A"));
        assert!(out.contains("B"));
        assert!(!out.contains("C"));
    }

    #[test]
    fn nested_if() {
        let s = "%IF Bits64 %THEN outer %IF AMD64 %THEN inner %END %END";
        let out = pp(s);
        assert!(out.contains("outer"));
        assert!(out.contains("inner"));
    }

    #[test]
    fn not_operator() {
        let s = "%IF %NOT IA32 %THEN keep %END";
        let out = pp(s);
        assert!(out.contains("keep"));
    }

    #[test]
    fn parens_and_operators() {
        let s = "%IF (%NOT IA32) %AND AMD64 %THEN keep %END";
        let out = pp(s);
        assert!(out.contains("keep"));
    }

    #[test]
    fn line_count_preserved() {
        let s = "A\n%IF IA32 %THEN\ndrop\n%END\nB";
        let out = pp(s);
        // Same number of \n bytes.
        assert_eq!(out.bytes().filter(|&b| b == b'\n').count(), s.bytes().filter(|&b| b == b'\n').count());
    }

    #[test]
    fn directive_inside_brackets() {
        // Real ADW pattern: %IF inside procedure-attribute bracket list.
        let s = "[Pass, %IF IA32 %THEN Alters %ELSE Returns %END]";
        let out = pp(s);
        assert!(!out.contains("Alters"));
        assert!(out.contains("Returns"));
    }

    #[test]
    fn custom_value_equality_from_env() {
        let s = "%IF Flavor = debug %THEN keep %END";
        let env = Env::empty().with_value("Flavor", "debug");
        let out = preprocess(s, &env).unwrap();
        assert!(out.contains("keep"));
    }

    #[test]
    fn custom_value_inequality_from_env() {
        let s = "%IF Flavor # release %THEN keep %END";
        let env = Env::empty().with_value("Flavor", "debug");
        let out = preprocess(s, &env).unwrap();
        assert!(out.contains("keep"));
    }

    #[test]
    fn custom_numeric_value_equality() {
        let s = "%IF WordSize = 64 %THEN keep %END";
        let env = Env::empty().with_value("WordSize", "64");
        let out = preprocess(s, &env).unwrap();
        assert!(out.contains("keep"));
    }

    #[test]
    fn bare_identifier_uses_truthy_value() {
        let s = "%IF Feature %THEN keep %END";
        let env = Env::empty().with_value("Feature", "enabled");
        let out = preprocess(s, &env).unwrap();
        assert!(out.contains("keep"));
    }

    #[test]
    fn version_pragma_enables_later_if() {
        let s = "<*/VERSION:FeatureX*>\n%IF FeatureX %THEN keep %END";
        let out = preprocess(s, &Env::empty()).unwrap();
        assert!(out.contains("keep"));
    }

    #[test]
    fn commented_version_pragma_enables_later_if() {
        let s = "(*<*/VERSION:FeatureX*>*)\n%IF FeatureX %THEN keep %END";
        let out = preprocess(s, &Env::empty()).unwrap();
        assert!(out.contains("keep"));
    }

    #[test]
    fn version_pragma_in_dead_branch_does_not_leak() {
        let s = "%IF Missing %THEN <*/VERSION:FeatureX*> %END\n%IF FeatureX %THEN keep %END";
        let out = preprocess(s, &Env::empty()).unwrap();
        assert!(!out.contains("keep"));
    }

    #[test]
    fn directive_inside_comment_ignored() {
        let s = "(* %IF IA32 %THEN should-not-fire %END *)";
        // Should not error and should preserve the comment.
        let out = pp(s);
        assert!(out.contains("%IF"));
    }

    #[test]
    fn unterminated_if_errors() {
        assert!(preprocess("%IF AMD64 %THEN keep", &Env::target_default()).is_err());
    }

    #[test]
    fn adw_win64_unicode_has_expected_symbols() {
        let env = Env::adw_win64_unicode();
        assert_eq!(env.lookup_value("AMD64"), Some("true"));
        assert_eq!(env.lookup_value("Bits64"), Some("true"));
        assert_eq!(env.lookup_value("UNICODE"), Some("true"));
        assert_eq!(env.lookup_value("WordSize"), Some("64"));
        assert_eq!(env.lookup_value("MAC"), Some("false"));
    }
}
