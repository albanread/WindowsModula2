//! Token kinds and the keyword table.

use crate::Span;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LiteralFlavor {
    Default,
    Achar,
    Uchar,
}

impl LiteralFlavor {
    pub fn suffix(self) -> &'static str {
        match self {
            Self::Default => "",
            Self::Achar => "A",
            Self::Uchar => "U",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CharLiteral {
    pub value: char,
    pub flavor: LiteralFlavor,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StringLiteral {
    pub value: String,
    pub flavor: LiteralFlavor,
}

/// One lexical token. The raw spelling, when needed, is recovered from the
/// `span` against the source — keeping `Token` allocation-free for the common
/// punctuation/keyword/number tokens (identifiers carry their name in `kind`).
#[derive(Debug, Clone, PartialEq)]
pub struct Token {
    pub kind: TokenKind,
    pub span: Span,
}

/// The kinds of token NewM2 recognises.
///
/// Keyword tokens carry a [`Keyword`] enum; identifier and literal
/// tokens carry their value. Punctuation tokens are unit variants.
#[derive(Debug, Clone, PartialEq)]
pub enum TokenKind {
    // Identifier or unrecognised name.
    Ident(String),
    // Reserved word.
    Keyword(Keyword),

    // Literals
    Integer(u64),
    Real(f64),
    Char(CharLiteral),
    String(StringLiteral),

    // ADW pragma `<* … *>`. Body is the text between the delimiters.
    Pragma(String),

    // Punctuation and operators
    Plus,
    Minus,
    Star,
    Slash,
    Amp,
    Tilde,
    Equal,
    Hash,
    Less,
    LessEq,
    Greater,
    GreaterEq,
    NotEqual, // <>
    Assign,   // :=
    Dot,
    DotDot,
    Comma,
    Semicolon,
    Colon,
    LParen,
    RParen,
    LBracket,
    RBracket,
    LBrace,
    RBrace,
    Pipe,
    Caret,
    At,

    Eof,
}

/// Reserved words recognised by the lexer.
///
/// Covers PIM-4 + ISO 10514-1 + ISO 10514-2 (OO extension, parsed but
/// deferred per the project plan).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Keyword {
    And,
    Array,
    Begin,
    By,
    Case,
    Const,
    Definition,
    Div,
    Do,
    Else,
    Elsif,
    End,
    Except,
    Exit,
    Export,
    Finally,
    For,
    Forward,
    From,
    Generic,
    If,
    Implementation,
    Import,
    In,
    Loop,
    Mod,
    Module,
    Not,
    Of,
    Or,
    Packedset,
    Pointer,
    Procedure,
    Qualified,
    Record,
    Rem,
    Repeat,
    Retry,
    Return,
    Set,
    Then,
    To,
    Type,
    Until,
    Var,
    While,
    With,
    // ISO 10514-2 (OO) — parsed but currently no sema/codegen.
    Abstract,
    // x86-64 inline assembly body.
    Asm,
    // ADW bitwise operators (operate on integer types).
    Bor,
    Band,
    Bxor,
    Bnot,
    Shl,
    Shr,
}

impl Keyword {
    pub fn from_str(s: &str) -> Option<Self> {
        use Keyword::*;
        Some(match s {
            "AND" => And,
            "ARRAY" => Array,
            "BEGIN" => Begin,
            "BY" => By,
            "CASE" => Case,
            "CONST" => Const,
            "DEFINITION" => Definition,
            "DIV" => Div,
            "DO" => Do,
            "ELSE" => Else,
            "ELSIF" => Elsif,
            "END" => End,
            "EXCEPT" => Except,
            "EXIT" => Exit,
            "EXPORT" => Export,
            "FINALLY" => Finally,
            "FOR" => For,
            "FORWARD" => Forward,
            "FROM" => From,
            "GENERIC" => Generic,
            "IF" => If,
            "IMPLEMENTATION" => Implementation,
            "IMPORT" => Import,
            "IN" => In,
            "LOOP" => Loop,
            "MOD" => Mod,
            "MODULE" => Module,
            "NOT" => Not,
            "OF" => Of,
            "OR" => Or,
            "PACKEDSET" => Packedset,
            "POINTER" => Pointer,
            "PROCEDURE" => Procedure,
            "QUALIFIED" => Qualified,
            "RECORD" => Record,
            "REM" => Rem,
            "REPEAT" => Repeat,
            "RETRY" => Retry,
            "RETURN" => Return,
            "SET" => Set,
            "THEN" => Then,
            "TO" => To,
            "TYPE" => Type,
            "UNTIL" => Until,
            "VAR" => Var,
            "WHILE" => While,
            "WITH" => With,
            "ABSTRACT" => Abstract,
            "ASM" => Asm,
            "BOR" => Bor,
            "BAND" => Band,
            "BXOR" => Bxor,
            "BNOT" => Bnot,
            "SHL" => Shl,
            "SHR" => Shr,
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        use Keyword::*;
        match self {
            And => "AND",
            Array => "ARRAY",
            Begin => "BEGIN",
            By => "BY",
            Case => "CASE",
            Const => "CONST",
            Definition => "DEFINITION",
            Div => "DIV",
            Do => "DO",
            Else => "ELSE",
            Elsif => "ELSIF",
            End => "END",
            Except => "EXCEPT",
            Exit => "EXIT",
            Export => "EXPORT",
            Finally => "FINALLY",
            For => "FOR",
            Forward => "FORWARD",
            From => "FROM",
            Generic => "GENERIC",
            If => "IF",
            Implementation => "IMPLEMENTATION",
            Import => "IMPORT",
            In => "IN",
            Loop => "LOOP",
            Mod => "MOD",
            Module => "MODULE",
            Not => "NOT",
            Of => "OF",
            Or => "OR",
            Packedset => "PACKEDSET",
            Pointer => "POINTER",
            Procedure => "PROCEDURE",
            Qualified => "QUALIFIED",
            Record => "RECORD",
            Rem => "REM",
            Repeat => "REPEAT",
            Retry => "RETRY",
            Return => "RETURN",
            Set => "SET",
            Then => "THEN",
            To => "TO",
            Type => "TYPE",
            Until => "UNTIL",
            Var => "VAR",
            While => "WHILE",
            With => "WITH",
            Abstract => "ABSTRACT",
            Asm => "ASM",
            Bor => "BOR",
            Band => "BAND",
            Bxor => "BXOR",
            Bnot => "BNOT",
            Shl => "SHL",
            Shr => "SHR",
        }
    }
}
