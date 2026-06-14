# Multi-dimensional open arrays — design

Status: **not yet implemented** (design only). No source files are modified by
this document.

## Summary

NewModula2 supports 1-dimensional open arrays (`ARRAY OF T`) end-to-end: a data
pointer plus a synthesised `i64` HIGH companion travels alongside each open-array
argument, `HIGH`/`LEN`/indexing read that companion, and a *fixed* array can bind
to such a parameter. It does **not** support multi-dimensional open arrays —
`PROCEDURE p (VAR a: ARRAY OF ARRAY OF CHAR)` and passing
`ARRAY [0..4],[0..5] OF CHAR` to it. Today this is rejected in sema with
"argument type is not assignment-compatible with parameter".

This document proposes the ISO-compatible representation and the changes across
sema, IR lowering, and LLVM codegen to make N-dimensional open arrays work. The
core model is the reference implementation's: a single data pointer to **row-major flat** storage, plus
**one `i64` HIGH companion per open dimension**. `HIGH(a)` is the dim-0 bound,
`HIGH(a[0])` the dim-1 bound, and `a[i,j] = data[i*(HIGH1+1) + j]` — strides come
from the *runtime* companions, not static bounds.

## Failing tests & current behavior

Both live in the external conformance corpus (`iso/run/pass`) and are run by the
conformance harness (`tests/newm2-conformance/src/lib.rs:86`, category
`iso/run/pass`, `Kind::Run`).

- `iso/run/pass/unbounded.mod:34` —
  ```
  PROCEDURE test (VAR a: ARRAY OF ARRAY OF CHAR) ;
  BEGIN m := HIGH(a) ; n := HIGH(a[0]) ; a[1,2] := 'a' ; a[2,1] := 'c' END test ;
  VAR b : ARRAY [0..4], [0..5] OF CHAR ; ... test(b)
  ```
  Expected runtime output `m = 4, n = 5`, then `b[1,2]='a'`, `b[2,1]='c'`,
  every other cell still `'z'`.
- `iso/run/pass/unbounded2.mod:33` — same `test` shape; additionally passes a
  second actual `c: ARRAY BOOLEAN OF ARRAY BOOLEAN OF CHAR` (`unbounded2.mod:44`,
  `:49`) — exercising a **non-INTEGER, non-zero-stride** index type (BOOLEAN,
  count 2) in both dimensions.

**Current behavior — where it fails.** The call `test(b)` runs
`analyse_call_args` (`src/newm2-sema/src/analyze.rs:3656`), which calls
`expr_compatible_with_type(param.ty, arg, arg_ty)` (`:3663`). The parameter type
is `OpenArray{ base: OpenArray{ base: Char } }` and the actual is
`Array{ indices:[sub0,sub1], base: Char }`.

- `types_compatible` (`analyze.rs:3157`) reaches the open-array branch at
  `analyze.rs:3209`:
  ```rust
  (TypeKind::OpenArray { base: e }, TypeKind::OpenArray { base: a })
  | (TypeKind::OpenArray { base: e }, TypeKind::Array { base: a, .. }) =>
      types_compatible(ctx, *e, *a),
  ```
  Here `e = OpenArray{Char}` (the *outer* open array's base) and `a = Char` (the
  fixed array's element). `types_compatible(OpenArray{Char}, Char)` is false — it
  compares one open level against the scalar element and never accounts for the
  fixed array carrying *two* index dimensions in a single node. Returns false.
- `expr_compatible_with_type`'s fallback array branch (`analyze.rs:3259`) has the
  same one-level shape: it pulls `eb` from the expected's single `base` and
  compares `types_compatible(eb, base)` against the actual's single `base`
  (`analyze.rs:3266`). Same mismatch (`OpenArray{Char}` vs `Char`), false.

So sema emits the diagnostic at `analyze.rs:3665` and lowering/codegen are never
reached. (Note: the *indexing* and *HIGH* analysis in sema already tolerate the
nested/multi-dim shapes — see below — so the block is purely the arg-compat gate.)

## Modula-2 semantics (ISO model)

- An open-array formal `ARRAY OF ARRAY OF CHAR` has rank 2: two open
  dimensions. Generally `ARRAY OF (ARRAY OF){n} T` has rank `n+1`.
- The actual may be any array whose **flattened element type is `CHAR`** and
  whose **total rank matches** the formal's rank: a fixed `ARRAY [..],[..] OF CHAR`
  (rank 2 in one node), a fixed `ARRAY [..] OF ARRAY [..] OF CHAR` (rank 2 across
  two nodes), or another open `ARRAY OF ARRAY OF CHAR`. The ISO spec matches by
  *(total dimension count, scalar element type)*, ignoring the specific bounds
  and how the dimensions are distributed across nodes.
- The actual's storage is **row-major contiguous**. A fixed
  `ARRAY [0..4],[0..5] OF CHAR` is 5×6 = 30 contiguous CHAR cells; the open
  array sees the same flat block.
- The callee receives, per open dimension `d` (0-based), the number
  `HIGH_d = (count of dimension d) − 1`. For `b` above: `HIGH_0 = 4`, `HIGH_1 = 5`.
- `HIGH(a)` = `HIGH_0`. `HIGH(a[0])` = `HIGH_1`. In general `HIGH(a[i0..i_{k-1}])`
  after fixing the first `k` indices = `HIGH_k`.
- Indexing flattens with the runtime strides:
  `a[i,j] = data[ i*(HIGH_1+1) + j ]`. For rank `n`,
  `flat = Σ_{k} i_k · Π_{m>k} (HIGH_m + 1)`. Index types need not be zero-based or
  INTEGER (e.g. `ARRAY BOOLEAN OF …` in unbounded2) — the *companion* already
  encodes count−1, and the per-dimension lower bound subtraction is the actual's
  concern, applied at the call site when computing companions (a fixed array with
  lower bound `lo` still occupies `hi−lo+1` cells starting at element 0 of its
  storage, so `HIGH_d = hi−lo`).

## Current NewM2 representation (file:line)

### Types

- `TypeKind::Array { indices: Vec<TypeId>, base }` — a closed array. A single node
  can carry **several** dimensions: `ARRAY [0..4],[0..5] OF CHAR` parses
  (`src/newm2-parser/src/parser.rs:1328`) to `Array(indices=[sub0,sub1], base=Char)`
  and `form_type_expr` builds exactly that (`analyze.rs:2548`). Definition:
  `src/newm2-sema/src/types.rs:44`.
- `TypeKind::OpenArray { base }` (`types.rs:48`). `ARRAY OF ARRAY OF CHAR` parses
  (`parser.rs:1320`, recursive `parse_type_expr` on the base) to
  `OpenArray(OpenArray(Char))` and `form_type_expr` (`analyze.rs:2556`) builds
  `OpenArray{ base: OpenArray{ base: Char } }`. **A node carries exactly one open
  dimension; rank comes from nesting depth.**

### Sema — what already works for multi-dim

- **Indexing** `a[1,2]` on a nested open array: `analyse_selector_chain`'s Index
  arm (`analyze.rs:3523`) consumes one dimension per index, crossing node
  boundaries (`analyze.rs:3530`–`3570`). For an `OpenArray`, `ndims = 1`
  (`:3545`), it peels one level (`elem_ty = base`, `:3568`) and loops, so
  `a[1,2]` on `OpenArray{OpenArray{Char}}` correctly yields `Char`. Partial
  indexing yields a lower-rank sub-array (`:3565`).
- **`HIGH(a)` / `HIGH(a[0])`** type to `CARDINAL` (`analyze.rs:4056`), independent
  of rank.

So **sema analysis of the body is already rank-agnostic**; only the *arg-compat
gate* rejects the call.

### IR lowering — the 1-D open-array ABI

- Companion name: `open_array_high_name(n) = "{n}$high"` (`lower.rs:276`).
- `is_open_array_ty` (`lower.rs:281`) — matches `OpenArray { .. }` (one level).
- **Callee signature:** for each open-array formal, an extra `i64` `{name}$high`
  param is appended right after the array pointer (`lower.rs:779`–`791`, proc;
  `lower.rs:939`–`951`, method; captures `lower.rs:845`–`851`). **One companion
  only.**
- **Callee prologue / slots:** each param (including each `$high`) gets one
  pre-alloca'd stack slot, in order; an open-array param's slot is `Indirect`
  and holds the *data pointer* (`lower.rs:1282`–`1295`). The `$high` companion is
  a normal local found under `"{name}$high"`.
- **`local_ptr`** for an open-array Indirect binding loads the slot to get the
  data base, untyped, and lets indexing supply the element type
  (`lower.rs:1447`).
- **Call site:** `formal_open` path (`lower.rs:3894`–`3959`). Pushes the data
  pointer (`eval_lvalue` for a designator — `&array[0]` for a fixed array, the
  forwarded data pointer for an open param via its Indirect slot — `:3917`), then,
  for native callees, pushes **one** HIGH via `eval_actual_high` (`:3956`).
- **`eval_actual_high`** (`lower.rs:4171`): string → len−1; forwarded open param →
  load its `$high` slot (`:4180`); fixed array → `fixed_array_high` reads the
  **first** dimension's static `hi−lo` (`:4188`, `fixed_array_high` at `:4219`,
  using only `indices.first()` at `:4227`); else element-count−1 of the first dim
  (`:4196`) or 0.
- **`HIGH`/`LEN` builtin** (`lower.rs:4239`–`4265`) just calls `eval_actual_high`
  on the single argument designator. **It only handles a bare name
  (`c.base.segments.len()==1`, no selectors at `:4245`, arg is a plain
  designator).** `HIGH(a[0])` — a designator *with* an index selector — is **not**
  intercepted here and falls through to general call lowering.

### IR lowering — multi-dim *fixed* indexing (the stride machinery to reuse)

`apply_selector` Index arm (`lower.rs:4798`–`4868`): for a fixed array it
flattens row-major,
`flat = Σ_k (i_k − lo_k)·Π_{m>k} count_m`, with per-dimension lower-bound
subtraction (`dim_lo`, `:4899`), bounds checks (`:4838`), and **static** strides
`Π count_m` from `dim_count` (`:4907`, reads subrange `hi−lo+1` or enum
`names.len()`). Partial indexing is supported. **For an open array `dims` is
empty (`:4803`), so it falls back to `self.eval_expr(&indices[0])`** — the raw
first index, no stride, no multi-index support. This is the central codegen gap.

`selector_result_type` Index arm (`lower.rs:1551`): for `OpenArray{base}` returns
`Some(*base)` regardless of index count (`:1565`) — i.e. one `Index` selector
peels exactly one open level, which is wrong when the selector carries multiple
indices into a nested open array (`a[1,2]` should peel two).

### LLVM codegen

- `OpenArray` lowers to a bare pointer (`codegen.rs:213`).
- Native ABI param expansion: each open-array param emits `ptr` then an `i64`
  HIGH, **unless lowering already appended an explicit `…$high`** companion
  (detected at `codegen.rs:314`–`320`); the indirect (proc-pointer) ABI adds one
  `i64` unconditionally per open param (`codegen.rs:345`). **Both assume exactly
  one companion per open param.**
- Param→slot binding is **positional**: each IR param (including each `$high`)
  maps to the i-th alloca and codegen stores `get_nth_param(i)` into it
  (`codegen.rs:826`–`847`). So adding more companions "just works" provided
  lowering pre-allocas a slot per companion in matching order (it does — every
  IrParam gets a slot at `lower.rs:1282`).
- `IndexPtr` GEPs `elem_ty*` from the base (`codegen.rs:997`–`1018`) — a single
  linear index. The multi-dim flatten happens in lowering before this; codegen
  needs no change for indexing.

## Proposed design

### Representation / ABI

Generalise the 1-D ABI to N companions, ISO-style:

- A rank-`r` open-array formal `a` is passed as: `a` (data `ptr`), then
  `a$high`, `a$high1`, …, `a$high{r-1}` — `r` `i64` companions, in dimension
  order. Naming: keep `{n}$high` for dimension 0 (backward compatible with the
  1-D path) and `{n}$high{d}` for `d ≥ 1`.
- Storage is row-major flat; the data pointer addresses element 0. Indexing uses
  the **runtime** companions for strides: stride over dimension `k` is
  `Π_{m>k} (high_m + 1)`.
- `HIGH(a)` loads `a$high`; `HIGH(a[i0…i_{k-1}])` loads `a$high{k}`.

### (1) Sema compatibility

Add a rank-and-element matcher and use it in both `types_compatible` (open-array
branch, `analyze.rs:3209`) and `expr_compatible_with_type` (`analyze.rs:3259`).

Define two helpers over `TypeKind`:

- `open_rank_and_elem(ty) -> Option<(usize, TypeId)>`: count nested
  `OpenArray` levels and return `(rank, scalar_elem)`.
  `OpenArray{OpenArray{Char}}` → `(2, Char)`.
- `array_rank_and_elem(ty) -> Option<(usize, TypeId)>`: walk a fixed/open actual,
  summing dimensions across nodes —
  `Array{indices, base}` contributes `indices.len()` then recurses into `base`;
  `OpenArray{base}` contributes 1 then recurses; a scalar terminates. So
  `Array{[sub0,sub1], Char}` → `(2, Char)`,
  `Array{[s], Array{[t], Char}}` → `(2, Char)`,
  `OpenArray{OpenArray{Char}}` → `(2, Char)`.

Compatibility rule (open formal vs array actual):
```
let (er, ee) = open_rank_and_elem(expected)?;     // expected is the formal
let (ar, ae) = array_rank_and_elem(actual)?;
er == ar && types_compatible(ee, ae)
```
For rank 1 this reduces to the existing behaviour (so the 1-D path is unchanged).
Keep the existing single-CHAR / string-literal leniency branches
(`analyze.rs:3271`, `:3281`, `:3294`) as-is; they apply only at the innermost
element level.

Edge cases to preserve:
- `ARRAY OF SYSTEM.LOC/BYTE/WORD` raw-storage view (`is_loc_view_param`,
  `analyze.rs:3613`, gate at `analyze.rs:3662`) stays rank-1 storage view; do not
  let the rank matcher hijack it.
- A rank mismatch (e.g. passing a 1-D array to a 2-D open formal) must still be a
  diagnostic — the `er == ar` check guarantees this.

No new `TypeKind` is needed; representation is unchanged.

### (2) Lowering ABI — N companions

**Callee signature** (`lower.rs:777`–`791`, and mirror at method `:937`–`951`,
captures `:843`–`851`): replace the single-companion append with a loop over the
formal's rank. Add:
```
fn open_rank(sema, ty) -> usize   // nested OpenArray depth; 0 if not open
fn open_array_high_name_d(n, d) -> String  // d==0 -> "{n}$high", else "{n}$high{d}"
```
For a rank-`r` open formal, push the array `IrParam` then `r` `i64` companions
named `…$high`, `…$high1`, …. (`is_open_array_ty` stays the rank≥1 predicate;
add `open_rank` for the count.)

**Callee slots** (`lower.rs:1282`): the param loop already pre-allocas one slot
per IrParam in order, so each companion gets its own slot and `locals` entry
automatically. No change needed beyond the names being emitted by the signature
builder. The open-array param slot stays `Indirect` holding the data pointer.

**Call site** (`lower.rs:3894`–`3959`): after pushing the data pointer, replace
the single `eval_actual_high` push with a loop pushing `r` companions in
dimension order, where `r = open_rank(formal.ty)`. Each companion `d` is the
HIGH of the actual's `d`-th flattened dimension:

- New `fn actual_high_dim(arg, d) -> ValueId`, generalising `eval_actual_high`:
  - **Forwarded open param** (actual is a bare open-array param `x` of rank ≥ r):
    load `x$high{d}` from locals (the existing single-companion load at
    `lower.rs:4180` becomes the `d==0` case).
  - **Fixed array designator**: the `d`-th flattened dimension's static
    `hi−lo`. Generalise `fixed_array_high` (`lower.rs:4219`) to walk
    `Array.indices` across node boundaries (like `array_rank_and_elem`) and pick
    the `d`-th `Subrange`/enum dimension, returning a `Const{Int}` of `count−1`.
  - **String CONST / char** path (`lower.rs:3898`–`3911`): only valid for rank 1;
    unchanged.
- LOC-view (`byte_view_high`, `lower.rs:4135`) remains rank-1 only.

**Captures** (`lower.rs:4010`–`4018`): pushing capture companions
(`capture_high`, `:4038`) must likewise loop `d` over the capture's rank, loading
`{name}$high{d}`.

### (3) Codegen indexing with runtime strides

Two changes, both in IR lowering (codegen's `IndexPtr` is already a generic
linear GEP and needs no change):

**a. `apply_selector` Index arm (`lower.rs:4798`).** Currently the open-array
case can't see the companions because it only receives the data-pointer `ValueId`
and `base_ty`. Give it access to the runtime HIGHs. The cleanest path:

- Detect the open-array multi-index case *before* the data pointer is loaded, in
  `eval_lvalue` (`lower.rs:4636`): when the base names an open-array param/capture
  of rank `r` and the next selector is an `Index` with `k` indices, compute the
  flat index using the companions read from `…$high{m}` slots, then emit a single
  `IndexPtr`. Concretely, for indices `i_0..i_{k-1}`:
  ```
  // stride_k = Π_{m=k}^{r-1} (high_m + 1)   (load high_m from {name}$high{m})
  // flat = Σ_{k} i_k * stride_{k+1}
  ```
  build the products with `Inst::Binary { Mul }` and `Inst::Const{Int(1)}` for
  the +1, accumulate with `Add`, then `IndexPtr { base: data_ptr, index: flat,
  elem_ty }`. `elem_ty` is the scalar element (peel `r` open levels) when fully
  indexed, or the row element when partially indexed.
- Pass the open-array name (or its companion `ValueId`s) into the index
  computation. Practical approach: keep the flatten logic in `eval_lvalue`/a new
  `open_array_index_ptr(name, data_ptr, indices, base_ty)` helper that has the
  designator base name in hand (so it can look up `{name}$high{m}` in `locals`),
  rather than inside the name-blind `apply_selector`. `apply_selector`'s existing
  fixed-array branch (static strides) stays for fixed arrays.

This mirrors the existing fixed-array flatten (`lower.rs:4817`) but substitutes
**runtime** `(high_m+1)` for the static `dim_count`. Lower-bound subtraction is
**not** applied here (the actual's lower bounds were already folded into the
companions at the call site), matching the ISO spec — index `i_k` is used directly.

**b. `selector_result_type` Index arm for `OpenArray` (`lower.rs:1565`).** Make
it peel one open level **per index** in the selector, not one per selector, so a
partial vs full index produces the right rank for the element-type the GEP uses:
```
TypeKind::OpenArray { .. } => {
    // peel `indices.len()` nested OpenArray levels; return the scalar/base or
    // the residual OpenArray for a partial index.
}
```

**Bounds checks.** The fixed-array path bounds-checks each index against its
static `count` (`lower.rs:4838`). For open dimensions the bound is the runtime
`high_m`; emit an analogous `0 <= i_k <= high_m` check guarded by
`self.ctx.runtime_checks`, reusing the companion value already loaded for the
stride. (Optional for first cut; the corpus's `pass` tests don't require it, but it
keeps parity with fixed arrays.)

### (4) `HIGH(a[k])` resolution

`lower_high_len_builtin` (`lower.rs:4239`) currently bails on any argument that
isn't a bare single-segment designator (`:4252` requires a `Designator`; the
designator must be index-free for `eval_actual_high`'s open-param branch to fire
at `:4179`). Extend it:

- `HIGH(a)` where `a` is an open param of rank `r`: load `a$high` (dim 0).
  Unchanged.
- `HIGH(a[i0…i_{k-1}])`: the argument designator has `k` leading index positions
  on an open-array base. Resolve to `a$high{k}` — load the `k`-th companion slot.
  Implement by inspecting the arg designator: if its base is an open-array
  param/capture and it has a single `Index` selector with `k` indices (or `k`
  successive single-index selectors), return the load of `{name}$high{k}`.
  `unbounded.mod` uses `HIGH(a[0])` → `k = 1` → `a$high1`.
- `LEN` = `HIGH + 1` as today (`lower.rs:4259`).

Because the companions already encode each dimension's `count−1`, no arithmetic
beyond selecting the right slot is needed.

## Implementation plan (ordered, concrete)

1. **Sema — compatibility (unblocks the diagnostic).**
   - Add `open_rank_and_elem` and `array_rank_and_elem` helpers near
     `types_compatible` (`analyze.rs:3157`).
   - In `types_compatible` open-array branch (`analyze.rs:3209`) and in
     `expr_compatible_with_type`'s array branch (`analyze.rs:3259`), replace the
     one-level `types_compatible(eb, base)` with the rank-equal + element-compatible
     test. Preserve the `is_loc_view_param` gate (`analyze.rs:3662`) and the
     scalar-CHAR/string-literal leniency.
   - At this point sema accepts `test(b)`; body analysis already handles
     `a[1,2]`/`HIGH(a)`/`HIGH(a[0])` (`analyze.rs:3523`, `:4056`). Lowering will
     still mis-handle strides/companions — expect wrong runtime values, not a
     sema error. Good checkpoint.

2. **Lowering — ABI plumbing (N companions).**
   - Add `open_rank(sema, ty)` and `open_array_high_name_d(n, d)` near
     `lower.rs:276`/`:281`.
   - Callee signature loops: proc (`lower.rs:777`), method (`lower.rs:937`),
     captures (`lower.rs:843`) — push `r` companions.
   - Call site (`lower.rs:3950`): push `r` companions via the generalised
     `actual_high_dim`; generalise `fixed_array_high` (`lower.rs:4219`) to walk
     dimensions across nodes and index by `d`; generalise the forwarded-param
     branch of `eval_actual_high` (`lower.rs:4178`) to `{name}$high{d}`.
   - Capture companion push (`lower.rs:4010`) loops `d`.

3. **Codegen — ABI param count.**
   - Native ABI expansion (`codegen.rs:306`–`321`): the "next is companion"
     detection (`:314`) already consumes pre-emitted `…$high*` params; confirm it
     skips **all** `$high{d}` names (its `ends_with("$high")` test must also match
     `…$high1`). Simplest: have lowering always pre-emit the companions (it will,
     per step 2) and make codegen's auto-append a no-op when companions are
     present — i.e. detect any `name.contains("$high")` follower, or just rely on
     the explicit params and drop the auto-append for multi-rank. Verify the
     positional param→slot store (`codegen.rs:839`) lines up (one slot per
     companion — guaranteed by `lower.rs:1282`).
   - Indirect/proc-pointer ABI (`codegen.rs:333`–`353`): add `r` `i64`s per open
     param using `open_rank` rather than a single `i64` (`:345`). (Only needed if
     multi-dim open arrays are called through procedure variables; lower priority.)

4. **Lowering — runtime-stride indexing.**
   - Add `open_array_index_ptr` (new helper) and call it from `eval_lvalue`
     (`lower.rs:4636`) when the base is an open-array param/capture and the next
     selector is an `Index`. Compute `flat` from runtime `{name}$high{m}` loads as
     specified; emit one `IndexPtr`.
   - Fix `selector_result_type` `OpenArray` Index arm (`lower.rs:1565`) to peel
     `indices.len()` open levels.
   - (Optional) open-dimension bounds checks under `runtime_checks`.

5. **Lowering — `HIGH(a[k])`.**
   - Extend `lower_high_len_builtin` (`lower.rs:4239`) to accept an indexed
     open-array designator and return the load of `{name}$high{k}`.

6. **Run conformance + JIT tests** (below); iterate.

## Test plan

### Conformance corpus (primary)

- `iso/run/pass/unbounded.mod` and `iso/run/pass/unbounded2.mod`, via the
  conformance harness category `iso/run/pass`
  (`tests/newm2-conformance/src/lib.rs:86`). These are the acceptance criteria;
  `unbounded2` additionally pins the BOOLEAN-indexed (`ARRAY BOOLEAN OF …`) case
  so non-zero-based / non-INTEGER strides are covered.

### Self-contained JIT test (fast inner loop)

Add `Mod/tests/t-40-070-multidim-open.mod` and register a `#[test]` in
`tests/newm2-tests/tests/m2_tests.rs` with `check("t-40-070-multidim-open.mod", …)`
(model: the open-array test `t-70-050-proc-openarray.mod`, the multidim fixed test
`t-40-030-multidim-array.mod`, and the `#[test]`+`check(...)` pattern at
`m2_tests.rs:348`). Sketch:

```
MODULE t40070;
IMPORT STextIO, SWholeIO;
VAR b: ARRAY [0..2], [0..3] OF CHAR;  i, j: CARDINAL;
PROCEDURE test (VAR a: ARRAY OF ARRAY OF CHAR);
BEGIN
  SWholeIO.WriteCard(HIGH(a), 0); STextIO.WriteLn;      (* 2 *)
  SWholeIO.WriteCard(HIGH(a[0]), 0); STextIO.WriteLn;   (* 3 *)
  a[1,2] := 'X'; a[2,0] := 'Y';
END test;
BEGIN
  FOR i := 0 TO 2 DO FOR j := 0 TO 3 DO b[i,j] := 'z' END END;
  test(b);
  STextIO.WriteChar(b[1,2]); STextIO.WriteChar(b[2,0]);
  STextIO.WriteChar(b[0,0]); STextIO.WriteLn;           (* XYz *)
END t40070.
```
Expected output (the `check` string):
```
2
3
XYz
```
This exercises: sema compatibility (fixed 2-D → 2-D open VAR), two HIGH
companions, `HIGH(a)` / `HIGH(a[0])`, runtime-stride write-back into the caller's
storage, and that untouched cells are preserved. Adding a second helper that
*forwards* its open param to `test` would additionally cover the
forwarded-companion (`{name}$high{d}` load) path; worth a follow-up case.

## Risks / open questions

- **`apply_selector` is name-blind.** It receives only the data pointer and
  `base_ty`, so it cannot reach the `…$high{d}` slots. The design routes the
  open-array multi-index flatten through `eval_lvalue` (which still has the
  designator base name). Risk: r-value indexing paths (`eval_expr` of a designator
  used as a value) must funnel through the same helper, or they'll re-hit the
  name-blind fallback (`lower.rs:4863`) and produce a wrong (un-strided) index.
  Audit every caller that indexes an open-array value, not just lvalue stores.
- **Companion ordering must be exact.** Codegen binds params to slots positionally
  (`codegen.rs:839`); any mismatch between the order lowering emits companions and
  the order codegen/`llvm_fn_type_with_abi` expects them will silently corrupt the
  ABI. The 1-D `next_is_companion` guard (`codegen.rs:314`) must be re-checked for
  `$high1`, `$high2`, … followers.
- **Non-zero / non-INTEGER index bounds.** Lower-bound subtraction is deliberately
  *not* applied inside the open-array flatten (the actual's bounds are folded into
  the companions at the call site). Must confirm a fixed actual with a non-zero
  lower bound (e.g. `ARRAY [1..3],[1..4] OF CHAR`) passes `count−1` (not `hi−lo`
  mishandled) and that the row-major layout the callee assumes matches the
  caller's storage. `unbounded2`'s `ARRAY BOOLEAN OF …` (count 2, lower bound
  FALSE) is the canonical check.
- **Partial indexing / sub-array passing.** `a[i]` yielding a rank-`r−1` open
  sub-array passed onward is *not* required by the two failing tests; the design
  supports computing its address but **does not** propagate the residual
  companions to a further call. Treat full-rank indexing as the supported case;
  flag passing a partially-indexed open sub-array as out of scope for the first
  cut.
- **Element width.** CHAR is i16 on this Windows build (`codegen.rs:240`); the
  flat index is an element count and `IndexPtr` GEPs `elem_ty*`
  (`codegen.rs:1005`), so stride math stays in elements, not bytes — consistent
  with the existing fixed-array flatten. No byte scaling needed.
- **`HIGH` on a non-open multi-dim actual inside the callee** is moot (inside the
  callee `a` is always the open formal); the only HIGH-on-fixed path is the call
  site (`actual_high_dim`), already covered.
