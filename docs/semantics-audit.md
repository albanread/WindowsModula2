# Sprint K — semantic-analyzer audit

Targeted audit of `newm2-sema` for **silent miscompiles** and **invalid programs
the checker fails to reject** (ISO 10514-1 / PIM4). Every gap below was confirmed
empirically with `newm2-driver check <file>` (loader + sema, no codegen).

**Dominant root cause:** the "ADW integer-family leniency" in
`expr_compatible_with_type` (analyze.rs:2616–2622) combined with
`is_integer_family_type` treating **enums and subranges as integer-family**
(analyze.rs:2481). Assignment, parameter passing, CASE labels, FOR bounds, and
array indexing all funnel through these, so the leniency silently disables
nominal typing for enums/subranges and collapses CARDINAL/INTEGER.

## Prioritized gap table

| # | Gap | Severity | file:line | Expected vs actual |
|---|-----|----------|-----------|--------------------|
| 1 | Distinct enum types mutually assignable (`col := fr`, `col := apple`) | **Critical** | analyze.rs:2620-2622 + 2481 | want nominal-distinct error; accepted |
| 2 | Constant overflow in const-folding **panics the compiler** (debug) / wraps (release) | **Critical** | constant.rs:201/193/197, arith_op:499 | want "constant overflow"; `panicked … multiply with overflow`, exit 101 |
| 3 | `CARDINAL := INTEGER` and `CARDINAL := -1` accepted | High | analyze.rs:2620-2622 | want rejected; accepted (REAL↔INTEGER *is* rejected) |
| 4 | Qualified access to a **non-exported** module member succeeds | High | analyze.rs:2287 & 2318 | want "not exported"; resolves (note `FROM..IMPORT` *is* checked at :1253) |
| 5 | Passing a CONST (non-l-value) to a VAR parameter accepted | High | analyze.rs:2946-2948 | want "VAR param requires a variable"; accepted (compound *expr* IS rejected) |
| 6 | Array index not checked against declared index type | High | analyze.rs:2864-2878 | want index-type mismatch; accepted (enum & INTEGER both "integer-family") |
| 7 | Duplicate declaration in same scope silently accepted (last wins) | High | scope.rs:58-67 + pass1_decl | want "duplicate declaration"; silently replaced |
| 8 | Constant assigned/indexed out of subrange bounds not checked | Med | analyze.rs:2593-2594 | want static range error; accepted |
| 9 | Duplicate / overlapping CASE labels not detected | Med | analyze.rs:3728-3766 | want "duplicate CASE label"; accepted (no enum exhaustiveness either) |
| 10 | Runtime-expr `DIV 0` / `MOD 0` (literal 0) not flagged | Med | analyze.rs:3504-3540 | want a warning; accepted (CONST-decl `DIV 0` *is* caught) |

## Already correct (avoid false positives)
- REAL↔INTEGER, CHAR↔INTEGER, BOOLEAN→INTEGER mismatches are rejected.
- Call arity (over/under) checked (analyze.rs:2925).
- VAR param given a compound *expression* rejected (only designator l-value-ness unchecked).
- `FROM M IMPORT nonExported` rejected (analyze.rs:1253); only *qualified* `M.nonExported` is not (#4).
- CONST-decl division by zero diagnosed.

## Fix order (hardening pass)
1. **Tighten `expr_compatible_with_type` / `is_integer_family_type`** — root of #1,#3,#6,#8.
   Exclude `Enum`/`Subrange` from the leniency (enums stay nominal; subranges compare
   host + range). Closes the largest silent-miscompile cluster.
2. **Make constant folding overflow-safe (#2)** — `checked_*` returning `EvalError("constant
   overflow")` in `constant.rs`. As-is the compiler crashes (debug) or miscomputes (release).
3. **Reject non-exported qualified access (#4) and duplicate declarations (#7)** —
   filter `sym.exported` in the qualified branch; `pass1_decl` consults `scope.get` before insert.
