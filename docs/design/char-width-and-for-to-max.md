# CHAR-indexed arrays and `FOR … TO MAX(type)` — diagnosis & fix design

Status: design / diagnosis only (no source changed)
Author: investigation for `For9.mod` runtime `M2EXCEPTION.indexException`
Date: 2026-06-13

---

## Summary

`For9.mod` (`FOR ch := MIN(CHAR) TO MAX(CHAR) DO a[ch] := ' ' END` over
`a : ARRAY CHAR OF CHAR`) raises `M2EXCEPTION.indexException` at runtime on the
**second** iteration.

The root cause is **(a): the array index-type cardinality is computed as `1`
instead of the full range of the index type, whenever the index type is a bare
built-in ordinal (CHAR, BOOLEAN, …) rather than a `Subrange` or `Enum`.**
Two code paths size/check a `CHAR`-indexed array as if it had **one** element:

- `newm2-llvm/src/codegen.rs:186-195` (`llvm_type`) allocates `[1 x i16]`.
- `newm2-ir/src/lower.rs:4906-4913` (`dim_count`) returns `1`, so the emitted
  index bounds check is `index u>= 1` and trips for any `ch >= '\001'`.

Both disagree with the *sema* side, which sizes the array correctly at 65536
elements (`array_element_count` / `type_size_bytes`, via `type_ordinal_bounds`,
which **does** handle `Builtin`). So sema thinks the array has 65536 elements
while codegen emits storage and a bounds check for 1.

The `FOR`-loop lowering is **not** the cause here — it is already
overflow-safe (advances only when another whole step stays in range; see
evidence). It is, however, worth a short note because *the loop control
variable is INTEGER/i64*, which sidesteps a real latent CHAR-width issue that
would otherwise bite (`MAX(CHAR) = 0xFFFF` does not fit in a signed `i16`).

There is also a **secondary latent bug** exposed by the same investigation:
the `codegen.rs` array sizer ignores `Enum` index types too, so
`ARRAY (red,green,blue) OF T` would also be sized `[1 x …]` even though
`dim_count` handles the `Enum` case. The two paths must be unified.

---

## The failing test & exception

`For9.mod` (from the external conformance corpus):

```modula2
MODULE For9 ;
VAR
   a : ARRAY CHAR OF CHAR ;
   ch: CHAR ;
BEGIN
   FOR ch := MIN(CHAR) TO MAX(CHAR) DO
      a[ch] := ' '
   END
END For9.
```

Expected: every element of the CHAR-indexed array is set to a space; the loop
runs `MIN(CHAR) … MAX(CHAR)` inclusive with no out-of-bounds access.

Observed:

```
> target/debug/newm2-driver.exe run For9.mod
newm2: JIT error: unhandled exception in For9:
       M2EXCEPTION.indexException: array index out of range
EXIT CODE: 1
```

With `--no-runtime-checks` the bounds check is gone but the under-sized storage
remains, so it instead segfaults — direct confirmation that the array storage
itself is wrong, not just the check:

```
> target/debug/newm2-driver.exe run --no-runtime-checks For9.mod
=== NewM2 fatal exception: EXCEPTION_ACCESS_VIOLATION (0xc0000005)
    writing 0x... at M2 For9.body+0x4d ===
```

---

## NewM2's CHAR representation (8 vs 16 bit)

NewM2 deliberately models `CHAR` as a **16-bit Windows-wide (UTF-16) code
unit**, not 8-bit. The narrow 8-bit unit is `ACHAR`.

- Codegen: `src/newm2-llvm/src/codegen.rs:238-241`
  ```rust
  // CHAR is a Windows-wide (UTF-16) code unit on this Windows-aimed build;
  // ACHAR stays the 8-bit narrow unit.
  Char | Uchar => self.ctx.i16_type().into(),
  Byte | SysByte | Achar => self.ctx.i8_type().into(),
  ```
- Char constant lowering is i16: `src/newm2-llvm/src/codegen.rs:1498-1499`.
- String literals are emitted as UTF-16 `[N x i16]`: `codegen.rs:412-419`,
  `codegen.rs:1504-1511`.

Sema agrees on width and range:

- Range / `MIN`/`MAX`: `src/newm2-sema/src/analyze.rs:1995-2014`
  (`builtin_ordinal_bounds`) — `Char | Uchar => (0, 0xFFFF)`.
- Byte size: `src/newm2-sema/src/analyze.rs:2017-2028`
  (`builtin_size_bytes`) — `Char | Uchar … => 2`.

So `MIN(CHAR) = 0`, `MAX(CHAR) = 65535`, `SIZE(CHAR) = 2`, and the cardinality
of `ARRAY CHAR OF CHAR` is `65535 - 0 + 1 = 65536`. These are internally
consistent **on the sema side**.

Note the width/value tension for later: `MAX(CHAR) = 0xFFFF = 65535` is the
full `i16` *bit pattern* range, but as a **signed** `i16` value 65535 is `-1`.
Anywhere a CHAR ordinal is materialised in an `i16` and then compared/extended
as signed, values `0x8000..0xFFFF` (32768..65535) misbehave. The current test
avoids this only because the loop control variable is INTEGER/i64 (below).

---

## Diagnosis (what exactly goes out of bounds — with evidence)

### Sema sizes the array correctly (65536)

`array_element_count` and `type_size_bytes` both expand the index type through
`type_ordinal_bounds`, which handles `Builtin`:

- `type_ordinal_bounds` — `src/newm2-sema/src/analyze.rs:1978-1991`; the
  `TypeKind::Builtin(b) => builtin_ordinal_bounds(*b)` arm (line 1988) returns
  `(0, 0xFFFF)` for CHAR.
- `ordinal_count` — `analyze.rs:1973-1975` → `(hi - lo) + 1 = 65536`.
- `array_element_count` — `analyze.rs:2370-2380` → `65536`.
- `type_size_bytes` Array arm — `analyze.rs:1960-1967` uses `ordinal_count`,
  giving `65536 * 2 = 131072` bytes.

So sema's view is right. The defect is entirely downstream.

### How the array type is stored (the trigger condition)

`ARRAY CHAR OF CHAR` is built in `form_type_expr`,
`src/newm2-sema/src/analyze.rs:2548-2554`: each index expression is resolved by
`form_type_expr`. The index `CHAR` resolves to the **named built-in**, i.e.
`TypeKind::Builtin(Builtin::Char)` — it is **not** normalised into a
`Subrange { host: CHAR, lo: 0, hi: 0xFFFF }`. This is the crux: any downstream
code that only pattern-matches `Subrange`/`Enum` index types silently treats a
`Builtin` index as a single-element dimension.

### Codegen sizes the storage as `[1 x i16]`

`src/newm2-llvm/src/codegen.rs:186-195` (`llvm_type`, Array arm):

```rust
TypeKind::Array { indices, base } => {
    let elem = self.llvm_type(*base);
    let mut count: u64 = 1;
    for &idx in indices {
        if let TypeKind::Subrange { lo, hi, .. } = self.types.get(idx) {
            count *= (hi - lo + 1).max(0) as u64;
        }
        // <-- Builtin and Enum index types contribute nothing; count stays 1
    }
    elem.array_type(count as u32).into()
}
```

For a CHAR index (a `Builtin`) the `if let Subrange` does not match, so `count`
stays `1`. Confirmed by the LLVM dump:

```
@For9.a = global [1 x i16] zeroinitializer
```

This is the storage bug: only one element is allocated. (It also drops `Enum`
index types — see Secondary issue.)

### lower.rs computes `dim_count = 1` and emits a `u>= 1` bounds check

`src/newm2-ir/src/lower.rs:4906-4913` (`dim_count`):

```rust
fn dim_count(&self, dim: TypeId) -> i128 {
    match self.ctx.sema.types.get(dim) {
        TypeKind::Subrange { lo, hi, .. } => hi - lo + 1,
        TypeKind::Enum { names, .. } => names.len() as i128,
        _ => 1,                       // <-- Builtin CHAR index lands here → 1
    }
}
```

This `count` feeds the index bounds check in the `apply_selector` Index arm,
`src/newm2-ir/src/lower.rs:4837-4840`:

```rust
let count = self.dim_count(dims[k]);          // = 1 for CHAR index
if self.ctx.runtime_checks && count > 0 && count <= i64::MAX as i128 {
    self.emit_index_bounds_check(adj, count);  // raises if adj u>= 1
}
```

`emit_index_bounds_check` (`lower.rs:2359-2370`) emits `oob = adj UGe count`
and raises `indexException` (number 0) on true.

The emitted IR (`dump-ir For9.mod`) confirms it exactly — block `B3`
(`for_body`):

```
B3:  ; for_body
    v13 = char ' '
    v14 = global @For9.a
    v15 = load *v0          ; v0 = the loop control var (the i64 slot)
    v16 = int 1             ; <-- count = 1
    v17 = v15 u>= v16       ; unsigned: ch u>= 1
    condbr v17 → B6 | B7    ; B6 = idx_oob → raise indexException
```

So iteration `ch = 0` ('\000') passes (`0 u>= 1` is false) and writes element 0;
iteration `ch = 1` ('\001') fails (`1 u>= 1` is true) and raises
`indexException`. That is exactly the observed runtime behaviour.

### Why the FOR loop is *not* the culprit (and why dim_count is)

The IR also confirms the `FOR`-to-`MAX` loop is overflow-safe:

```
B0:  v2 = int 65535         ; end = MAX(CHAR), in the i64 INTEGER domain
B2:  ; for_cond  → cur <= end (ascending)
B4:  ; for_step
     v22 = v2 - v21         ; room = end - cur
     v26 = v22 >= v3        ; "does another whole step (1) still fit?"
     condbr v30 → B8(advance) | B5(exit)
B8:  ; for_advance  v31 = v21 + 1 ; only taken when a step still fits
```

The control variable is incremented (`B8`) **only** when `room >= step`, and
the body (`B3`) always runs with an in-range value. There is no
increment-past-`MAX` and no wrap. (This matches the comment at
`lower.rs:2173-2177`.) The loop control slot is `alloca i64`
(`int_ty()` = INTEGER, `lower.rs:2103,2110`), so `65535` is represented
exactly and the unsigned bounds compare works on i64. Remove the
`count = 1` defect and the loop body would correctly run 65536 times.

### Root-cause classification

- **(a) array index cardinality** — **YES, this is the active root cause**, in
  two places (`codegen.rs` array sizing, `lower.rs` `dim_count`), both because a
  `Builtin` ordinal index type is not expanded to its range.
- **(b) FOR-to-MAX increment overflow** — **NO**, not active here; the loop
  lowering is already overflow-safe and uses an i64 control variable.

---

## Modula-2 semantics (for reference)

### `ARRAY CHAR OF CHAR`

In PIM/ISO Modula-2 the array index type may be **any ordinal type**, including
a base type used by name (`CHAR`, `BOOLEAN`, an enumeration), not only a
subrange. `ARRAY CHAR OF CHAR` has one element per value of `CHAR`, i.e.
`ORD(MAX(CHAR)) - ORD(MIN(CHAR)) + 1` elements. With NewM2's wide CHAR that is
65536 elements. Indexing `a[ch]` selects element `ORD(ch) - ORD(MIN(CHAR))`.

### `FOR v := MIN(T) TO MAX(T)`

ISO Modula-2 specifies that a `FOR` loop terminates without forming a control
value beyond the final one, precisely so that `FOR v := MIN(T) TO MAX(T)` is
well-defined and cannot overflow the control variable at the top of the range.
Naïve "increment then test against `end`" lowerings are wrong here because the
post-`MAX` increment wraps (or, with checks, raises). NewM2's lowering already
honours this (advance-only-if-room), which is the correct shape; the document
notes it as a general property to preserve, not to change.

### CHAR width vs `MAX(CHAR)` value

The chosen wide-CHAR model means `MAX(CHAR) = 0xFFFF`, which is *not*
representable as a positive `signed i16`. Any future code that puts a CHAR
ordinal in an `i16` and then compares/extends it as signed will mishandle the
upper half-plane (32768..65535). The safe rules are: extend CHAR **zero**-wide
(unsigned) when widening to the index/INTEGER domain, and use **unsigned**
comparisons for CHAR ordering and bounds. The existing bounds check already
uses `UGe` (good); the fix must keep CHAR zero-extended on the way in.

---

## Proposed fix

Fix is **(a): make every "how many elements does this array dimension have"
computation expand a built-in ordinal index type to its full range**, exactly
as sema already does. Concretely, route all three callers through the one sema
function that is already correct.

### Core change — one shared cardinality helper

`src/newm2-sema/src/analyze.rs` already has the correct primitive,
`type_ordinal_bounds` (handles `Subrange`, `Enum`, `Set`, and `Builtin`). The
fix is to make `dim_count` and the codegen array sizer use that same logic
instead of their local, `Subrange`/`Enum`-only matches.

1. **Expose a public helper** from sema, e.g.
   `pub fn ordinal_cardinality(types: &TypeArena, ty: TypeId) -> Option<i128>`
   wrapping the existing `type_ordinal_bounds` + `(hi - lo + 1)` logic
   (`analyze.rs:1973-1991`). (Or expose `type_ordinal_bounds` itself.) This is
   the single source of truth for "number of values of an ordinal type".

2. **`lower.rs` `dim_count`** (`src/newm2-ir/src/lower.rs:4906-4913`): replace
   the local match with a call to the shared helper, so a `Builtin` (CHAR,
   BOOLEAN) or `Set` index also yields the right count. Keep the existing
   "huge / unbounded fold" guard in the caller (`lower.rs:4838`,
   `count <= i64::MAX`) — for CHAR, 65536 passes the guard and is checked
   normally. `dim_lo` (`lower.rs:4899-4904`) must be made consistent too: it
   returns `0` for any non-`Subrange`, which is correct for CHAR/BOOLEAN
   (their `MIN` is 0) and for dense enums, but to be robust it should return
   `type_ordinal_bounds(...).0` (the real `lo`).

3. **`codegen.rs` `llvm_type` Array arm**
   (`src/newm2-llvm/src/codegen.rs:186-195`): replace the
   `if let Subrange` accumulation with the shared cardinality helper so the
   allocated `[N x elem]` matches sema's `type_size_bytes`. This fixes the
   `[1 x i16]` → `[65536 x i16]` storage bug **and** the dropped-`Enum`-index
   bug in the same edit.

After these three, `codegen` (storage), `lower` (bounds check / stride), and
`sema` (`type_size_bytes`, assignment compatibility) all agree on 65536.

### What is *not* changed

- The `FOR`-loop lowering (`lower_for`, `lower.rs:2095-2213`) is correct and
  stays as-is. (b) is not the bug.
- `MAX(CHAR)`/`MIN(CHAR)` values stay `(0, 0xFFFF)` — they are correct for the
  wide-CHAR design and already agree with the (fixed) cardinality.

### Optional hardening (separate, lower priority)

- **CHAR/i16 signedness:** audit places that materialise a CHAR ordinal in i16
  and widen it. Ensure zero-extension (unsigned) so 32768..65535 survive a
  round-trip. Not required to fix `For9` (loop var is i64) but needed before
  any test stores a high CHAR into an `i16` slot and indexes with it.
- **`FOR`-to-`MAX` general note:** keep the advance-if-room invariant; add a
  regression test with a *narrow signed* control type at its top end (e.g.
  `FOR i := MIN(INTEGER16) TO MAX(INTEGER16)`) to lock the property in.

---

## Implementation plan

1. **Sema:** add `pub fn ordinal_cardinality(types, ty) -> Option<i128>` (and/or
   make `type_ordinal_bounds` `pub`) in `src/newm2-sema/src/analyze.rs` near
   `ordinal_count` (1973-1991). Re-express the existing `ordinal_count` /
   `array_element_count` in terms of it to avoid drift.
2. **lower.rs:** rewrite `dim_count` (4906-4913) and `dim_lo` (4899-4904) to call
   the sema helper / `type_ordinal_bounds`. Verify the index-check guard at
   4838 still behaves (it should: 65536 is finite and `> 0`).
3. **codegen.rs:** rewrite the `llvm_type` Array arm (186-195) to use the shared
   helper for `count`, covering `Builtin`, `Enum`, `Subrange`, and `Set` index
   types uniformly.
4. **Build & run** `newm2-driver run For9.mod`; expect clean exit 0.
5. **Re-dump** IR/LLVM for `For9` to confirm `@For9.a = global [65536 x i16]`
   and that the body bounds check is `… u>= 65536`.
6. Run the broader PIM `run/pass` suite to check for regressions (the existing
   `ARRAY [0..N]` tests must be unaffected — they go through the `Subrange`
   path either way).

---

## Test plan

- **Primary:** `vendor/.../pim/run/pass/For9.mod` runs to completion, exit 0,
  no `indexException`.
- **Storage size:** assert via `dump-llvm For9.mod` that
  `@For9.a = global [65536 x i16]` (was `[1 x i16]`).
- **Bounds-check value:** assert via `dump-ir For9.mod` that the for-body
  emits `… u>= 65536` (was `u>= 1`).
- **No-checks path:** `run --no-runtime-checks For9.mod` no longer segfaults
  (storage is now correctly sized).
- **Regression — Subrange index (unchanged path):** `ForChar.mod`,
  `arraychar.mod`, `arraychar2.mod` (all use `ARRAY [0..N] OF CHAR`) still pass.
- **Secondary — Enum index:** add/locate a test
  `ARRAY (red,green,blue) OF CHAR`, write all three slots, and confirm storage
  is `[3 x …]` (guards the `codegen.rs` Enum-index regression fixed here).
- **BOOLEAN index:** `ARRAY BOOLEAN OF CHAR` indexed by `FALSE`/`TRUE` →
  storage `[2 x …]`, both writes in bounds.
- **FOR-to-MAX overflow guard (property lock):** a loop
  `FOR i := MIN(INTEGER16) TO MAX(INTEGER16)` (or a small enum) completes with
  no wrap and no spurious check — ensures the (already correct) loop shape is
  not regressed by the cardinality changes.

---

## Risks

- **Memory blow-up:** `ARRAY CHAR OF CHAR` is now genuinely 65536 × i16 =
  128 KiB of zero-initialised global, vs the (wrong) 2 bytes today. That is the
  correct semantics, but multidimensional CHAR arrays multiply fast
  (`ARRAY CHAR OF ARRAY CHAR OF …` = 65536^n). A separate sanity cap with a
  clear diagnostic on absurd array sizes may be worth considering, but is out of
  scope for this fix.
- **Stride/codegen interaction:** `apply_selector` already computes strides from
  `dim_count` (`lower.rs:4841-4842`); once `dim_count` returns the true count,
  multidimensional CHAR/enum/BOOLEAN-indexed arrays will stride correctly — but
  any place that *previously* relied on the buggy `1` (none found) would change.
  The fix must land in `codegen` (storage) and `lower` (stride + check)
  together to keep them consistent; landing only one re-introduces a
  size/stride mismatch.
- **CHAR/i16 signedness (latent):** unchanged by this fix, but a high-CHAR
  (>= 0x8000) stored in an i16 and used as an index would still misbehave via
  signed extension. `For9` does not exercise this (i64 loop var), so the fix is
  sufficient for the test, but the hardening item above should follow before
  any test writes/reads high CHARs through i16 storage.
- **`set_max_bits` / Set index types:** routing through `type_ordinal_bounds`
  also makes `Set`-typed dimensions "work"; ensure no path now accepts an
  over-wide ordinal (e.g. `ARRAY CARDINAL OF …`) and tries to allocate an
  astronomical array — the existing `count <= i64::MAX` guard in `lower.rs:4838`
  protects the *check*, but `codegen.rs` array sizing has **no** such guard and
  would attempt a `[u32::MAX x …]` allocation. Add the same finiteness guard /
  diagnostic to the codegen sizer as part of this change.
