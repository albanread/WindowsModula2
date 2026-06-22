# Reference

The reserved-word set and the predeclared (pervasive) identifiers. The reserved words are
from `src/newm2-lexer/src/token.rs`; the pervasive identifiers are registered by sema
(`src/newm2-sema/src/analyze.rs`).

## Reserved words

These are the keywords the lexer recognises — PIM 4 + ISO 10514-1, a piece of ISO 10514-2,
and NewM2 extensions. They cannot be used as identifiers.

| Group | Reserved words |
|-------|----------------|
| Modules & structure | `MODULE` `DEFINITION` `IMPLEMENTATION` `IMPORT` `FROM` `EXPORT` `QUALIFIED` `BEGIN` `END` |
| Declarations | `CONST` `TYPE` `VAR` `PROCEDURE` `FORWARD` `RECORD` `ARRAY` `SET` `POINTER` `OF` `TO` |
| Control flow | `IF` `THEN` `ELSIF` `ELSE` `CASE` `WHILE` `DO` `REPEAT` `UNTIL` `FOR` `BY` `LOOP` `EXIT` `WITH` `RETURN` |
| Word operators | `AND` `OR` `NOT` `DIV` `MOD` `REM` `IN` |
| ISO 10514-1 | `EXCEPT` `FINALLY` `RETRY` `GENERIC` `PACKEDSET` |
| Object-oriented (COM) | `ABSTRACT` |
| NewM2 extensions | `ASM` `BAND` `BOR` `BXOR` `BNOT` `SHL` `SHR` |

**Contextual (soft) keywords.** The object-oriented layer's other words —
`CLASS` `INTERFACE` `INHERIT` `REVEAL` `OVERRIDE` `GUARD` `AS` (and
`UNSAFEGUARDED`) — are recognised only in their syntactic position, so they are
*not* reserved and remain usable as ordinary identifiers. See
[Objects & classes](objects-and-classes.md).

## Pervasive identifiers

Predeclared in an enclosing pseudo-scope and usable without an import — but they are
ordinary **identifiers**, not reserved words (so a local declaration shadows them).

**Types** — `INTEGER` `CARDINAL` `REAL` `LONGREAL` `BOOLEAN` `CHAR` `BITSET` `PROC`, the ISO
`COMPLEX` / `LONGCOMPLEX`, and the exact-width family `INTEGER8`/`16`/`32`/`64`,
`CARDINAL8`/`16`/`32`/`64`, `ACHAR`, `UCHAR`.

**Constants** — `TRUE` `FALSE` `NIL`, and `EMPTY` (the null object reference — `EMPTY` is to
objects as `NIL` is to pointers; see [Objects & classes](objects-and-classes.md)).

**Procedures & functions** (registered in `analyze.rs`) — see
[The standard environment](standard-environment.md) for what each does:

| Kind | Names |
|------|-------|
| Storage | `NEW` `DISPOSE` |
| Increment / set | `INC` `DEC` `INCL` `EXCL` |
| Inquiry | `HIGH` `SIZE` `TSIZE` `ODD` |
| Conversion | `ORD` `CHR` `VAL` `CAP` `FLOAT` `LFLOAT` `INT` `TRUNC` `ENTIER` |
| Arithmetic | `ABS` `MIN` `MAX` |
| Object RTTI | `ISMEMBER` (and the `GUARD` statement — see [Objects & classes](objects-and-classes.md)) |
| Program | `HALT` `ASSERT` |

## The SYSTEM module

`IMPORT SYSTEM;` exposes the low-level layer: types `ADDRESS` `WORD` `BYTE` `LOC` (and
`CARD8`..`64` / `INT8`..`64`), and procedures `ADR` (address-of), `CAST` / `VAL` (type
transfer), `TSIZE`, address arithmetic `ADDADR` / `SUBADR` / `DIFADR` / `MAKEADR`, and
`SHIFT` / `ROTATE`. The coroutine primitives (`NEWPROCESS` / `TRANSFER` / `IOTRANSFER`)
parse and resolve but are not yet executed. See
[The standard environment](standard-environment.md).

## Operators at a glance

`:=` assign · `=` equal · `#` / `<>` not-equal · `< <= > >=` order · `IN` membership ·
`+ - * /` arithmetic and set ops · `DIV` `MOD` `REM` integer division · `AND` / `&` `OR`
`NOT` / `~` boolean · NewM2 `BAND BOR BXOR BNOT SHL SHR` bitwise. Full precedence on
[Expressions & operators](expressions-and-operators.md).

---
[NewM2 Guide home](index.md) · [Lexical structure](lexical-structure.md) · [The standard environment](standard-environment.md)
