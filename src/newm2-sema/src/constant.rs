//! Compile-time constant values and constant-expression evaluator.
//!
//! M2 constants are formed from literals, named constants, arithmetic,
//! comparison, boolean, and bitset operations.  The evaluator is used
//! during type formation (subrange bounds, array dimensions, SET
//! cardinality limits) and constant-declaration checking.
//!
//! Errors are returned as `EvalError`; the caller wraps them into
//! `Diagnostic` entries.

use newm2_lexer::Span;
use newm2_parser::ast::{BinaryOp, Expr, Selector, UnaryOp};

/// A compile-time constant value.
#[derive(Debug, Clone, PartialEq)]
pub enum ConstValue {
    Int(i128),
    Real(f64),
    Bool(bool),
    Char(char),
    Str(String),
    /// A BITSET (set of ordinal values).  We store the members as a
    /// sorted vec for correctness; operations mirror the M2 semantics.
    Set(Vec<i128>),
    /// The `NIL` literal.
    Nil,
    /// A procedure value constant (procedure alias or procedure pointer).
    FuncRef(String),
    /// A (LONG)COMPLEX value — `CMPLX(re, im)` evaluated at compile time.
    Complex(f64, f64),
    /// A RECORD or ARRAY structured-constructor constant — `T{a, b, …}` —
    /// holding its field/element values in declaration order.
    Aggregate(Vec<ConstValue>),
}

impl ConstValue {
    pub fn type_name(&self) -> &'static str {
        match self {
            ConstValue::Int(_) => "integer",
            ConstValue::Real(_) => "real",
            ConstValue::Bool(_) => "BOOLEAN",
            ConstValue::Char(_) => "CHAR",
            ConstValue::Str(_) => "string",
            ConstValue::Set(_) => "set",
            ConstValue::Nil => "NIL",
            ConstValue::FuncRef(_) => "procedure",
            ConstValue::Complex(..) => "complex",
            ConstValue::Aggregate(_) => "aggregate",
        }
    }

    /// Return the integer value if this is an Int or a Bool (FALSE=0,
    /// TRUE=1) or a Char (ordinal value).
    pub fn as_int(&self) -> Option<i128> {
        match self {
            ConstValue::Int(n) => Some(*n),
            ConstValue::Bool(b) => Some(*b as i128),
            ConstValue::Char(c) => Some(*c as i128),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct EvalError {
    pub message: String,
    pub span: Span,
}

impl EvalError {
    fn new(span: Span, msg: impl Into<String>) -> Self {
        EvalError { message: msg.into(), span }
    }
}

/// Lookup function: given a name (possibly qualified as `"M.C"`), return
/// the constant value if the name resolves to a constant in the caller's
/// scope.  Returns `None` if the name is not constant (type, var, etc.).
pub type ConstLookup<'a> = &'a dyn Fn(&str) -> Option<ConstValue>;

/// Synthetic `consts`-map key for a type-dependent builtin (`MAX`, `MIN`,
/// `SIZE`, `TSIZE`) applied to a named type. `constant.rs` has no type system,
/// so the analyze layer — which does — pre-computes the value and inserts it
/// under this key; the evaluator below looks it up. The `\u{1}` prefix can
/// never appear in source, so these keys never collide with real names.
pub fn type_builtin_key(op: &str, arg: &Expr) -> Option<String> {
    let Expr::Designator(d) = arg else {
        return None;
    };
    // Accept only a plain, possibly module-qualified, type name — no index,
    // dereference, or call selectors.
    if !d.selectors.iter().all(|s| matches!(s, Selector::Field(_, _))) {
        return None;
    }
    let mut name = d.base.segments.join(".");
    for sel in &d.selectors {
        if let Selector::Field(f, _) = sel {
            name.push('.');
            name.push_str(f);
        }
    }
    Some(format!("\u{1}{op}\u{1}{name}"))
}

/// Synthetic `consts`-map key marking that `name` is a *type*, so a
/// single-argument call `name(x)` is a value conversion — foldable to the value
/// of `x` — rather than a (non-constant) procedure call. The analyze layer,
/// which has the type system, inserts a marker under this key when it sees such
/// a conversion in a constant expression. The `\u{1}` prefix never appears in
/// source, so it cannot collide with a real name.
pub fn type_conv_key(name: &str) -> String {
    format!("\u{1}conv\u{1}{name}")
}

/// Synthetic keys carrying the target type's ordinal bounds for a value
/// conversion `name(x)`, so the evaluator can reject an out-of-range constant
/// conversion (e.g. `ind0(50)` where `ind0 = [60..100]`). Present only when the
/// type has ordinal bounds (absent for REAL and the like).
pub fn type_conv_lo_key(name: &str) -> String {
    format!("\u{1}convlo\u{1}{name}")
}
pub fn type_conv_hi_key(name: &str) -> String {
    format!("\u{1}convhi\u{1}{name}")
}

/// Evaluate a constant expression.  `lookup` is used for named constants
/// and enumeration members.
pub fn eval_const(expr: &Expr, lookup: ConstLookup) -> Result<ConstValue, EvalError> {
    match expr {
        Expr::Integer(n, _) => Ok(ConstValue::Int(*n as i128)),
        Expr::Real(f, _) => Ok(ConstValue::Real(*f)),
        Expr::Char(c, _) => Ok(ConstValue::Char(c.value)),
        Expr::String(s, _) => Ok(ConstValue::Str(s.value.clone())),
        Expr::Nil(span) => {
            let _ = span;
            Ok(ConstValue::Nil)
        }
        Expr::Designator(d) => {
            // Build the qualified name from the base segments AND any field
            // selectors, so a qualified enum/const member like
            // `ConvTypes.strAllRight` is looked up under its full name.
            let mut key = d.base.segments.join(".");
            for sel in &d.selectors {
                if let Selector::Field(name, _) = sel {
                    key.push('.');
                    key.push_str(name);
                }
            }
            if let Some(v) = lookup(&key) {
                return Ok(v);
            }
            // Predefined identifiers not in scope (e.g. TRUE/FALSE/NIL
            // before the pervasive scope is wired in).
            match key.as_str() {
                "TRUE" => return Ok(ConstValue::Bool(true)),
                "FALSE" => return Ok(ConstValue::Bool(false)),
                "NIL" => return Ok(ConstValue::Nil),
                _ => {}
            }
            // MAX/MIN applied to type names — treat as error here; these are
            // handled with the full type system elsewhere.
            Err(EvalError::new(
                d.span,
                format!("'{key}' is not a constant expression"),
            ))
        }
        // Procedure calls used as constant expressions (e.g. MAX, MIN,
        // SIZE, TSIZE, CHR, ORD, VAL) are evaluated specially.
        Expr::Call(func, args, span) => eval_builtin_call(func, args, *span, lookup),
        Expr::Binary(op, lhs, rhs, span) => eval_binary(*op, lhs, rhs, *span, lookup),
        Expr::Unary(op, e, span) => eval_unary(*op, e, *span, lookup),
        Expr::Set { elements, span, .. } => {
            let mut members: Vec<i128> = Vec::new();
            for elem in elements {
                match elem {
                    newm2_parser::ast::SetElem::Single(e) => {
                        let v = eval_const(e, lookup)?;
                        let n = v.as_int().ok_or_else(|| {
                            EvalError::new(*span, "set element must be an ordinal")
                        })?;
                        if !members.contains(&n) {
                            members.push(n);
                        }
                    }
                    newm2_parser::ast::SetElem::Range(lo, hi) => {
                        let lo_v = eval_const(lo, lookup)?.as_int().ok_or_else(|| {
                            EvalError::new(*span, "set range must be ordinal")
                        })?;
                        let hi_v = eval_const(hi, lookup)?.as_int().ok_or_else(|| {
                            EvalError::new(*span, "set range must be ordinal")
                        })?;
                        for i in lo_v..=hi_v {
                            if !members.contains(&i) {
                                members.push(i);
                            }
                        }
                    }
                }
            }
            members.sort();
            Ok(ConstValue::Set(members))
        }
    }
}

/// The character data of a `Str`/`Char` constant, for concatenation folding.
fn const_string_part(v: &ConstValue) -> String {
    match v {
        ConstValue::Str(s) => s.clone(),
        ConstValue::Char(c) => c.to_string(),
        _ => String::new(),
    }
}

fn eval_binary(
    op: BinaryOp,
    lhs: &Expr,
    rhs: &Expr,
    span: Span,
    lookup: ConstLookup,
) -> Result<ConstValue, EvalError> {
    let lv = eval_const(lhs, lookup)?;
    let rv = eval_const(rhs, lookup)?;
    match op {
        BinaryOp::Add => match (&lv, &rv) {
            (ConstValue::Set(a), ConstValue::Set(b)) => Ok(ConstValue::Set(set_union(a, b))),
            // String concatenation: `"ab" + "cd"`, `"ab" + 'c'`, `'W' + 'o'`.
            // A single-char literal folds to `Char`, so a concatenation like
            // `"W" + "o" + "r" + "l" + "d"` is a chain of `Char + Char`. `+` is
            // never arithmetic on characters in Modula-2 (use ORD/CHR), so two
            // characters added always concatenate.
            (ConstValue::Str(_), ConstValue::Str(_))
            | (ConstValue::Str(_), ConstValue::Char(_))
            | (ConstValue::Char(_), ConstValue::Str(_))
            | (ConstValue::Char(_), ConstValue::Char(_)) => {
                let mut s = const_string_part(&lv);
                s.push_str(&const_string_part(&rv));
                Ok(ConstValue::Str(s))
            }
            _ => arith_op(lv, rv, span, |a, b| a.checked_add(b), |a, b| a + b),
        },
        BinaryOp::Sub => match (&lv, &rv) {
            (ConstValue::Set(a), ConstValue::Set(b)) => Ok(ConstValue::Set(set_diff(a, b))),
            _ => arith_op(lv, rv, span, |a, b| a.checked_sub(b), |a, b| a - b),
        },
        BinaryOp::Mul => match (&lv, &rv) {
            (ConstValue::Set(a), ConstValue::Set(b)) => Ok(ConstValue::Set(set_inter(a, b))),
            _ => arith_op(lv, rv, span, |a, b| a.checked_mul(b), |a, b| a * b),
        },
        BinaryOp::Div => {
            match (&lv, &rv) {
                (ConstValue::Real(a), ConstValue::Real(b)) => {
                    if *b == 0.0 {
                        return Err(EvalError::new(span, "division by zero"));
                    }
                    Ok(ConstValue::Real(a / b))
                }
                // ADW extension: integer / integer in a constant expression
                // is treated as truncated integer division.
                (ConstValue::Int(a), ConstValue::Int(b)) => {
                    if *b == 0 {
                        return Err(EvalError::new(span, "division by zero"));
                    }
                    Ok(ConstValue::Int(a / b))
                }
                // Set symmetric difference.
                (ConstValue::Set(a), ConstValue::Set(b)) => {
                    let mut result: Vec<i128> = a
                        .iter()
                        .filter(|x| !b.contains(x))
                        .chain(b.iter().filter(|x| !a.contains(x)))
                        .cloned()
                        .collect();
                    result.sort();
                    result.dedup();
                    Ok(ConstValue::Set(result))
                }
                _ => Err(EvalError::new(span, "type mismatch for '/' operator")),
            }
        }
        BinaryOp::DivKw => {
            let a = int_val(&lv, span)?;
            let b = int_val(&rv, span)?;
            if b == 0 {
                return Err(EvalError::new(span, "division by zero"));
            }
            // Wirth floored division: result has sign of divisor.
            Ok(ConstValue::Int(m2_div(a, b)))
        }
        BinaryOp::Mod => {
            let a = int_val(&lv, span)?;
            let b = int_val(&rv, span)?;
            if b == 0 {
                return Err(EvalError::new(span, "division by zero"));
            }
            Ok(ConstValue::Int(m2_mod(a, b)))
        }
        BinaryOp::Rem => {
            // REM is truncated remainder (C-style).
            let a = int_val(&lv, span)?;
            let b = int_val(&rv, span)?;
            if b == 0 {
                return Err(EvalError::new(span, "division by zero"));
            }
            Ok(ConstValue::Int(a.wrapping_rem(b)))
        }
        BinaryOp::Eq => Ok(ConstValue::Bool(const_eq(&lv, &rv))),
        BinaryOp::Ne => Ok(ConstValue::Bool(!const_eq(&lv, &rv))),
        BinaryOp::Lt => Ok(ConstValue::Bool(const_cmp(&lv, &rv, span)? < 0)),
        BinaryOp::Le => Ok(ConstValue::Bool(const_cmp(&lv, &rv, span)? <= 0)),
        BinaryOp::Gt => Ok(ConstValue::Bool(const_cmp(&lv, &rv, span)? > 0)),
        BinaryOp::Ge => Ok(ConstValue::Bool(const_cmp(&lv, &rv, span)? >= 0)),
        BinaryOp::And => {
            let a = bool_val(&lv, span)?;
            let b = bool_val(&rv, span)?;
            Ok(ConstValue::Bool(a && b))
        }
        BinaryOp::Or => {
            let a = bool_val(&lv, span)?;
            let b = bool_val(&rv, span)?;
            Ok(ConstValue::Bool(a || b))
        }
        BinaryOp::In => {
            let elem = int_val(&lv, span)?;
            match &rv {
                ConstValue::Set(s) => Ok(ConstValue::Bool(s.contains(&elem))),
                _ => Err(EvalError::new(span, "'IN' requires a set on the right")),
            }
        }
        BinaryOp::Bor => {
            let a = int_val(&lv, span)?;
            let b = int_val(&rv, span)?;
            Ok(ConstValue::Int(a | b))
        }
        BinaryOp::Band => {
            let a = int_val(&lv, span)?;
            let b = int_val(&rv, span)?;
            Ok(ConstValue::Int(a & b))
        }
        BinaryOp::Bxor => {
            let a = int_val(&lv, span)?;
            let b = int_val(&rv, span)?;
            Ok(ConstValue::Int(a ^ b))
        }
        BinaryOp::Shl => {
            let a = int_val(&lv, span)?;
            let b = int_val(&rv, span)?;
            Ok(ConstValue::Int(a << (b & 63)))
        }
        BinaryOp::Shr => {
            let a = int_val(&lv, span)?;
            let b = int_val(&rv, span)?;
            Ok(ConstValue::Int(((a as u64) >> (b & 63)) as i128))
        }
    }
}

fn eval_unary(
    op: UnaryOp,
    e: &Expr,
    span: Span,
    lookup: ConstLookup,
) -> Result<ConstValue, EvalError> {
    let v = eval_const(e, lookup)?;
    match op {
        UnaryOp::Pos => match v {
            ConstValue::Int(_) | ConstValue::Real(_) => Ok(v),
            _ => Err(EvalError::new(span, "unary '+' requires numeric operand")),
        },
        UnaryOp::Neg => match v {
            ConstValue::Int(n) => n
                .checked_neg()
                .map(ConstValue::Int)
                .ok_or_else(|| EvalError::new(span, "constant overflow")),
            ConstValue::Real(f) => Ok(ConstValue::Real(-f)),
            _ => Err(EvalError::new(span, "unary '-' requires numeric operand")),
        },
        UnaryOp::Not => match v {
            ConstValue::Bool(b) => Ok(ConstValue::Bool(!b)),
            // ADW: BNOT is parsed as UnaryOp::Not; allow bitwise NOT on integers.
            ConstValue::Int(n) => Ok(ConstValue::Int(!n)),
            _ => Err(EvalError::new(span, "NOT requires BOOLEAN operand")),
        },
    }
}

/// The final identifier of a `CAST`/`VAL` type argument, upper-cased — the
/// type whose bits the cast reinterprets. Handles both the unqualified form
/// (`REAL`) and a qualified one (`SYSTEM.REAL64`).
fn cast_target_name(type_expr: &Expr) -> Option<String> {
    let Expr::Designator(d) = type_expr else {
        return None;
    };
    if let Some(Selector::Field(name, _)) = d.selectors.last() {
        return Some(name.to_ascii_uppercase());
    }
    d.base.segments.last().map(|s| s.to_ascii_uppercase())
}

/// Reinterpret a folded constant across a `CAST(T, x)` when the cast crosses
/// the integer/floating boundary, mirroring a runtime bit-cast. An integer bit
/// pattern cast to a float type folds to the float with those bits; a float
/// cast to an integer type folds to its bit pattern. Same-domain casts (and any
/// cast we can't classify) leave the value unchanged.
fn reinterpret_cast_const(type_expr: &Expr, val: ConstValue) -> ConstValue {
    let Some(name) = cast_target_name(type_expr) else {
        return val;
    };
    match (name.as_str(), &val) {
        ("REAL" | "LONGREAL" | "REAL64", ConstValue::Int(n)) => {
            ConstValue::Real(f64::from_bits(*n as u64))
        }
        ("REAL32" | "SHORTREAL", ConstValue::Int(n)) => {
            ConstValue::Real(f32::from_bits(*n as u32) as f64)
        }
        (
            "CARDINAL" | "INTEGER" | "LONGINT" | "LONGCARD" | "CARDINAL64" | "INTEGER64"
            | "ADRCARD" | "ADRINT",
            ConstValue::Real(f),
        ) => ConstValue::Int(f.to_bits() as i128),
        _ => val,
    }
}

fn eval_builtin_call(
    func: &Expr,
    args: &[Expr],
    span: Span,
    lookup: ConstLookup,
) -> Result<ConstValue, EvalError> {
    // Only recognise a Designator with no selectors as the callee.
    let Expr::Designator(d) = func else {
        return Err(EvalError::new(span, "call expression is not constant"));
    };
    if d.selectors.is_empty() && d.base.segments.len() == 1 {
        match d.base.segments[0].as_str() {
            "CHR" => {
                if args.len() != 1 {
                    return Err(EvalError::new(span, "CHR requires one argument"));
                }
                let n = int_val(&eval_const(&args[0], lookup)?, span)?;
                let c = char::from_u32(n as u32)
                    .ok_or_else(|| EvalError::new(span, "CHR: value out of Unicode range"))?;
                return Ok(ConstValue::Char(c));
            }
            "ORD" => {
                if args.len() != 1 {
                    return Err(EvalError::new(span, "ORD requires one argument"));
                }
                let v = eval_const(&args[0], lookup)?;
                return v
                    .as_int()
                    .map(ConstValue::Int)
                    .ok_or_else(|| EvalError::new(span, "ORD requires ordinal argument"));
            }
            "ABS" => {
                if args.len() != 1 {
                    return Err(EvalError::new(span, "ABS requires one argument"));
                }
                let v = eval_const(&args[0], lookup)?;
                return match v {
                    ConstValue::Int(n) => Ok(ConstValue::Int(n.abs())),
                    ConstValue::Real(f) => Ok(ConstValue::Real(f.abs())),
                    _ => Err(EvalError::new(span, "ABS requires numeric argument")),
                };
            }
            "ODD" => {
                if args.len() != 1 {
                    return Err(EvalError::new(span, "ODD requires one argument"));
                }
                let n = int_val(&eval_const(&args[0], lookup)?, span)?;
                return Ok(ConstValue::Bool(n & 1 != 0));
            }
            "CAP" => {
                if args.len() != 1 {
                    return Err(EvalError::new(span, "CAP requires one argument"));
                }
                let v = eval_const(&args[0], lookup)?;
                let c = match v {
                    ConstValue::Char(c) => c,
                    ConstValue::Str(ref s) if s.chars().count() == 1 => s.chars().next().unwrap(),
                    other => {
                        let n = int_val(&other, span)?;
                        char::from_u32(n as u32)
                            .ok_or_else(|| EvalError::new(span, "CAP: value out of range"))?
                    }
                };
                return Ok(ConstValue::Char(c.to_ascii_uppercase()));
            }
            "LENGTH" => {
                if args.len() != 1 {
                    return Err(EvalError::new(span, "LENGTH requires one argument"));
                }
                return match eval_const(&args[0], lookup)? {
                    ConstValue::Str(s) => Ok(ConstValue::Int(s.chars().count() as i128)),
                    ConstValue::Char(_) => Ok(ConstValue::Int(1)),
                    _ => Err(EvalError::new(span, "LENGTH requires a string argument")),
                };
            }
            // CMPLX/RE/IM — compile-time complex construction / projection.
            "CMPLX" => {
                if args.len() != 2 {
                    return Err(EvalError::new(span, "CMPLX requires two arguments"));
                }
                let re = real_val(&eval_const(&args[0], lookup)?, span)?;
                let im = real_val(&eval_const(&args[1], lookup)?, span)?;
                return Ok(ConstValue::Complex(re, im));
            }
            "RE" | "IM" => {
                if args.len() != 1 {
                    return Err(EvalError::new(span, "RE/IM requires one argument"));
                }
                if let ConstValue::Complex(re, im) = eval_const(&args[0], lookup)? {
                    return Ok(ConstValue::Real(if d.base.segments[0] == "RE" { re } else { im }));
                }
                return Err(EvalError::new(span, "RE/IM requires a complex argument"));
            }
            // MAX/MIN/SIZE/TSIZE are type-dependent. The analyze layer
            // pre-computes them (it has the type system) and threads the value
            // through `lookup` under a synthetic key; fall back to a 0
            // placeholder only when no type info was supplied (or the argument
            // is not a plain type name).
            "MAX" | "MIN" | "SIZE" | "TSIZE" | "TBITSIZE" => {
                let op = d.base.segments[0].as_str();
                if args.len() == 1 {
                    if let Some(key) = type_builtin_key(op, &args[0]) {
                        if let Some(v) = lookup(&key) {
                            return Ok(v);
                        }
                    }
                }
                return Ok(ConstValue::Int(0));
            }
            // VAL(T, x) — the constant value is x's ordinal; the type coercion
            // is a no-op for folding purposes.
            "VAL" => {
                if args.len() == 2 {
                    return eval_const(&args[1], lookup);
                }
                return Ok(ConstValue::Int(0));
            }
            // OFFS(RecordType.Field) — compile-time field offset.
            // We can't compute it without type layout; return 0 placeholder.
            "OFFS" => {
                return Ok(ConstValue::Int(0));
            }
            // CAST(Type, expr) — reinterpret bits. For constant folding we fold
            // the value, then bit-reinterpret it when the cast crosses the
            // int/float boundary so the folded VALUE matches a runtime BitCast
            // (e.g. `CAST(REAL, 07FF0000000000000H)` folds to the f64 +inf, not
            // the integer 9218868437227405312). Same-domain casts are no-ops.
            "CAST" => {
                if args.len() >= 2 {
                    return Ok(reinterpret_cast_const(&args[0], eval_const(&args[1], lookup)?));
                }
                return Err(EvalError::new(span, "CAST requires two arguments"));
            }
            // MAKEADR(n) — construct an ADDRESS from an integer constant
            // (e.g. MAKEADR(-1) = MAXADDRESS, used like MAKEINTRESOURCE).
            // Return the integer value; CAST wrapping handles the type.
            "MAKEADR" => {
                if args.len() != 1 {
                    return Err(EvalError::new(span, "MAKEADR requires one argument"));
                }
                let n = int_val(&eval_const(&args[0], lookup)?, span)?;
                return Ok(ConstValue::Int(n));
            }
            // ADW Unicode/ANSI character coercions used in CONST expressions.
            // UCHR(n), WCHR(n), ACHAR(n) — ordinal-to-char casts;
            // return Int for constant folding purposes.
            "UCHR" | "WCHR" | "ACHAR" => {
                if args.len() != 1 {
                    return Err(EvalError::new(span, "character coercion requires one argument"));
                }
                let n = int_val(&eval_const(&args[0], lookup)?, span)?;
                return Ok(ConstValue::Int(n));
            }
            _ => {}
        }
    }
    // Qualified CAST: SYSTEM.CAST(T, v)
    if d.selectors.is_empty() && d.base.segments.len() == 2
        && d.base.segments[1].eq_ignore_ascii_case("CAST")
    {
        if args.len() >= 2 {
            return Ok(reinterpret_cast_const(&args[0], eval_const(&args[1], lookup)?));
        }
        return Err(EvalError::new(span, "CAST requires two arguments"));
    }
    // `T(x)` where T is a type name is a value conversion: the constant value
    // is x's value (the type coercion is a no-op for folding, like VAL/CAST).
    // The analyze layer marks a type-named callee via `type_conv_key`. When the
    // target type has ordinal bounds, an out-of-range value is a compile error
    // (e.g. `ind0(50)` where `ind0 = [60..100]`).
    if d.selectors.is_empty()
        && d.base.segments.len() == 1
        && args.len() == 1
        && lookup(&type_conv_key(&d.base.segments[0])).is_some()
    {
        let name = &d.base.segments[0];
        let v = eval_const(&args[0], lookup)?;
        if let (Some(ConstValue::Int(lo)), Some(ConstValue::Int(hi)), Some(n)) = (
            lookup(&type_conv_lo_key(name)),
            lookup(&type_conv_hi_key(name)),
            v.as_int(),
        ) && (n < lo || n > hi)
        {
            return Err(EvalError::new(
                span,
                format!("value {n} is out of range for conversion to '{name}'"),
            ));
        }
        return Ok(v);
    }
    Err(EvalError::new(span, "call expression is not constant"))
}

// ---- helpers ----

fn int_val(v: &ConstValue, span: Span) -> Result<i128, EvalError> {
    v.as_int().ok_or_else(|| EvalError::new(span, "expected integer constant"))
}

fn real_val(v: &ConstValue, span: Span) -> Result<f64, EvalError> {
    match v {
        ConstValue::Real(f) => Ok(*f),
        ConstValue::Int(n) => Ok(*n as f64),
        _ => Err(EvalError::new(span, "expected real constant")),
    }
}

fn bool_val(v: &ConstValue, span: Span) -> Result<bool, EvalError> {
    match v {
        ConstValue::Bool(b) => Ok(*b),
        _ => Err(EvalError::new(span, "expected BOOLEAN constant")),
    }
}

fn arith_op(
    lv: ConstValue,
    rv: ConstValue,
    span: Span,
    // `int_op` is *checked*: it returns `None` on overflow so the folder can
    // emit a clean diagnostic instead of panicking (debug) or silently wrapping
    // (release) — i128 has finite range even though M2 integer constants don't.
    int_op: impl Fn(i128, i128) -> Option<i128>,
    real_op: impl Fn(f64, f64) -> f64,
) -> Result<ConstValue, EvalError> {
    match (&lv, &rv) {
        (ConstValue::Int(a), ConstValue::Int(b)) => int_op(*a, *b)
            .map(ConstValue::Int)
            .ok_or_else(|| EvalError::new(span, "constant overflow")),
        (ConstValue::Real(a), ConstValue::Real(b)) => Ok(ConstValue::Real(real_op(*a, *b))),
        (ConstValue::Int(a), ConstValue::Real(b)) => Ok(ConstValue::Real(real_op(*a as f64, *b))),
        (ConstValue::Real(a), ConstValue::Int(b)) => Ok(ConstValue::Real(real_op(*a, *b as f64))),
        _ => Err(EvalError::new(span, "type mismatch in arithmetic constant expression")),
    }
}

fn set_union(a: &[i128], b: &[i128]) -> Vec<i128> {
    let mut result: Vec<i128> = a.to_vec();
    for x in b {
        if !result.contains(x) {
            result.push(*x);
        }
    }
    result.sort();
    result
}

/// Set difference (a - b): elements in a but not in b.
pub fn set_diff(a: &[i128], b: &[i128]) -> Vec<i128> {
    let mut r: Vec<i128> = a.iter().filter(|x| !b.contains(x)).cloned().collect();
    r.sort();
    r
}

/// Set intersection (a * b): elements in both.
pub fn set_inter(a: &[i128], b: &[i128]) -> Vec<i128> {
    let mut r: Vec<i128> = a.iter().filter(|x| b.contains(x)).cloned().collect();
    r.sort();
    r
}

fn const_eq(a: &ConstValue, b: &ConstValue) -> bool {
    match (a, b) {
        (ConstValue::Int(x), ConstValue::Int(y)) => x == y,
        (ConstValue::Real(x), ConstValue::Real(y)) => x == y,
        (ConstValue::Bool(x), ConstValue::Bool(y)) => x == y,
        (ConstValue::Char(x), ConstValue::Char(y)) => x == y,
        (ConstValue::Str(x), ConstValue::Str(y)) => x == y,
        (ConstValue::Set(x), ConstValue::Set(y)) => x == y,
        (ConstValue::Nil, ConstValue::Nil) => true,
        _ => false,
    }
}

/// Returns -1, 0, +1 for constant comparison.
fn const_cmp(a: &ConstValue, b: &ConstValue, span: Span) -> Result<i32, EvalError> {
    match (a, b) {
        (ConstValue::Int(x), ConstValue::Int(y)) => Ok(x.cmp(y) as i32),
        (ConstValue::Real(x), ConstValue::Real(y)) => Ok(x
            .partial_cmp(y)
            .map(|o| o as i32)
            .unwrap_or(0)),
        (ConstValue::Char(x), ConstValue::Char(y)) => Ok(x.cmp(y) as i32),
        (ConstValue::Str(x), ConstValue::Str(y)) => Ok(x.cmp(y) as i32),
        _ => Err(EvalError::new(span, "type mismatch in comparison")),
    }
}

// Wirth floored DIV: sign of result follows sign of divisor.
fn m2_div(a: i128, b: i128) -> i128 {
    let q = a / b;
    let r = a % b;
    if (r != 0) && ((r < 0) != (b < 0)) {
        q - 1
    } else {
        q
    }
}

// Wirth MOD: result always has same sign as divisor.
fn m2_mod(a: i128, b: i128) -> i128 {
    let r = a % b;
    if (r != 0) && ((r < 0) != (b < 0)) {
        r + b
    } else {
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use newm2_lexer::Span;
    use newm2_parser::ast::{BinaryOp, Expr, SetElem};

    const ZERO_SPAN: Span = Span {
        start: newm2_lexer::SourcePosition { line: 1, column: 1, offset: 0 },
        end: newm2_lexer::SourcePosition { line: 1, column: 1, offset: 0 },
    };

    fn no_lookup(_: &str) -> Option<ConstValue> {
        None
    }

    fn lookup_true(name: &str) -> Option<ConstValue> {
        match name {
            "TRUE" => Some(ConstValue::Bool(true)),
            "FALSE" => Some(ConstValue::Bool(false)),
            _ => None,
        }
    }

    #[test]
    fn integer_literal() {
        let e = Expr::Integer(42, ZERO_SPAN);
        assert_eq!(eval_const(&e, &no_lookup).unwrap(), ConstValue::Int(42));
    }

    #[test]
    fn wirth_div_positive() {
        assert_eq!(m2_div(7, 3), 2);
        assert_eq!(m2_div(-7, 3), -3); // floored toward -inf
        assert_eq!(m2_div(7, -3), -3);
        assert_eq!(m2_div(-7, -3), 2);
    }

    #[test]
    fn wirth_mod_positive() {
        assert_eq!(m2_mod(7, 3), 1);
        assert_eq!(m2_mod(-7, 3), 2); // result has sign of divisor
        assert_eq!(m2_mod(7, -3), -2);
        assert_eq!(m2_mod(-7, -3), -1);
    }

    #[test]
    fn bool_constant_lookup() {
        let e = Expr::Designator(newm2_parser::ast::Designator {
            base: newm2_parser::ast::QualName {
                segments: vec!["TRUE".to_string()],
                span: ZERO_SPAN,
            },
            selectors: vec![],
            span: ZERO_SPAN,
        });
        assert_eq!(eval_const(&e, &lookup_true).unwrap(), ConstValue::Bool(true));
    }

    #[test]
    fn chr_ord_roundtrip() {
        // CHR(65) = 'A'
        let chr_expr = Expr::Call(
            Box::new(Expr::Designator(newm2_parser::ast::Designator {
                base: newm2_parser::ast::QualName {
                    segments: vec!["CHR".to_string()],
                    span: ZERO_SPAN,
                },
                selectors: vec![],
                span: ZERO_SPAN,
            })),
            vec![Expr::Integer(65, ZERO_SPAN)],
            ZERO_SPAN,
        );
        assert_eq!(eval_const(&chr_expr, &no_lookup).unwrap(), ConstValue::Char('A'));
    }

    #[test]
    fn set_arithmetic_uses_iso_operators() {
        let left = Expr::Set {
            type_name: None,
            elements: vec![
                SetElem::Single(Expr::Integer(1, ZERO_SPAN)),
                SetElem::Single(Expr::Integer(2, ZERO_SPAN)),
            ],
            span: ZERO_SPAN,
        };
        let right = Expr::Set {
            type_name: None,
            elements: vec![
                SetElem::Single(Expr::Integer(2, ZERO_SPAN)),
                SetElem::Single(Expr::Integer(3, ZERO_SPAN)),
            ],
            span: ZERO_SPAN,
        };

        let union = Expr::Binary(BinaryOp::Add, Box::new(left.clone()), Box::new(right.clone()), ZERO_SPAN);
        let diff = Expr::Binary(BinaryOp::Sub, Box::new(left.clone()), Box::new(right.clone()), ZERO_SPAN);
        let inter = Expr::Binary(BinaryOp::Mul, Box::new(left.clone()), Box::new(right.clone()), ZERO_SPAN);
        let sym = Expr::Binary(BinaryOp::Div, Box::new(left), Box::new(right), ZERO_SPAN);

        assert_eq!(eval_const(&union, &no_lookup).unwrap(), ConstValue::Set(vec![1, 2, 3]));
        assert_eq!(eval_const(&diff, &no_lookup).unwrap(), ConstValue::Set(vec![1]));
        assert_eq!(eval_const(&inter, &no_lookup).unwrap(), ConstValue::Set(vec![2]));
        assert_eq!(eval_const(&sym, &no_lookup).unwrap(), ConstValue::Set(vec![1, 3]));
    }
}
