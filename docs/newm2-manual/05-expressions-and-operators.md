# Expressions & Operators

Modula-2 has a compact, three-level binary expression grammar. Knowing the precedence table lets you write correct arithmetic and logical expressions without over-parenthesising.

## Precedence

The table is read top-to-bottom: lower rows bind tighter. The parser implements exactly these levels (`src/newm2-parser/src/parser.rs`, functions `parse_relational` / `parse_simple` / `parse_term` / `parse_factor`).

| Level | Operators | Associativity | AST function |
|-------|-----------|---------------|--------------|
| Relational (lowest) | `=` `#` `<>` `<` `<=` `>` `>=` `IN` | non-associating | `parse_relational` (line 1691) |
| Additive / disjunctive | `+` `-` `OR` | left | `parse_simple` (line 1718) |
| Multiplicative / conjunctive | `*` `/` `DIV` `MOD` `REM` `AND` `&` `BOR` `BAND` `BXOR` `SHL` `SHR` | left | `parse_term` (line 1756) |
| Prefix (highest) | `NOT` `~` `BNOT` unary `+` unary `-` | — | `parse_factor` / `parse_simple` (line 1828) |

A parenthesised sub-expression `(e)` always resets to the outermost level (`parse_factor` line 1860).

**Consequence:** `AND` binds tighter than `OR`, which binds tighter than relational operators — so `a OR b AND c` parses as `a OR (b AND c)`, and `a = b OR c = d` parses as `(a = b) OR (c = d)`. You rarely need parentheses for the standard Boolean patterns.

## Arithmetic and DIV / MOD / REM

The four standard arithmetic operators work on numeric types:

| Operator | Meaning | Operand types |
|----------|---------|---------------|
| `+` | Addition | `INTEGER`, `CARDINAL`, `REAL`, `LONGREAL`, sets |
| `-` | Subtraction / negation | numeric, sets |
| `*` | Multiplication | numeric, sets |
| `/` | Real division, or set symmetric difference | `REAL`/`LONGREAL`, sets |
| `DIV` | Truncating integer division | integer types |
| `MOD` | Modulus — result has the sign of the divisor | integer types |
| `REM` | Remainder — result has the sign of the dividend | integer types (ISO) |

The distinction between `MOD` and `REM` matters for negative operands:

```modula2
VAR q, r : INTEGER;
BEGIN
  q := 7 DIV 2;    (* 3 — truncates toward zero *)
  r := 7 MOD 2;    (* 1 *)

  q := (-7) DIV 2; (* -3 — truncates toward zero *)
  r := (-7) MOD 2; (* 1 — MOD result has sign of divisor (2 is positive) *)
  r := (-7) REM 2; (* -1 — REM result has sign of dividend (-7) *)
END
```

This matches the corpus: `Mod/tests/t-10-020-divmod.mod` exercises `DIV` and `MOD` on positive integers. `REM` follows ISO 10514-1; NewM2 registers it as keyword `Rem` in `src/newm2-lexer/src/token.rs` line 136.

Unary `-` appears as a prefix on a factor:

```modula2
VAR a, b : INTEGER;
BEGIN
  a := -5;
  b := 15 + a;  (* b = 10 *)
END
```

Source: `Mod/tests/t-10-030-neg-arith.mod`.

## Relational Operators and IN

Relational operators compare two values of the same base type and yield `BOOLEAN`:

| Operator | Meaning | Note |
|----------|---------|------|
| `=` | Equal | |
| `#` | Not equal | |
| `<>` | Not equal | synonym for `#` |
| `<` | Less than | |
| `<=` | Less than or equal | |
| `>` | Greater than | |
| `>=` | Greater than or equal | |
| `IN` | Set membership | left: element type; right: set type |

Both `#` and `<>` are distinct tokens (`TokenKind::Hash` and `TokenKind::NotEqual` in `src/newm2-lexer/src/token.rs` lines 72 and 76) but produce the same AST node `BinaryOp::Ne` (`ast.rs` line 329, `parser.rs` line 1697). Use whichever you prefer; the corpus uses both.

`IN` tests whether an ordinal value is a member of a set:

```modula2
TYPE
  ExecFlags    = (ExecDetached, ExecMinimized, ExecMaximized, ExecHidden);
  ExecFlagSet  = SET OF ExecFlags;
VAR flags : ExecFlagSet;
BEGIN
  flags := ExecFlagSet{ExecMinimized, ExecHidden};
  IF ExecMinimized IN flags THEN
    (* minimized mode is set *)
  END;
END
```

Source pattern: `library/advapidef/PipedExec.def` defines `ExecFlagSet = SET OF ExecFlags`.

Relational expressions are non-associating in Modula-2: `a < b < c` is a parse error. Write `(a < b) AND (b < c)`.

## Boolean Operators and Short-Circuit Evaluation

Modula-2 defines three Boolean operators:

| Operator | Synonym | Meaning |
|----------|---------|---------|
| `AND` | `&` | Logical conjunction — true iff both operands are true |
| `OR` | — | Logical disjunction — true iff at least one operand is true |
| `NOT` | `~` | Logical negation (prefix) |

Both spellings of each operator are full keywords (`src/newm2-lexer/src/token.rs`: `Keyword::And`, `Keyword::Or`, `Keyword::Not`; `TokenKind::Amp`, `TokenKind::Tilde`). They produce the same AST nodes.

**Short-circuit evaluation.** `AND` and `OR` evaluate left-to-right and stop as soon as the result is determined:

- `A AND B` — if `A` is `FALSE`, `B` is not evaluated.
- `A OR B` — if `A` is `TRUE`, `B` is not evaluated.

This is guaranteed by PIM 4 and by the sequential recursive descent in `parse_simple` / `parse_term`. You may exploit it safely:

```modula2
IF (p # NIL) AND (p^.value > 0) THEN
  (* safe: the deref only happens when p is non-nil *)
END;
```

`NOT` (or `~`) applies to a single factor:

```modula2
IF NOT isPrime THEN
  divisor := candidate;
END;
```

Source: `Mod/tests/perf-primes-o2.mod` (line 24 uses `isPrime := FALSE`; the sieve at `perf-sieve-o2.mod` line 28 uses `flags[i] # 0` as a boolean guard).

## Sets

Set operators use the same symbols as arithmetic operators, but apply to set types (`SET OF T` or `BITSET`). The type of both operands must be compatible set types.

| Operator | Set operation |
|----------|--------------|
| `+` | Union |
| `-` | Difference |
| `*` | Intersection |
| `/` | Symmetric difference |

A **set constructor** builds a set value inline. The type name is written before the braces; elements and ranges are separated by commas:

```modula2
TYPE
  Digit    = [0..9];
  DigitSet = SET OF Digit;
VAR s, t, u : DigitSet;
BEGIN
  s := DigitSet{1, 3, 5, 7, 9};   (* odd digits *)
  t := DigitSet{0, 2, 4, 6, 8};   (* even digits *)
  u := s + t;                      (* union — all digits *)
  s := u - DigitSet{0};            (* difference — remove 0 *)
  t := s * DigitSet{1..5};         (* intersection — {1, 2, 3, 4, 5} *)
END
```

A range inside a constructor is written `lo..hi`. The type-name prefix is optional for `BITSET` when the element type can be inferred, but writing it explicitly is recommended for readability.

Set constructor syntax in the AST: `Expr::Set { type_name, elements, span }` where each element is `SetElem::Single(e)` or `SetElem::Range(lo, hi)` (`src/newm2-parser/src/ast.rs` lines 297–298, 354–358; `parser.rs` `parse_set_constructor` line 2009).

`INCL(s, e)` and `EXCL(s, e)` are pervasive procedures that add and remove a single element; they are more efficient than `s := s + SetType{e}` for single-element updates. See [The standard environment](09-standard-environment.md).

## Bitwise Operators (NewM2 Extension)

NewM2 carries these bitwise operators as reserved keywords (`src/newm2-lexer/src/token.rs` lines 153–159). They operate on integer types and have **no standard Modula-2 equivalent** — they are a NewM2 extension:

| Operator | Operation | AST node |
|----------|-----------|----------|
| `BAND` | Bitwise AND | `BinaryOp::Band` |
| `BOR` | Bitwise OR | `BinaryOp::Bor` |
| `BXOR` | Bitwise exclusive OR | `BinaryOp::Bxor` |
| `BNOT` | Bitwise NOT (prefix) | `UnaryOp::Not` |
| `SHL` | Left shift | `BinaryOp::Shl` |
| `SHR` | Right shift | `BinaryOp::Shr` |

`BNOT` is a prefix operator (parsed in `parse_factor`, line 1839); the rest are binary and sit at the multiplicative level in `parse_term` (lines 1769–1789) — the same level as `AND` and `DIV`.

The real corpus uses them heavily for multi-precision arithmetic:

```modula2
(* From library/advapimod/Money.mod — multi-word integer arithmetic *)
a1[1] := a SHR DigitBits;
a3    := (a3 SHL 1) BOR (a2 SHR (DigitBits - 1));
RETURN (VAL(Money, a1) SHL DigitBits) BOR VAL(Money, a0);
```

Use these operators only in code that targets NewM2. Portable Modula-2 using the `SYSTEM` module's `CAST` and bit manipulation is the standard-conforming alternative.

## Type Conversions

Modula-2 is strongly typed: arithmetic mixing of distinct numeric types requires an explicit conversion. The pervasive functions for this are:

| Function | Converts |
|----------|---------|
| `VAL(T, x)` | Reinterprets `x` as type `T` (ordinal types; also numeric) |
| `ORD(x)` | Ordinal value of a `CHAR`, enumeration, or `BOOLEAN` |
| `CHR(n)` | `CHAR` with ordinal value `n` |
| `FLOAT(n)` | `REAL` from an integer |
| `TRUNC(r)` | `INTEGER` from `REAL`, truncating toward zero |

`VAL` is the general-purpose conversion: `VAL(INTEGER64, src)` converts a `LONGREAL` to `INTEGER64`; `VAL(INTEGER, mid)` converts back. The corpus demonstrates a full round-trip in `Mod/tests/t-10-040-val-roundtrip.mod`.

These are pervasive identifiers — no import needed. They are described in full in [The standard environment](09-standard-environment.md).

---
[NewM2 Guide home](index.md) · [Declarations & types](04-declarations-and-types.md) · [Statements & control flow](06-statements-and-control-flow.md)
