# Design: ISO array/record constructor `BY` repeat syntax

**Status:** Proposed (design only — no source changed)
**Author:** research pass, 2026-06-13
**Feature:** Accept `Type{ element BY count }` in aggregate / set constructors, meaning
`element` repeated `count` times.

---

## Summary

ISO Modula-2 allows a constructor element to be written `value BY count`, which
denotes `count` copies of `value`. NewM2 does not parse this: the constructor
parser (`parse_set_constructor`) only understands `expr` and `expr .. expr`
(range) elements, so it hits `BY` and reports
`parse error ... expected '}', found Keyword(By)`.

The fix touches all four pipeline stages:

1. **AST** — add a third constructor-element variant `SetElem::Repeat(element, count)`.
2. **Parser** — after reading an element expression, recognise `BY` and parse a
   trailing count expression.
3. **Sema / const-fold** — type-check the element and the (constant) count, and in
   the constant evaluator expand `element BY count` into `count` folded values;
   for an `ARRAY OF CHAR` field this expands `"" BY 80` to 80 `Char('\0')` cells.
4. **IR lowering** — for runtime constructors, emit `count` element stores (a small
   compile-time unrolled loop, since `count` is a constant), reusing the existing
   CHAR-array string-copy logic where the element is a string.

The work is additive: a new enum variant whose absence today is exactly what the
existing `match`/`else` arms silently drop, so every site that pattern-matches
`SetElem` must gain a `Repeat` arm.

---

## Failing test & current behavior

Test: `nestediso.mod:41` (from the external conformance corpus)

```modula2
person := PersonType{StringType{"" BY 80}, DateType{0, 1, 2}} ;
```

with

```modula2
StringType = ARRAY [0..79] OF CHAR ;   (* nestediso.mod:22 *)
DateType   = RECORD y, m, d: CARDINAL END ;   (* :23 *)
PersonType = RECORD name: StringType; birth: DateType END ;   (* :26 *)
```

Here `StringType{"" BY 80}` is an 80-element `ARRAY OF CHAR` whose every cell is
the empty/NUL char — i.e. a fully blanked 80-char buffer. Lines 42–45 then use the
same `PersonType` constructor in several spellings that already parse
(`PersonType{"", {0,1,2}}`, etc.), so once `BY` parses, the rest of the file is
covered by existing aggregate-constructor support.

**Current behavior:** parse fails on `BY`. `parse_set_constructor`
(`src/newm2-parser/src/parser.rs:2118`) calls `parse_expr()` for the element, then
expects either `..` (range) or `,`/`}`; encountering `BY` falls through to
`expect_kind(RBrace, "'}'")` at `parser.rs:2136`, producing the diagnostic.

---

## ISO Modula-2 semantics of `BY` in constructors

In ISO M2 a *structure constructor* (array, record, or set value constructor)
may contain *value-or-range* components, and an array/set component may carry a
repetition factor written `component BY repeatCount`:

- `arr{ x BY n }` — element `x` occupies the next `n` consecutive positions.
- `arr{ a, x BY n, b }` — `a` at position 0, then `x` at positions 1..n, then `b`.
- `repeatCount` is a **constant** ordinal expression `>= 0` (the ISO spec requires it to be
  evaluated at compile time; it indexes positions, so it cannot depend on runtime values).
- For a record constructor, `BY` is meaningful only when the repeated component
  lines up with consecutive same-typed fields; in practice the construct is used
  for arrays (and array-of-char fields). NewM2 can treat a record-level `BY` as
  "fill the next `count` fields with `element`" for symmetry, but the failing test
  only needs the array case, so the record case is a low-priority extension (see
  Open questions).
- Special case exercised by the test: `StringType{ "" BY 80 }` where
  `StringType = ARRAY [0..79] OF CHAR`. The component is the empty string and the
  array element type is `CHAR`. The ISO spec expands this to 80 NUL characters — a blanked
  buffer. (More generally `'X' BY 80` would be 80 `'X'` characters.)

Reference for the existing partial support note in NewM2:
`src/newm2-sema/src/analyze.rs:2341` already contains a comment
"`{x BY n}` repetition in a constructor is not yet supported." and bails out of
const-folding for the (currently unreachable) `Range` arm.

---

## Current NewM2 constructor handling (file:line)

### Lexer
- `BY` keyword token exists: `src/newm2-lexer/src/token.rs:105` (`By` variant),
  `:169` (`"BY" => By`), `:231` (display). It is currently consumed only by the
  FOR-loop parser. The constructor parser never expects it, so there is no
  ambiguity to resolve — inside `{ }` a `BY` after an element expression is
  unambiguously the repeat separator.

### AST
- Expression node: `Expr::Set { type_name: Option<QualName>, elements: Vec<SetElem>, span }`
  at `src/newm2-parser/src/ast.rs:304`. This single node represents **both** set
  constructors (`{1,3,5}`, `BITSET{..}`) and structured aggregate constructors
  (`RecordType{..}`, `ArrayType{..}`) — the latter distinguished by a `Some(type_name)`
  that resolves to a RECORD/ARRAY type.
- Element enum: `SetElem` at `src/newm2-parser/src/ast.rs:361`:
  ```rust
  pub enum SetElem { Single(Expr), Range(Expr, Expr) }
  ```

### Parser
- `parse_set_constructor` at `src/newm2-parser/src/parser.rs:2118`. Loop body at
  `:2123`: reads `lo = parse_expr()`, then if `DotDot` consumes `hi` and pushes
  `Range`, else pushes `Single` (`:2125`–`:2130`). No `BY` handling — this is the
  one edit needed in the parser.

### Sema (analysis / type-check)
- Structured-aggregate analysis: `analyse_expr`'s `Expr::Set` arm at
  `src/newm2-sema/src/analyze.rs:4396`. For a RECORD/ARRAY `type_name` it computes
  per-field / per-element expected types (`:4416`–`:4426`) and checks each element.
  The element `match` at `:4427` handles `Single` (type-check against field/elem
  type, `:4429`) and `Range` (just types the operands, no aggregate meaning, `:4442`).
- The const re-eval driver `reeval_aggregate_consts` at
  `src/newm2-sema/src/analyze.rs:2171`, and the entry `eval_const_decl` at `:2200`,
  which dispatches `Expr::Set { type_name: Some(qn), .. }` whose `qn` resolves to
  RECORD/ARRAY to `eval_aggregate_const` (`:2224`–`:2231`).
- **Aggregate constant evaluator** `eval_aggregate_const` at
  `src/newm2-sema/src/analyze.rs:2297`. Key facts:
  - Builds `elem_types` per position (record fields flattened, or array base
    repeated): `:2315`–`:2324`.
  - `char_array_base` flag at `:2328` — true when the target is a 1-D `ARRAY OF
    CHAR`; used to spread a string element across consecutive CHAR cells
    (`:2353`–`:2358`).
  - Element loop at `:2337`: matches `Single` (`:2340`), and on `Range(..)` returns
    `None` (`:2342`) — i.e. it gives up folding, which is what makes `BY` currently
    fail the const path. **This is the second edit site.**
- Generic set/const evaluator `eval_const`'s `Expr::Set` arm at
  `src/newm2-sema/src/constant.rs:172` (set-value semantics — `Single`/`Range`
  produce a `ConstValue::Set` of ordinals). Used when the constructor is a *set*,
  not an aggregate; will also need a `Repeat` arm to compile, even if `BY` in a
  pure set is rejected (see Open questions).
- `prefill_type_builtins`'s `Expr::Set` walk at
  `src/newm2-sema/src/analyze.rs:2119` recurses into `Single`/`Range` operands;
  needs a `Repeat` arm so MAX/MIN/SIZE inside a repeated element still prefill.
- `ConstValue` enum at `src/newm2-sema/src/constant.rs:16`; `Aggregate(Vec<ConstValue>)`
  at `:33` is the folded representation of a structured constructor. A folded
  `element BY count` simply contributes `count` entries to this vec — no new
  `ConstValue` variant is needed.

### IR lowering
- Expression dispatch: `Expr::Set` at `src/newm2-ir/src/lower.rs:2500`. If
  `expr_type` is RECORD/ARRAY/OpenArray it delegates to
  `lower_aggregate_constructor` (`:2511`); otherwise it builds an i256 set value,
  iterating `SetElem::Single` / `SetElem::Range` (`:2532`–) — that set loop must gain a
  `Repeat` arm to compile.
- **`lower_aggregate_constructor`** at `src/newm2-ir/src/lower.rs:2651`:
  - Allocates a slot (`Inst::Alloca`, `:2668`) — **not zero-initialised**.
  - Iterates `elements`, `let Single(value) = elem else { continue }` at `:2671` —
    so a `Range`/`Repeat` element is silently skipped today. **Third edit site.**
  - For each element computes the destination pointer: `IndexPtr` for arrays
    (`:2674`–`:2676`, using a running `field` index) or `FieldPtr` for records
    (`:2678`).
  - **CHAR-array string copy**: if the slot type is an `ARRAY OF CHAR`
    (`array_char_count` at `:4061`) and `value` is a string r-value
    (`is_string_rvalue` at `:4095`), it calls the runtime `NM2Str.WCopy`
    (`:2698`) to copy the string into the buffer rather than storing a pointer.
  - Otherwise stores the scalar value (`:2700`–`:2701`), increments `field`.
- Const-init path: `emit_const_value` at `src/newm2-ir/src/lower.rs:2576` carries a
  folded `ConstValue::Aggregate` to codegen as `ConstVal::Aggregate { value, ty }`
  (`:2581`–`:2587`). When the `BY` count is constant *and* every element folds, the
  whole constructor can ride this path with **no runtime code at all** — the
  expansion happens in `eval_aggregate_const`.
- Runtime support: `nm2_copy_wstring` (`NM2Str.WCopy`) at
  `src/newm2-runtime/src/strings.rs:108`. **Important:** it copies until the source
  NUL then writes a single terminating NUL — it does **not** blank-fill the whole
  buffer. So a runtime `"" BY 80` cannot rely on WCopy to zero 80 cells; the empty
  string only writes cell 0. This constrains the runtime design (below).

---

## Affected subsystems

| Stage | File | Change |
|-------|------|--------|
| AST | `src/newm2-parser/src/ast.rs:361` | add `SetElem::Repeat(Expr, Expr)` |
| Parser | `src/newm2-parser/src/parser.rs:2118` | parse `expr BY expr` element |
| Sema analyse | `src/newm2-sema/src/analyze.rs:4396`, `:4427` | type-check `Repeat`; count must be constant ordinal |
| Sema prefill | `src/newm2-sema/src/analyze.rs:2119` | recurse into `Repeat` operands |
| Sema const-fold (aggregate) | `src/newm2-sema/src/analyze.rs:2337`, `:2353` | expand `Repeat` into `count` folded values (CHAR-array aware) |
| Sema const-fold (set) | `src/newm2-sema/src/constant.rs:172` | add `Repeat` arm (compile-fix; reject in pure set) |
| IR lowering (set) | `src/newm2-ir/src/lower.rs:2532` | add `Repeat` arm (compile-fix; reject in pure set) |
| IR lowering (aggregate) | `src/newm2-ir/src/lower.rs:2651` | unroll `Repeat`: `count` stores / fills |
| Tests | `Mod/tests/`, conformance corpus | new JIT test + enable `nestediso.mod` |

No lexer change is required (`BY` already tokenises).

---

## Proposed design

### (1) AST

Add a third variant to `SetElem` (`src/newm2-parser/src/ast.rs:361`):

```rust
pub enum SetElem {
    Single(Expr),
    Range(Expr, Expr),
    /// `element BY count` — `element` repeated `count` times in a
    /// structured (array) constructor. `count` is a constant ordinal.
    Repeat(Expr, Expr),
}
```

Rationale for a dedicated variant (vs. desugaring at parse time into `count`
`Single`s): the count is not known to be a small constant until sema folds it, and
the element may be a string that itself spreads across many cells. Keeping the
syntactic form lets sema decide expansion with full type context, and keeps spans
intact for diagnostics. It also mirrors how `Range` is preserved rather than
expanded in the AST.

### (2) Parser

In `parse_set_constructor` (`parser.rs:2123`) extend the element loop:

```rust
let lo = self.parse_expr()?;
if self.eat_kind(&TokenKind::DotDot) {
    let hi = self.parse_expr()?;
    elements.push(SetElem::Range(lo, hi));
} else if self.eat_kind(&TokenKind::Keyword(Keyword::By)) {
    let count = self.parse_expr()?;
    elements.push(SetElem::Repeat(lo, count));
} else {
    elements.push(SetElem::Single(lo));
}
```

`eat_kind(Keyword(By))` consumes the `BY` only inside the constructor, so the
FOR-loop `BY` is untouched. `..` and `BY` are mutually exclusive on one element,
matching ISO grammar (a component is `value [ '..' value | 'BY' value ]`).

### (3) Sema / const-fold

**Type checking** (`analyze.rs:4427`, structured arm): add

```rust
ast::SetElem::Repeat(value, count) => {
    if let Some(value_ty) = analyse_expr(ctx, value, scope) {
        let expect = elem_ty.or_else(|| field_tys.get(i).copied());
        if let Some(expect) = expect {
            if !expr_compatible_with_type(ctx, expect, value, value_ty) {
                ctx.error(expr_span(value),
                    "aggregate constructor element type is incompatible");
            }
        }
    }
    // count must be a constant non-negative ordinal
    let cty = analyse_expr(ctx, count, scope);
    // (verify ordinal; const-ness is enforced at fold time — error there
    //  if eval_const fails)
}
```

Note the running index `i` no longer maps 1:1 to array position once `Repeat`
expands. For *type checking* the per-position lookup is only needed for records;
for arrays `elem_ty` is constant, so `i` is irrelevant. For the record-with-`BY`
case (out of scope for the failing test) the position accounting would need to
advance by `count`; recommend rejecting record-level `BY` with a clear diagnostic
in v1 and revisiting if a test needs it.

**Prefill** (`analyze.rs:2119`): add
`SetElem::Repeat(e, c) => { prefill(e); prefill(c); }`.

**Aggregate constant evaluation** (`eval_aggregate_const`, `analyze.rs:2337`):
this is the core expansion. Restructure the element loop so each element can
contribute *zero or more* folded values:

```rust
for elem in elements.iter() {
    let (inner, repeat): (&ast::Expr, usize) = match elem {
        ast::SetElem::Single(e) => (e, 1),
        ast::SetElem::Repeat(e, count_expr) => {
            let lookup = |n: &str| consts.get(n).cloned();
            let n = eval_const(count_expr, &lookup).ok()?.as_int()?;
            if n < 0 { return None; }   // diagnostic upstream
            (e, n as usize)
        }
        ast::SetElem::Range(..) => return None,
    };
    // expected element type for this run:
    let ety = /* array base, or field type — see note below */;
    let folded = if let Some(agg) =
        eval_aggregate_const(ctx, scope, inner, ety, consts) {
        agg
    } else {
        let lookup = |n: &str| consts.get(n).cloned();
        eval_const(inner, &lookup).ok()?
    };
    for _ in 0..repeat {
        // CHAR-array spread: a string element fills consecutive CHAR cells.
        if char_array_base && let ConstValue::Str(s) = &folded {
            if s.is_empty() {
                // `"" BY 80` => 80 NUL cells (one per repeat); a non-empty
                // string would spread its chars then this repeat advances.
                vals.push(ConstValue::Char('\0'));
            } else {
                for ch in s.chars() { vals.push(ConstValue::Char(ch)); }
            }
        } else {
            vals.push(folded.clone());
        }
    }
}
```

Key subtlety for `"" BY 80`: the empty string spreads to **zero** chars under the
existing `for ch in s.chars()` logic, so a naive reuse would yield 0 cells, not 80.
The repeat must emit one NUL per count when the string is empty. The cleanest model:
treat `"" BY 80` as "the CHAR value `'\0'`, repeated 80 times". This produces an
`Aggregate` of exactly 80 `Char('\0')` — matching the ISO spec's blanked 80-char buffer and
filling the whole `ARRAY [0..79] OF CHAR`. (`'X' BY 80` yields 80 `Char('X')`.)

Because `nestediso.mod` uses `StringType{"" BY 80}` as a **constant-foldable**
sub-constructor inside `PersonType{...}` and the surrounding `person := ...`
assignment has all-constant components on line 41, the entire RHS can fold to a
`ConstValue::Aggregate` and lower via the const-init path with no runtime loop.
(Lines 42–45 mix in runtime values where applicable and exercise the runtime path,
already supported once parsing succeeds.)

### (4) Lowering

**Set path** (`lower.rs:2532`) and **set const-fold** (`constant.rs:172`): add a
`SetElem::Repeat` arm. A repeat in a *pure set* `{x BY n}` is not standard set
syntax; emit a sema error ("BY repetition is only valid in array constructors") and
treat the arm as a no-op for codegen so the `match` is exhaustive and the compiler
still builds. (Alternatively, accept it as "include x" once — but rejecting is
clearer.)

**Aggregate path** (`lower_aggregate_constructor`, `lower.rs:2651`): replace the
`let Single(value) = elem else { continue }` (`:2671`) with a handler that supports
`Repeat`. Since the count is constant, fold it and emit the body `count` times,
reusing the *existing* per-element store / CHAR-WCopy logic:

```rust
for elem in elements {
    let (value, repeat): (&ast::Expr, i128) = match elem {
        ast::SetElem::Single(v) => (v, 1),
        ast::SetElem::Repeat(v, c) => (v, self.const_count(c)?),  // constant
        ast::SetElem::Range(..) => continue,   // not valid here
    };
    for _ in 0..repeat {
        // ... existing body: compute IndexPtr/FieldPtr at `field`,
        //     WCopy for CHAR-array string element, else Store;
        //     then field += 1 ...
    }
}
```

`const_count` evaluates the count via the sema const machinery (it is guaranteed
constant by sema). For an array element type this advances `field` by 1 per copy.

**Critical runtime detail for `"" BY 80` on the runtime path:** the destination
slot is an un-zeroed `Alloca` (`:2668`), and `nm2_copy_wstring` only writes one NUL
for an empty source (`strings.rs:108`). Two viable approaches:

- **Preferred:** because `count` is constant, unroll into `count` *element-level*
  stores of `CHR(0)` for `"" BY 80` (i.e. treat the repeated empty-string element as
  a CHAR `'\0'` store per position, exactly as the const path does), writing all 80
  cells explicitly. This keeps lowering uniform with the const-fold model and needs
  no zero-fill of the alloca.
- **Alternative:** zero the whole slot once (a `memset`/`Inst` fill) before storing
  elements when any `Repeat` of an empty string is present. More general but adds a
  fill primitive; only needed if non-constant fills ever appear (they cannot here).

Given the test is fully constant-foldable, the runtime path is a secondary concern;
implement the unrolled-store form so runtime `name BY n` (e.g. with a non-constant
*element* but constant count) also works.

---

## Implementation plan (ordered, concrete)

1. **AST** — add `SetElem::Repeat(Expr, Expr)` at
   `src/newm2-parser/src/ast.rs:361`. This breaks every non-exhaustive `SetElem`
   match; the compiler error list is the to-do list for the rest of the steps.
2. **Parser** — in `parse_set_constructor` (`parser.rs:2123`) add the
   `else if eat_kind(Keyword::By)` branch producing `Repeat`. Add a parser unit
   test (`src/newm2-parser/tests/`) asserting `Type{ x BY 3 }` parses to one
   `Repeat` element.
3. **Sema compile-fixes (exhaustiveness)** — add `Repeat` arms to:
   - `prefill_type_builtins` `Expr::Set` walk (`analyze.rs:2119`).
   - `eval_const` `Expr::Set` arm (`constant.rs:172`) — for a pure set, return an
     `EvalError` ("BY not valid in a set constructor"); the aggregate path never
     reaches here.
   - the set lowering loop (`lower.rs:2532`) — emit sema error / no-op.
4. **Sema type-check** — `analyse_expr` structured arm (`analyze.rs:4427`): add
   `Repeat` arm checking the element against the field/element type and requiring
   `count` to be a constant non-negative ordinal (error otherwise). Reject
   record-level `BY` for now with a targeted message.
5. **Sema const-fold** — rework `eval_aggregate_const` element loop
   (`analyze.rs:2337`) to expand `Repeat` into `count` folded values, with the
   empty-string-CHAR special case yielding `count` `Char('\0')` cells. Verify
   `StringType{"" BY 80}` folds to an 80-element `Aggregate`.
6. **IR lowering (aggregate)** — rework `lower_aggregate_constructor`
   (`lower.rs:2671`) to unroll `Repeat` into `count` per-element stores/WCopies,
   advancing `field` each copy; handle the empty-string element as a `CHR(0)` store
   per position so the runtime path matches the const path. Confirm the const-init
   path (`emit_const_value`, `lower.rs:2576`) already covers the fully-constant case
   once folding works.
7. **Enable the conformance test** — wire `nestediso.mod` into the ISO run/pass
   corpus runner and confirm it passes (no expected output file is needed beyond a
   clean run; the corpus's `pass/` tests assert successful execution).
8. **Add a focused JIT test** — `Mod/tests/t-90-1xx-by-repeat.mod` (below).

Steps 1–6 are a single logical change set; steps 3–6 are forced by the step-1
enum variant.

---

## Test plan

### Conformance: `nestediso.mod`
Enable `nestediso.mod` in the external conformance corpus. Success
criterion: compiles + runs to completion. It exercises:
- `StringType{"" BY 80}` (const-foldable array-of-char fill) — line 41.
- the same `PersonType` constructor in already-supported spellings — lines 42–45.

### Self-contained JIT test (`Mod/tests/t-90-1xx-by-repeat.mod`)
Mirror the existing aggregate-constructor test style (`EXPECTED:` header block, as
in `Mod/tests/t-90-174-const-char-array-fill.mod`). Proposed content:

```modula2
MODULE T90XXXByRepeat;
(*
 * Group 90 — constructors
 * Test: `element BY count` repeat syntax in array constructors, including a
 *       blanked ARRAY OF CHAR via `"" BY n` and a repeated CHAR value.
 *
 * EXPECTED:
 * 7 7 7 7 7
 * X X X
 * len=0
 *)
FROM SWholeIO IMPORT WriteCard;
FROM StrIO   IMPORT WriteString, WriteLn;
FROM Strings IMPORT Length;   (* or measure via a manual scan *)

TYPE
  Fives  = ARRAY [0..4] OF CARDINAL;
  Line80 = ARRAY [0..79] OF CHAR;
  Three  = ARRAY [0..2] OF CHAR;

VAR
  f : Fives;
  s : Line80;
  t : Three;
  i : CARDINAL;
BEGIN
  f := Fives{ 7 BY 5 };                 (* runtime/const: 5 copies of 7 *)
  FOR i := 0 TO 4 DO
    WriteCard(f[i], 0); IF i < 4 THEN WriteString(" ") END
  END; WriteLn;

  t := Three{ 'X' BY 3 };               (* 3 copies of 'X' *)
  WriteString(t); WriteLn;              (* prints: XXX -> shown as X X X via spacing? keep simple: XXX *)

  s := Line80{ "" BY 80 };              (* the failing-test case: 80 NUL cells *)
  WriteString("len="); WriteCard(Length(s), 0); WriteLn   (* len=0 *)
END T90XXXByRepeat.
```

(Adjust the exact `EXPECTED` text to whatever `WriteString(t)` yields — the load-
bearing assertions are: the five `7`s, three `X`s, and that the blanked 80-char
buffer has length 0 because cell 0 is NUL.)

Also recommended:
- A **CONST** variant exercising the const-fold path:
  `CONST blank = Line80{ "" BY 80 };` then assign and measure — verifies
  `eval_aggregate_const` expansion and the `ConstVal::Aggregate` lowering.
- A parser unit test in `src/newm2-parser/tests/` asserting the AST shape of
  `Type{ x BY 3 }`.
- A negative test: `BITSET{ 1 BY 3 }` (or `{1 BY 3}`) should produce the
  "BY not valid in a set constructor" diagnostic, not a crash.

---

## Risks / open questions

1. **Record-level `BY`.** ISO permits `BY` against consecutive record fields, but
   it is rarely used and not needed by `nestediso.mod`. v1 should reject it with a
   clear diagnostic to avoid mis-aligning field offsets; revisit if a corpus test
   requires it. (Array and array-of-char are the supported cases.)
2. **`count = 0`.** `x BY 0` contributes zero elements. The fold/loop handle this
   naturally (empty range), but confirm an all-zero constructor doesn't desync the
   array-length check elsewhere. Negative counts must be a diagnostic.
3. **Empty-string fill on the runtime path.** `nm2_copy_wstring`
   (`strings.rs:108`) does **not** blank a whole buffer for an empty source. The
   design avoids relying on it by unrolling `"" BY n` into `n` explicit `CHR(0)`
   element stores. If a future feature needs runtime non-constant fills, a slot
   zero-fill primitive (memset) would be required — out of scope here.
4. **Un-zeroed alloca.** `lower_aggregate_constructor`'s slot is uninitialised
   (`lower.rs:2668`). With explicit per-position stores for every `Repeat` copy this
   is fine; but an array constructor that under-fills its array (fewer positions
   than the array length) already leaves trailing garbage today — `BY` does not
   make this worse, and the const path always fills exactly. Worth a note, not a
   blocker.
5. **String element interaction.** A non-empty repeated string element
   (`"AB" BY 3`) is ambiguous: does it mean 3 copies of the 2-char run (6 cells) or
   is it disallowed? The reference implementation treats the array component as a single element repeated;
   for a CHAR array the natural reading is "spread `AB`, then repeat that run".
   Recommend supporting it as "spread the string then repeat the whole spread"
   (consistent with the const-fold loop above), but the failing test only needs the
   empty-string case, so over-engineering here is a risk — keep it minimal and
   document the chosen semantics.
6. **Set constructor `BY`.** Some dialects might tolerate `BY` in a set; NewM2 will
   reject it. If a corpus test surfaces a legitimate set-level use, revisit. Low
   probability.
7. **Index `i` vs. position.** In the structured type-check arm (`analyze.rs:4427`)
   the loop index `i` is currently used for record field lookup. With `Repeat`
   expanding positions, `i` no longer equals the array position; harmless for arrays
   (constant element type) but must be accounted for if record-level `BY` is later
   enabled.
