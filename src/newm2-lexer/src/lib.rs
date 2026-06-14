//! NewM2 lexer — the tokenisation stage of the compiler pipeline.
//!
//! Tokenises Modula-2 source as the ADW dialect: PIM 4 + ISO 10514-1
//! + ADW extensions (`%IF` conditional compilation, `<*…*>` pragmas,
//! `[Pass(…),Alters(…)]` procedure attributes).
//!
//! Case-sensitive; M2 keywords are UPPERCASE.

mod preprocess;
mod token;

use serde::{Deserialize, Serialize};

pub use preprocess::{Env, preprocess};
pub use token::{CharLiteral, Keyword, LiteralFlavor, StringLiteral, Token, TokenKind};

/// Format a slice of tokens for the `newm2 dump-tokens` driver
/// command. One token per line: `LINE:COL  KIND  text`.
pub fn format_tokens(toks: &[Token]) -> String {
    let mut out = String::new();
    for tok in toks {
        let kind = match &tok.kind {
            TokenKind::Ident(s) => format!("Ident({s:?})"),
            TokenKind::Keyword(k) => format!("Keyword({})", k.as_str()),
            TokenKind::Integer(n) => format!("Integer({n})"),
            TokenKind::Real(r) => format!("Real({r})"),
            TokenKind::Char(c) => format!("Char({:?}{})", c.value, c.flavor.suffix()),
            TokenKind::String(s) => {
                format!("String({:?}{})", s.value, s.flavor.suffix())
            }
            TokenKind::Pragma(s) => format!("Pragma({s:?})"),
            other => format!("{other:?}"),
        };
        out.push_str(&format!(
            "{:>4}:{:<3}  {}\n",
            tok.span.start.line,
            tok.span.start.column,
            kind
        ));
    }
    out
}

/// A position in a source file (1-based line and column, 0-based byte offset).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourcePosition {
    pub line: usize,
    pub column: usize,
    pub offset: usize,
}

impl SourcePosition {
    pub const START: Self = Self { line: 1, column: 1, offset: 0 };
}

/// Span over a source range.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Span {
    pub start: SourcePosition,
    pub end: SourcePosition,
}

/// A lexer error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LexError {
    pub message: String,
    pub position: SourcePosition,
}

impl std::fmt::Display for LexError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "lex error at line {}, column {}: {}",
            self.position.line, self.position.column, self.message
        )
    }
}

impl std::error::Error for LexError {}

/// Tokenise a source string. Comments, whitespace, and pragmas are
/// either consumed or surfaced as tokens (pragmas surface as `Pragma`
/// tokens; comments are dropped).
///
/// To handle ADW `%IF` conditional compilation, call [`preprocess`]
/// first.
pub fn tokenize(src: &str) -> Result<Vec<Token>, LexError> {
    let mut lexer = Lexer::new(src);
    let mut tokens = Vec::new();
    loop {
        let token = lexer.next_token()?;
        let is_eof = matches!(token.kind, TokenKind::Eof);
        tokens.push(token);
        if is_eof {
            break;
        }
    }
    Ok(tokens)
}

/// Convenience: run the ADW preprocessor over `src` against
/// the target-default environment, then tokenise the result.
pub fn preprocess_and_tokenize(src: &str) -> Result<Vec<Token>, LexError> {
    let env = Env::target_default();
    let preprocessed = preprocess(src, &env)?;
    tokenize(&preprocessed)
}

struct Lexer<'a> {
    src: &'a [u8],
    pos: SourcePosition,
}

impl<'a> Lexer<'a> {
    fn new(src: &'a str) -> Self {
        Self { src: src.as_bytes(), pos: SourcePosition::START }
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.pos.offset).copied()
    }

    fn peek_at(&self, ahead: usize) -> Option<u8> {
        self.src.get(self.pos.offset + ahead).copied()
    }

    fn advance(&mut self) -> Option<u8> {
        let c = self.peek()?;
        self.pos.offset += 1;
        if c == b'\n' {
            self.pos.line += 1;
            self.pos.column = 1;
        } else {
            self.pos.column += 1;
        }
        Some(c)
    }

    fn next_token(&mut self) -> Result<Token, LexError> {
        loop {
            self.skip_trivia()?;
            let start = self.pos;
            let Some(c) = self.peek() else {
                return Ok(Token {
                    kind: TokenKind::Eof,
                    span: Span { start, end: start },
                });
            };

            // Pragma: <* ... *>
            if c == b'<' && self.peek_at(1) == Some(b'*') {
                return self.lex_pragma(start);
            }

            // Identifier / keyword: ASCII letter
            if is_ident_start(c) {
                return Ok(self.lex_ident(start));
            }

            // Number: ASCII digit
            if c.is_ascii_digit() {
                return self.lex_number(start);
            }

            // String literal: " or '
            if c == b'"' || c == b'\'' {
                return self.lex_string(start, c);
            }

            // Operators / punctuation
            return self.lex_punct(start);
        }
    }

    fn skip_trivia(&mut self) -> Result<(), LexError> {
        loop {
            match self.peek() {
                Some(c) if c == b' ' || c == b'\t' || c == b'\r' || c == b'\n' => {
                    self.advance();
                }
                Some(b'(') if self.peek_at(1) == Some(b'*') => {
                    // (* nested comment *)
                    self.skip_block_comment()?;
                }
                Some(b'/') if self.peek_at(1) == Some(b'/') => {
                    // // line comment to end of line
                    while let Some(c) = self.peek() {
                        if c == b'\n' {
                            break;
                        }
                        self.advance();
                    }
                }
                _ => break,
            }
        }
        Ok(())
    }

    fn skip_block_comment(&mut self) -> Result<(), LexError> {
        let start = self.pos;
        // Consume opening (*
        self.advance();
        self.advance();
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
                    self.advance();
                    self.advance();
                    depth += 1;
                }
                Some(b'*') if self.peek_at(1) == Some(b'>') => {
                    // <* … *> pragma close sequence — only meaningful inside
                    // a pragma context, not inside a comment, so consume one byte.
                    self.advance();
                }
                Some(b'*') if self.peek_at(1) == Some(b')') => {
                    self.advance();
                    self.advance();
                    depth -= 1;
                }
                _ => {
                    self.advance();
                }
            }
        }
        Ok(())
    }

    fn lex_pragma(&mut self, start: SourcePosition) -> Result<Token, LexError> {
        // Consume opening <*
        self.advance();
        self.advance();
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
                    self.advance();
                    self.advance();
                    let body = std::str::from_utf8(&self.src[body_start..body_end])
                        .unwrap_or("")
                        .to_string();
                    return Ok(Token {
                        kind: TokenKind::Pragma(body),
                        span: Span { start, end: self.pos },
                    });
                }
                _ => {
                    self.advance();
                }
            }
        }
    }

    fn lex_ident(&mut self, start: SourcePosition) -> Token {
        while let Some(c) = self.peek() {
            if is_ident_cont(c) {
                self.advance();
            } else {
                break;
            }
        }
        let s = std::str::from_utf8(&self.src[start.offset..self.pos.offset]).unwrap();
        let kind = match Keyword::from_str(s) {
            Some(kw) => TokenKind::Keyword(kw),
            // The single allocation per identifier — keywords allocate nothing.
            None => TokenKind::Ident(s.to_string()),
        };
        Token { kind, span: Span { start, end: self.pos } }
    }

    fn lex_number(&mut self, start: SourcePosition) -> Result<Token, LexError> {
        // Modula-2 numeric literal forms:
        //   - decimal integer:        digit { digit }
        //   - hex integer:            digit { hexDigit } 'H'      (must start with 0..9)
        //   - octal integer:          octalDigit { octalDigit } 'B'
        //   - char from octal code:   octalDigit { octalDigit } 'C'
        //   - real:                   digit { digit } '.' digit { digit } [ ScaleFactor ]
        // ScaleFactor = ('E' | 'e') [ '+' | '-' ] digit { digit }
        //
        // Subtlety: `B` and `C` (and their lowercase forms) are both valid
        // hex digits *and* literal-kind suffixes. ADW accepts case-
        // insensitive suffixes (`H/h`, `B/b`, `C/c`) and case-insensitive
        // hex digits (`A-F` / `a-f`). We scan all hex-digit candidates
        // greedily (`0-9`, `A-F`, `a-f`), then examine the trailing byte:
        //   - `H`/`h`              → entire run is hex
        //   - `B`/`b`              → run minus last byte is octal int
        //   - `C`/`c`              → run minus last byte is octal char code
        //   - `.` (not `..`)       → real literal continues
        //   - else                 → plain decimal (no hex letters allowed)
        while let Some(c) = self.peek() {
            if c.is_ascii_digit()
                || (b'A'..=b'F').contains(&c)
                || (b'a'..=b'f').contains(&c)
            {
                self.advance();
            } else {
                break;
            }
        }
        let run_end = self.pos.offset;
        let run = std::str::from_utf8(&self.src[start.offset..run_end]).unwrap();
        let span_end = |s: &Lexer<'_>| Span { start, end: s.pos };
        // Now look at what follows.
        match self.peek() {
            Some(c) if c == b'H' || c == b'h' => {
                self.advance();
                let value = u64::from_str_radix(run, 16).map_err(|e| LexError {
                    message: format!("invalid hex literal '{run}{}': {e}", c as char),
                    position: start,
                })?;
                Ok(Token { kind: TokenKind::Integer(value), span: span_end(self) })
            }
            Some(b'.') if self.peek_at(1) != Some(b'.') => {
                // Real literal. The integer part must have been plain decimal.
                if run.bytes().any(|b| !b.is_ascii_digit()) {
                    return Err(LexError {
                        message: "real literal integer part must be decimal".into(),
                        position: start,
                    });
                }
                self.advance(); // '.'
                while let Some(c) = self.peek() {
                    if c.is_ascii_digit() {
                        self.advance();
                    } else {
                        break;
                    }
                }
                if matches!(self.peek(), Some(b'E') | Some(b'e')) {
                    self.advance();
                    if matches!(self.peek(), Some(b'+') | Some(b'-')) {
                        self.advance();
                    }
                    while let Some(c) = self.peek() {
                        if c.is_ascii_digit() {
                            self.advance();
                        } else {
                            break;
                        }
                    }
                }
                let s = std::str::from_utf8(&self.src[start.offset..self.pos.offset]).unwrap();
                let value = s.parse::<f64>().map_err(|e| LexError {
                    message: format!("invalid real literal '{s}': {e}"),
                    position: start,
                })?;
                Ok(Token { kind: TokenKind::Real(value), span: span_end(self) })
            }
            _ => {
                // No `H/h`, no `.`. The last byte of `run` may itself be
                // a suffix character.
                let last = run.bytes().last().unwrap_or(b'0');
                let suffix_kind = match last {
                    b'B' | b'b' => Some('B'),
                    b'C' | b'c' => Some('C'),
                    b'A' | b'a' => Some('A'),
                    _ => None,
                };
                if let Some(kind) = suffix_kind {
                    let digits = &run[..run.len() - 1];
                    if kind == 'A' {
                        // PIM binary literal: `0101A` = 5, `011111111A` = 255.
                        // `A` is also a hex digit, so only a run of pure 0/1 ending
                        // in `A` is binary; anything else stays a lex error.
                        if digits.is_empty() {
                            return Err(LexError { message: "empty binary literal".into(), position: start });
                        }
                        if !digits.bytes().all(|b| matches!(b, b'0' | b'1')) {
                            return Err(LexError {
                                message: format!("binary literal '{run}' contains a non-binary digit"),
                                position: start,
                            });
                        }
                        let value = u64::from_str_radix(digits, 2).map_err(|e| LexError {
                            message: format!("invalid binary literal '{run}': {e}"),
                            position: start,
                        })?;
                        return Ok(Token {
                            kind: TokenKind::Integer(value),
                            span: span_end(self),
                        });
                    }
                    if !digits.bytes().all(|b| (b'0'..=b'7').contains(&b)) {
                        return Err(LexError {
                            message: format!(
                                "{} literal '{run}' contains a non-octal digit",
                                if kind == 'B' { "octal" } else { "char" }
                            ),
                            position: start,
                        });
                    }
                    if digits.is_empty() {
                        return Err(LexError {
                            message: format!("empty {} literal", if kind == 'B' { "octal" } else { "char" }),
                            position: start,
                        });
                    }
                    if kind == 'B' {
                        let value = u64::from_str_radix(digits, 8).map_err(|e| LexError {
                            message: format!("invalid octal literal '{run}': {e}"),
                            position: start,
                        })?;
                        Ok(Token {
                            kind: TokenKind::Integer(value),
                            span: span_end(self),
                        })
                    } else {
                        let code = u32::from_str_radix(digits, 8).map_err(|e| LexError {
                            message: format!("invalid char literal '{run}': {e}"),
                            position: start,
                        })?;
                        let ch = char::from_u32(code).ok_or_else(|| LexError {
                            message: format!("invalid char code 0o{digits} = {code}"),
                            position: start,
                        })?;
                        Ok(Token {
                            kind: TokenKind::Char(CharLiteral {
                                value: ch,
                                flavor: LiteralFlavor::Default,
                            }),
                            span: span_end(self),
                        })
                    }
                } else if run.bytes().all(|b| b.is_ascii_digit()) {
                    let value = run.parse::<u64>().map_err(|e| LexError {
                        message: format!("invalid integer '{run}': {e}"),
                        position: start,
                    })?;
                    Ok(Token {
                        kind: TokenKind::Integer(value),
                        span: span_end(self),
                    })
                } else {
                    Err(LexError {
                        message: format!(
                            "numeric literal '{run}' has hex digits but no 'H', 'B', or 'C' suffix"
                        ),
                        position: start,
                    })
                }
            }
        }
    }

    fn lex_string(&mut self, start: SourcePosition, quote: u8) -> Result<Token, LexError> {
        // M2 string literals: cannot span lines, terminate at matching quote.
        // Single-char strings using ' or " are both legal (PIM allows both
        // quote characters interchangeably).
        self.advance(); // consume opening quote
        let body_start = self.pos.offset;
        loop {
            match self.peek() {
                None | Some(b'\n') => {
                    return Err(LexError {
                        message: "unterminated string literal".into(),
                        position: start,
                    });
                }
                Some(c) if c == quote => {
                    let body_end = self.pos.offset;
                    self.advance(); // consume closing quote
                    let flavor = match self.peek() {
                        Some(b'U') | Some(b'u') => {
                            self.advance();
                            LiteralFlavor::Uchar
                        }
                        Some(b'A') | Some(b'a') => {
                            self.advance();
                            LiteralFlavor::Achar
                        }
                        _ => LiteralFlavor::Default,
                    };
                    let body = std::str::from_utf8(&self.src[body_start..body_end])
                        .unwrap_or("")
                        .to_string();
                    let kind = if body.chars().count() == 1 {
                        TokenKind::Char(CharLiteral {
                            value: body.chars().next().unwrap(),
                            flavor,
                        })
                    } else {
                        TokenKind::String(StringLiteral { value: body, flavor })
                    };
                    return Ok(Token {
                        kind,
                        span: Span { start, end: self.pos },
                    });
                }
                _ => {
                    self.advance();
                }
            }
        }
    }

    fn lex_punct(&mut self, start: SourcePosition) -> Result<Token, LexError> {
        use TokenKind::*;
        let c = self.peek().unwrap();
        let kind = match c {
            b'+' => {
                self.advance();
                Plus
            }
            b'-' => {
                self.advance();
                Minus
            }
            b'*' => {
                self.advance();
                Star
            }
            b'/' => {
                self.advance();
                Slash
            }
            b'&' => {
                self.advance();
                Amp
            }
            b'~' => {
                self.advance();
                Tilde
            }
            b'=' => {
                self.advance();
                Equal
            }
            b'#' => {
                self.advance();
                Hash
            }
            b'<' => {
                self.advance();
                if self.peek() == Some(b'=') {
                    self.advance();
                    LessEq
                } else if self.peek() == Some(b'>') {
                    self.advance();
                    NotEqual
                } else {
                    Less
                }
            }
            b'>' => {
                self.advance();
                if self.peek() == Some(b'=') {
                    self.advance();
                    GreaterEq
                } else {
                    Greater
                }
            }
            b':' => {
                self.advance();
                if self.peek() == Some(b'=') {
                    self.advance();
                    Assign
                } else {
                    Colon
                }
            }
            b'.' => {
                self.advance();
                if self.peek() == Some(b'.') {
                    self.advance();
                    DotDot
                } else {
                    Dot
                }
            }
            b',' => {
                self.advance();
                Comma
            }
            b';' => {
                self.advance();
                Semicolon
            }
            b'(' => {
                self.advance();
                LParen
            }
            b')' => {
                self.advance();
                RParen
            }
            b'[' => {
                self.advance();
                LBracket
            }
            b']' => {
                self.advance();
                RBracket
            }
            b'{' => {
                self.advance();
                LBrace
            }
            b'}' => {
                self.advance();
                RBrace
            }
            b'|' => {
                self.advance();
                Pipe
            }
            // '!' is used in ADW PropIdl.def as an alternative to '|'
            // in VARIANT record arms.
            b'!' => {
                self.advance();
                Pipe
            }
            b'^' => {
                self.advance();
                Caret
            }
            b'@' => {
                self.advance();
                At
            }
            _ => {
                return Err(LexError {
                    message: format!("unexpected character {:?}", c as char),
                    position: start,
                });
            }
        };
        Ok(Token { kind, span: Span { start, end: self.pos } })
    }
}

fn is_ident_start(c: u8) -> bool {
    c.is_ascii_alphabetic() || c == b'_'
}

fn is_ident_cont(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(src: &str) -> Vec<TokenKind> {
        tokenize(src).unwrap().into_iter().map(|t| t.kind).collect()
    }

    #[test]
    fn source_position_constructs() {
        let p = SourcePosition::START;
        assert_eq!(p.offset, 0);
    }

    #[test]
    fn empty_source() {
        assert_eq!(kinds(""), vec![TokenKind::Eof]);
    }

    #[test]
    fn whitespace_only() {
        assert_eq!(kinds("   \n\t  "), vec![TokenKind::Eof]);
    }

    #[test]
    fn block_comment_skipped() {
        assert_eq!(kinds("(* hello *)"), vec![TokenKind::Eof]);
    }

    #[test]
    fn nested_block_comment_skipped() {
        assert_eq!(kinds("(* outer (* inner *) outer *)"), vec![TokenKind::Eof]);
    }

    #[test]
    fn line_comment_skipped() {
        assert_eq!(kinds("// foo bar"), vec![TokenKind::Eof]);
    }

    #[test]
    fn keyword_recognised() {
        let toks = kinds("BEGIN END");
        assert!(matches!(toks[0], TokenKind::Keyword(Keyword::Begin)));
        assert!(matches!(toks[1], TokenKind::Keyword(Keyword::End)));
    }

    #[test]
    fn ident_case_sensitive() {
        let toks = kinds("begin Begin");
        // Neither is the BEGIN keyword (case-sensitive); both are idents.
        assert!(matches!(toks[0], TokenKind::Ident(_)));
        assert!(matches!(toks[1], TokenKind::Ident(_)));
    }

    #[test]
    fn decimal_integer() {
        assert_eq!(kinds("42"), vec![TokenKind::Integer(42), TokenKind::Eof]);
    }

    #[test]
    fn hex_integer() {
        assert_eq!(kinds("0FFH"), vec![TokenKind::Integer(255), TokenKind::Eof]);
    }

    #[test]
    fn octal_integer() {
        assert_eq!(kinds("17B"), vec![TokenKind::Integer(0o17), TokenKind::Eof]);
    }

    #[test]
    fn octal_char() {
        assert_eq!(
            kinds("52C"),
            vec![
                TokenKind::Char(CharLiteral {
                    value: '\u{2a}',
                    flavor: LiteralFlavor::Default,
                }),
                TokenKind::Eof,
            ]
        );
    }

    #[test]
    fn real_literal() {
        let toks = kinds("3.14");
        match toks[0] {
            TokenKind::Real(v) => assert!((v - 3.14).abs() < 1e-9),
            _ => panic!("expected Real, got {:?}", toks[0]),
        }
    }

    #[test]
    fn real_with_exponent() {
        let toks = kinds("1.5e-3");
        match toks[0] {
            TokenKind::Real(v) => assert!((v - 1.5e-3).abs() < 1e-12),
            _ => panic!("expected Real, got {:?}", toks[0]),
        }
    }

    #[test]
    fn string_literal_double_quoted() {
        let toks = kinds("\"hello\"");
        assert!(matches!(&toks[0], TokenKind::String(s) if s.value == "hello" && s.flavor == LiteralFlavor::Default));
    }

    #[test]
    fn string_literal_single_quoted() {
        let toks = kinds("'world'");
        assert!(matches!(&toks[0], TokenKind::String(s) if s.value == "world" && s.flavor == LiteralFlavor::Default));
    }

    #[test]
    fn single_char_quoted_is_char() {
        let toks = kinds("'A'");
        assert!(matches!(&toks[0], TokenKind::Char(c) if c.value == 'A' && c.flavor == LiteralFlavor::Default));
    }

    #[test]
    fn string_literal_u_suffix_preserves_flavor() {
        let toks = kinds("\"hello\"U");
        assert!(matches!(&toks[0], TokenKind::String(s) if s.value == "hello" && s.flavor == LiteralFlavor::Uchar));
    }

    #[test]
    fn char_literal_a_suffix_preserves_flavor() {
        let toks = kinds("'A'A");
        assert!(matches!(&toks[0], TokenKind::Char(c) if c.value == 'A' && c.flavor == LiteralFlavor::Achar));
    }

    #[test]
    fn pragma_lexed_as_pragma() {
        let toks = kinds("<*/EXPORTALL*>");
        assert!(matches!(&toks[0], TokenKind::Pragma(body) if body == "/EXPORTALL"));
    }

    #[test]
    fn dotdot_range() {
        assert_eq!(kinds("..").len(), 2); // DotDot + Eof
        assert_eq!(kinds("..")[0], TokenKind::DotDot);
    }

    #[test]
    fn assign_operator() {
        assert_eq!(kinds(":=")[0], TokenKind::Assign);
    }

    #[test]
    fn not_equal_via_angle_bracket() {
        assert_eq!(kinds("<>")[0], TokenKind::NotEqual);
    }

    #[test]
    fn not_equal_via_hash() {
        assert_eq!(kinds("#")[0], TokenKind::Hash);
    }

    #[test]
    fn definition_module_header() {
        let toks = kinds("DEFINITION MODULE Foo;");
        assert!(matches!(toks[0], TokenKind::Keyword(Keyword::Definition)));
        assert!(matches!(toks[1], TokenKind::Keyword(Keyword::Module)));
        assert!(matches!(&toks[2], TokenKind::Ident(s) if s == "Foo"));
        assert!(matches!(toks[3], TokenKind::Semicolon));
    }

    #[test]
    fn spans_track_positions() {
        let toks = tokenize("AB CD").unwrap();
        assert_eq!(toks[0].span.start.column, 1);
        assert_eq!(toks[0].span.end.column, 3);
        assert_eq!(toks[1].span.start.column, 4);
    }
}
