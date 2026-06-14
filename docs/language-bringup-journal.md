# NewM2 — Full Modula-2 Language Bring-Up Journal

A running log of the multi-sprint effort to bring NewM2 to full PIM 4 + ISO 10514-1
conformance. Newest entries at the bottom. Each entry: what changed, why, result.

Target: PIM 4 + ISO 10514-1 core (JIT-first, x86_64-pc-windows-msvc). Scope decisions:
coroutines = fibers (Sprint H); OO/COM = in (full execution); runtime checks = ON by
default (`--no-runtime-checks` opt-out); ISO wins PIM/ISO conflicts; classical manual memory throughout.

Sprint plan: A numeric correctness · B test harness · C control-flow · D variant records ·
E local module + lifecycle · F exceptions + runtime checks + M2EXCEPTION · G enums/const/coercion ·
H coroutines (fibers) · + OO/COM execution.

---

## Planning (2026-06-10)
6-agent coverage assessment across all compiler phases produced a maturity matrix, a
P0→P3 gap list, and the A–H sprint plan. Verdict: hard architecture ~70% done; the work is
correctness-first (many features "parse + sema" then silently miscompile/crash), not new
architecture. Memory: `m2-language-bringup.md`.

---

## Sprint A — numeric & builtin correctness  (commits c377dcb, e80b08c)
Fixed the P0 cluster of silent numeric miscompiles / crashes, each regression-tested.

- **Set operators `+ - * /`** lowered to *integer* arithmetic on the bitmask. Now emit
  `SetOp::{Union,Difference,Intersection,SymDiff}` when an operand is set-typed
  (`lower.rs` eval_binary + new `expr_is_set`). `{0,1}+{1,2}` was 9 → now {0,1,2}.
- **Narrow signed widening** always zero-extended (codegen is sign-agnostic). Lowering now
  sign-extends INTEGER8/16/32 to i64 before int arithmetic (`widen_if_signed_narrow` →
  `IntSignExt`). `i8:=-5; i8+100` was 351 → **95**.
- **`REM`** used unsigned remainder. Added `BinOp::SRem`; signed/mixed path maps ISO REM →
  SRem. `-7 REM 3` was 0 → **-1**.
- **`CAP`** had no lowering → codegen panic. Added `UnaryOp::Cap` (range-compare + select).
  `CAP('a')` → `'A'`.
- **SYSTEM `ADDADR`/`SUBADR`/`DIFADR`/`MAKEADR`**: were sema-1-arg + unlowered (fell through
  to a nonexistent proc). Fixed sema arg-counts; lowered as ptr↔int round-trips (ADDRESS is
  an LLVM pointer). `DIFADR(ADDADR(a,16),a)` → 16.

Tests: t-10-060 (signed/REM), t-10-070 (CAP), t-10-080 (sys-addr), t-60-016 (set arith).
Result: **e2e 65 green**, all crate tests pass, no regressions.

Deferred tail (per descope valve — these fail loudly at sema, not silently): `SHIFT`/`ROTATE`
lowering (width-sensitive) and COMPLEX `+ - * /` operators (use the ComplexMath library).

---

## Sprint C — control-flow conformance (in progress)

### FOR loop: descending + ordinal control types
- **Descending FOR** (`FOR i := 10 TO 1 BY -1`) ran **0 iterations** — the header hardcoded
  `cur <= end`. Now the header is step-sign-aware and branchless:
  `cond = (step≥0 & cur≤end) | (step<0 & cur≥end)`, with the step sign computed once
  pre-loop (`lower_for`). Handles BY -1, BY -2, and runtime steps.
- **FOR over CHAR/enum** (`FOR c := 'A' TO 'E'`) was sema-rejected — the control-type check
  used `is_integer_family_type` (no CHAR). Added a dedicated `is_ordinal_type` (integer
  family + CHAR/ACHAR/UCHAR/BOOLEAN) for the FOR control var, kept separate so CHAR doesn't
  leak into arithmetic/array-index checks. Also fixed the BY-step check: the step is an
  integer count, not a value of the control type (`FOR c:='A' TO 'Z' BY 2`).
- Result: 55 (BY -1), 30 (BY -2), `ABCDE` (CHAR), 15 (ascending, unchanged). Test
  t-20-080-for-loops. **e2e 66 green.**

### CASE: remove 256-entry range truncation
- A `CASE` arm range was expanded into at most 256 dense switch entries
  (`v in l..=h.min(l+255)`), so e.g. `300..999` only matched 300..555 and other
  values silently fell to ELSE. `lower_case` now partitions labels: single values
  drive the dense switch; **ranges become explicit `lo <= val <= hi` checks**
  (chained before the switch), so wide ranges match every value.
- `classify(280)`/`classify(800)` over `0..299`/`300..999` now return L/H (were `?`).
  Test t-20-090-case-range → `LLHM?`. **e2e 67 green.**
- Note: CASE *no-match with no ELSE* still falls through (silent) for now; it
  becomes a catchable `caseSelectException` in Sprint F (needs the exception
  runtime — `Terminator::Halt` would kill the test process, so it's deferred).

## Sprint D — VARIANT records & aggregate layout (in progress)

### Subrange host type
- Subrange `[lo..hi]` always used host INTEGER (i64), so `['A'..'Z']` and enum
  subranges were mis-sized. Sema now derives the host from the bound's type
  (CHAR→i16, enum→i32, else INTEGER). Broad green (e2e 67) — the ISO library's
  subranges still lower correctly.

### Multi-dimensional & non-zero-based array indexing
- `Array { indices: Vec, base }` is a flat row-major array, but the index
  selector only used `indices[0]` AND never subtracted the dimension lower
  bound. So `a[i,j]` ignored j, and `ARRAY[1..3]` indexed from offset 1.
- Rewrote the index selector: full indexing flattens row-major with per-dim
  lower-bound adjustment, `flat = Σ_k (i_k - lo_k)·∏_{m>k} count_m`
  (`dim_lo`/`dim_count` helpers). A single fixed-array index goes through the
  same path (so non-zero-based 1D arrays now subtract their lower bound). Open
  arrays / partial indexing keep the raw first index.
- `m[1,2]`=12, `m[2,3]`=23 in a 3×4 array; `nz[1..3]`=100/200/300 in `[1..3]`.
  Test t-40-030-multidim-array. **e2e 67 green, no regressions.**

### VARIANT records
- Records with a `CASE` variant part silently miscompiled: codegen built the LLVM
  struct from the *fixed* fields only (the variant got 0 bytes), and every arm
  field resolved to `index: None → 0`, aliasing field 0.
- Added `RecordLayout::flatten_fields()` — one canonical struct order (fixed
  fields, named tag, each arm's fields, ELSE fields) used by codegen *and* both
  field-index resolvers (sema `find_record_field_binding`, lowering
  `resolve_field_index`) so they agree. `VariantLayout` gained `else_fields`
  (was dropped). Arms are laid out sequentially/non-overlapping — correct for
  normal tag-discriminated use; cross-arm type-punning is not supported (noted).
- A `Figure` record with `name:CHAR` + `CASE kind:Shape OF circle:radius |
  rectangle:width,height` now reads back name='C', ORD(kind)=0/1,
  radius=42 / width=10 / height=20. Test t-40-040-variant-record.
  **e2e 69 green, no record regressions.**

### WITH — deferred
`WITH r DO field … END` (unqualified field access) needs cross-cutting changes to
sema name-resolution *and* lowering designator resolution (both must agree). It is
worked around in the stdlib (qualified access), so it's deferred to a focused unit
rather than rushed.

---

## Sprint E — LOCAL MODULE + module lifecycle (in progress)

### LOCAL MODULE — fail loudly instead of segfaulting
- A nested `MODULE Inner; … END Inner;` was parsed + scoped but never lowered
  (`collect_procs` and the decl loop skip `Decl::LocalModule`), so its procs/vars/
  init were dropped and a call to `Inner.greet` jumped to 0x0 → segfault.
- Nothing compiled in the repo uses LOCAL MODULE, so per the descope valve sema
  now rejects it cleanly (`LOCAL MODULE is not yet supported`) rather than
  miscompiling silently. Full lowering (procs as qualified fns, vars as statics,
  init chained into the enclosing init, EXPORT-to-enclosing) is tracked as a
  follow-up. **e2e 69 green.**

### Still open in Sprint E (next units)
- Module finalization (`{mod}.final`) run LIFO at program shutdown (today FINALLY
  runs at body-end). CONST param read-only enforcement. Module `priority`.

---

---

## Sprint F — exceptions + runtime checks + M2EXCEPTION (in progress)

### Runtime: M2EXCEPTION source + raise primitive
- Added `M2_SOURCE` (a fixed sentinel source for ISO language exceptions, like
  `ASSERT_SOURCE`), the `m2exc` ordinal constants (index/range/caseSelect/…), and
  `nm2_raise_m2(number)` / `nm2_m2_source()` (exceptions.rs), bound into the JIT.
- Lowering helper `raise_m2_exception(number)` calls it then terminates the block.

### CASE no-match → caseSelectException
- A CASE selector matching no label with no ELSE now raises a catchable
  `caseSelectException` (M2_SOURCE) instead of silently falling through. An
  `EXCEPT` handler catches it. Test t-70-100-case-nomatch: `pick(1)`='A',
  `pick(9)` raises → EXCEPT writes 'X' → `AX`. **e2e 70 green.**

### Array bounds checking (ON by default)
- Lowering now emits an index bounds check for fixed arrays: the 0-based index
  must be in `[0, count)`, else `nm2_raise_m2(indexException)` (a catchable
  exception). `ModCtx.runtime_checks` gates it (true by default; a
  `--no-runtime-checks` opt-out threads here next). `emit_index_bounds_check`.
- Caught a real interaction: the standard `POINTER TO ARRAY [0..MAX(CARDINAL)-1]
  OF T` unbounded-array idiom — `MAX(CARDINAL)` const-folds to 0 (placeholder,
  Sprint G), so the subrange is `[0..-1]` → count 0 → the check fired on *every*
  access and aborted the file-I/O library. Fix: skip the check for degenerate
  (count<=0) or unbounded (count>i64::MAX) dimensions — only real, sane fixed
  bounds are checked.
- `a[1]`=20 in `[0..2]`; `a[5]` raises indexException → EXCEPT. Test
  t-70-110-bounds-check. **e2e 71 green** (incl. all file-I/O + perf tests).

### `--no-runtime-checks` opt-out
- `lower_module` now wraps `lower_module_opts(…, runtime_checks)` (default true);
  the driver gained `--no-runtime-checks` (DriverOptions.runtime_checks), threaded
  into the run path. Default ON → `a[5]` raises (`OOB`); with the flag → no check
  (`noraise`). Driver test `runtime_checks_default_on_and_opt_out`. driver 18 green.

### M2EXCEPTION module
- Added the ISO `M2EXCEPTION` module (def in isodef, impl in isomod) with the
  `M2Exceptions` enumeration (index/range/caseSelect/…) and `IsM2Exception()` /
  `M2Exception()`, thin over NM2RT. Added `NM2RT.M2Source()` (→ `nm2_m2_source`)
  so a handler can match the language-exception source.
- A handler can now discriminate: an out-of-bounds index raises, and
  `IsM2Exception()` + `M2Exception() = indexException` identifies it. Test
  t-70-120-m2exception → `index`. **e2e 72 green.** (`VAL(M2Exceptions, CARDINAL)`
  works for the number→enum conversion.)

### Whole-number division-by-zero check
- `eval_binary` now emits a zero-divisor check (gated by `runtime_checks`) for
  integer `DIV`/`MOD`/`REM` and integer `/`: a zero divisor raises
  `wholeDivException` (`emit_div_zero_check`). `10 DIV 2`=5, `10 DIV 0` raises →
  discriminated via M2EXCEPTION. Test t-70-130-div-zero → `5 divzero`.
  **e2e 72 green** (library divisions by non-zero unaffected).

### Uncaught-exception diagnostic
- Before: an exception that escaped to the JIT entry boundary (no enclosing
  EXCEPT) aborted silently with native code `0xe06d7363` — no clue what raised.
- `run_modules`' `catch_unwind` now downcasts the caught panic to
  `ExceptionPayload` and reports a named diagnostic instead of discarding it:
  `unhandled exception in <module>: <what>: <message>`.
- Added `newm2_runtime::describe_exception(source, number)` as the single source
  of truth for exception identity → name: the two runtime sentinels map to
  friendly names (`ASSERT_SOURCE` → `failed ASSERT`; `M2_SOURCE` → the
  `M2EXCEPTION.<name>` from `M2_EXCEPTION_NAMES`, the ISO-ordinal table), and any
  other source is a user source printed numerically.
- `a[9]` on `ARRAY [0..3]` with no handler now prints `unhandled exception in
  t7140: M2EXCEPTION.indexException: array index out of range` rather than
  crashing. New helper `check_run_error(test_id, needles)` asserts a run fails
  with a diagnostic; test t-70-140-uncaught. **e2e 74 green.**

### NIL-dereference check
- `eval_selector_ptr`'s `Deref` arm now emits a NIL check (gated by
  `runtime_checks`) right after loading the pointer and before any field/index
  GEP: the pointer is `PtrToInt`-cast and compared to 0; NIL raises
  `invalidLocation` (ordinal 3). Casting to integer avoids depending on
  pointer-typed `icmp`. `emit_nil_check` mirrors the other check helpers.
- `p := NIL; p^.value` now raises a catchable invalidLocation rather than
  segfaulting. Test t-70-150-nil-deref → `nilderef`. The check is on *every* `^`
  deref yet all file-I/O / pointer-heavy library tests still pass (valid
  pointers are never 0). **e2e 75 green.**

### Re-raise / RAISE statement
- The target dialect (PIM4 + ISO core) has **no `RAISE` statement** — raises go
  through the `EXCEPTIONS.RAISE` procedure, and the `Stmt::Raise` AST node is
  never produced by the parser. Re-raising is `NM2RT.Reraise` (binds
  `nm2_reraise`), already exposed.
- Hardened the vestigial lowering anyway: a bare `Stmt::Raise(None)` now lowers
  to `nm2_reraise` (correct ISO re-raise) instead of trapping with a NIL value,
  keeping the IR sound if a front end ever emits the node.
- Verified re-raise propagation end-to-end: `Inner` raises (source, 7, "boom"),
  its handler notes it (`inner `) and calls `NM2RT.Reraise`, and the enclosing
  module handler catches it with source/number intact (`IsCurrentSource` +
  `CurrentNumber = 7` → `outer7`). Test t-70-160-reraise → `inner outer7`.
  **e2e 76 green.**

## Sprint F complete
Exception model + runtime checks (default ON): CASE-no-match, array-bounds,
whole-division-by-zero, and NIL-dereference all raise catchable ISO
`M2EXCEPTION`s; `M2EXCEPTION` module discriminates them; `--no-runtime-checks`
opts out; an uncaught exception names itself at the JIT boundary instead of
aborting silently; re-raise propagation verified. 6 commits (a4106dd → c375535
+ this), e2e 69 → 76, no regressions.

## Sprint G — const-eval folding of type builtins
### MAX / MIN / SIZE / TSIZE in constant expressions
- Before: `constant.rs` (which has no type system) folded `MAX`/`MIN`/`SIZE`/
  `TSIZE`/`VAL` to a 0 placeholder. That made `MAX(CARDINAL)` = 0 — the root
  cause of the bounds-check abort on the unbounded-array idiom (Sprint F) and
  wrong everywhere these appear in CONST exprs and static array bounds.
- Fix without a big refactor (24 internal `eval_const` recursions, 6 external
  callers): the analyze layer pre-computes each type-builtin (it *has* the type
  system) and threads the value through the existing `lookup` closure under a
  synthetic `\u{1}OP\u{1}TypeName` key; `eval_builtin_call` forms the same key
  and looks it up, falling back to 0 only when no type info was supplied.
  `type_builtin_key` (in constant.rs) is the shared key-builder so both sides
  agree.
- New analyze helpers: `quiet_type_arg` (read-only, diagnostic-free type-name
  resolution — avoids double-reporting), `type_ordinal_bounds` /
  `builtin_ordinal_bounds` (MIN/MAX, matching codegen widths),
  `type_size_bytes` / `builtin_size_bytes` (SIZE/TSIZE, matching codegen's
  `builtin_type`: enums→i32=4, ptr/proc→8, set→32, array→count·elem),
  `prefill_type_builtins` (walks the const expr). `VAL(T,x)` now folds to `x`.
- Verified: `MAX(INTEGER8)`=127, `MIN(INTEGER16)`=-32768, `SIZE(INTEGER32)`=4,
  `TSIZE(CHAR)`=2, `MAX(Color)`=3, `MAX(Digit)`=9, `MIN(Digit)`=0, and folded
  arithmetic `MAX(Digit)-MIN(Digit)+1`=10. Test t-20-100-const-builtins.
  **e2e 77 green**, sema 18 + driver 40 green — no regression from the
  0→real-value change.

### Type builtins in static array/subrange bounds and variant labels
- `eval_const_decl` was only one of several `eval_const` entry points. Extended
  the same prefill to `form_type_expr`'s `Subrange` arm (so
  `ARRAY [0..MAX(INTEGER8)] OF INTEGER` sizes to 128 elements, not 1) and to
  variant-record CASE labels (`MIN(T)..MAX(T)`).
- Runtime uses were already correct: `lower_min_max_builtin` /
  `lower_size_builtin` (`ConstVal::SizeOf`) compute real values at the IR level;
  only the compile-time const path had the 0 placeholder.
- Verified: `Buf = ARRAY [0..MAX(INTEGER8)] OF INTEGER` filled by
  `FOR i := 0 TO MAX(INTEGER8)`, summing 0..127 = 8128 with every index passing
  the bounds check. Test t-40-050-array-maxbound. **e2e 78 green.**

### Signed/unsigned: CARDINAL vs INTEGER literal
- The unsigned compare/divide path required *both* operands to be unsigned-typed,
  so a CARDINAL compared or divided against an INTEGER literal (`c > 100`,
  `c DIV 2`) fell to the signed path — wrong once the value's top bit is set
  (`MAX(CARDINAL)` read as -1).
- Now the unsigned path fires when at least one operand is unsigned and the
  other is unsigned-compatible: unsigned-typed *or* a non-negative integer
  literal (which adapts to the unsigned operand). Negative literals are
  `-(literal)` (a unary op), so they correctly stay signed. New helper
  `unsigned_compatible`. Mixed CARDINAL/INTEGER *variables* still take the
  signed path (conservative; mixing is a type error anyway).
- Verified: `MAX(CARDINAL) > 100` → `big` (was `small`), `MAX(CARDINAL) DIV 2 >
  1000000` → `half-big` (was `half-small`). Test t-10-090-cardinal-cmp.
  **e2e 78 green** (no signed-comparison regressions).

### Sparse enumerations (ADW / C-enum explicit values)
- The parser accepted `(red = 0, green = 1, …)` but *discarded* the explicit
  value, assigning dense positional ordinals. For real Win32 ADW `.def` files
  this silently miscompiled — they use genuinely sparse C enums
  (`SidTypeUser = 1`, `…FORCE_DWORD = 7FFFFFFFH`, members defined relative to
  earlier ones). 13 of 156 reference `.def` files contain such enums.
- Now the explicit values are carried and honoured end-to-end:
  - AST `TypeExpr::Enum(Vec<String>, Vec<Option<Expr>>, Span)` — values parallel
    to names; parser records `name = expr`.
  - `TypeKind::Enum { name, names, values }` — `values[i]` is member `i`'s
    ordinal. `enum_member_ordinals` computes them: explicit constant if present
    (folded via `eval_const`, with earlier members in scope so `(a=1, b=a+4)`
    works), else previous+1. Unfoldable values degrade to the sequential
    ordinal. Used at both enum-member insertion passes and at type formation.
  - `EnumMember.ord` (already `i128`) carries the real value, so an enum-member
    reference lowers to `Const(ord)` and `ORD`/comparisons are correct.
  - `MAX`/`MIN` of an enum (sema `type_ordinal_bounds` and IR `type_min_max`)
    use min/max of the values, not `names.len()-1`. Array-dimension *count* keeps
    using the member count (so a FORCE_DWORD enum can't request a 2³¹-slot array).
  - `types_out` re-emits `name = value` so regenerated `.def`s round-trip.
- Verified: `Code = (ok=0, warn=5, fail=10, fatal)` → ORD(warn)=5, ORD(fail)=10,
  ORD(fatal)=11 (prev+1), MAX=11, MIN=0; and the dense explicit form
  `(red=0, green=1, blue=2)` still works. Tests t-30-070-enum-explicit,
  t-30-080-enum-sparse. **All 156 corpus `.def`s parse; e2e 81 green**, parser /
  sema / driver / ir / llvm / winapi-gen all green.

## WITH statement
- `WITH r DO … END` was unimplemented: the lowering `with_stack` was pushed but
  never read, and sema opened an empty block scope, so a bare field name in the
  body did not resolve to `r.field`. The ISO library had *worked around* this by
  hand-inlining `WITH inv DO …` as explicit `inv.field := …` writes (see
  `IOLink.mod`), and ADW modules like `DlgShell.mod` (81 WITHs) couldn't compile.
- Implemented end-to-end:
  - Sema: `Ctx.with_stack: Vec<TypeId>` (active WITH record types). The selector
    loop was extracted into `analyse_selector_chain` (shared). `analyse_designator`
    now, for a single-segment base that doesn't resolve normally, consults the
    WITH stack (innermost first) via `record_field_lookup`; on a hit it annotates
    the head as a field access and analyses the trailing selectors against the
    field type. `record_type_of` unwraps POINTER TO record.
  - Lowering: `lower_with` captures the record's address **once** (so the WITH
    designator — e.g. `pts[i]` — is evaluated a single time) and pushes
    `(ptr, record_ty)`. `with_field_ptr` GEPs a bare field off the captured base
    and applies any trailing selectors; `eval_lvalue` and `eval_designator_val`
    consult it first.
  - Precedence: WITH fields are resolved only when the name is otherwise
    unresolved (check-on-miss), so an outer variable of the same name keeps its
    meaning — a small, documented divergence from strict ISO shadowing, chosen
    to be non-breaking.
- Verified: simple record (`WITH p DO x:=3 END`), array-element designator
  (`WITH pts[i] DO …`, evaluated once per iteration), and nested WITH where the
  inner `x`/`y` belong to the inner record. Test t-40-060-with. **e2e 82 green**;
  sema/parser/driver unchanged.

## Sprint E — module finalization (LIFO)
- A module-level `FINALLY` was lowered into the module's init body (bundled via
  `nm2_run_protected`), so it ran *immediately after initialization* instead of
  at program termination. Multi-module repro proved it wrong: an imported
  resource module's finalizer ran as `init-res, final-res, main, final-main` —
  `final-res` fired before `main` even started.
- Split the module body: the `BEGIN…(EXCEPT)…` part stays as the initializer
  `<name>.body`; the `FINALLY` part is outlined into a separate `<name>.final`.
  `run_modules` now runs all initializers in topological order, then runs the
  finalizers of every module that finished initializing in **reverse** order
  (ISO LIFO) — including when a later initializer raises, so already-initialized
  modules still finalize. The body/finalizer JIT-invoke + uncaught-exception
  diagnostic were factored into one `run_jit_void` helper.
- Procedure- and block-level `FINALLY` are unchanged (only the module body path
  moved). Verified: the 2-module repro now prints `init-res, main, final-main,
  final-res`; single-module `work, cleanup` unchanged. Test
  t-40-070-modfinal (+ helper T40070Res). **e2e 83 green.**

### CONST parameters
- `CONST` params were parsed but mapped to `ParamMode::Var`, so they were
  by-reference and **rejected value arguments**: `Sum(x, 5)` failed with "VAR
  parameter requires a designator argument", and a CONST scalar passed to an
  EXTERNAL C function was (wrongly) passed by address.
- Modelled `CONST` as a distinct `ParamMode::Const` in both the AST and sema:
  a *read-only value* parameter. ABI is by value (the existing `== Var` checks
  treat `Const` as by-value), so it accepts any argument expression — open
  arrays still pass by ref+HIGH as for value params. Assignment to a CONST
  parameter (or any field/element of it) is now a sema error
  (`is_const_param_target`). `types_out`/print render the `CONST ` prefix so
  `.def`s round-trip.
- Verified: `Sum(x, 5)`=15 and `Sum(x+1, x*2)`=31 (value/expression args), and
  `a := 5` on `CONST a` errors "cannot assign to a CONST parameter". Tests
  t-80-050-const-param, t-80-060-const-readonly. **e2e 85 green**, corpus parses.

## Sprint E complete
LOCAL MODULE guard (earlier) + module finalization LIFO + CONST parameters.

## COMPLEX operators (deferred from Sprint A)
- COMPLEX equality, `CMPLX`, `RE`/`IM` existed, but `+ - * /` were unimplemented:
  sema rejected them ("arithmetic operators require numeric operands") because
  `is_numeric_type` excluded COMPLEX/LONGCOMPLEX, so they never reached lowering.
- Sema: `is_numeric_type` now includes `Complex`/`LongComplex`, so `+ - * /` on
  complex operands type-check and yield a complex result.
- Lowering: `lower_complex_arith` implements the component formulas —
  `(a+bi)·(c+di) = (ac−bd)+(ad+bc)i`, division by `(c²+d²)` — building the result
  `{re,im}` struct. `complex_parts` projects an operand's components evaluating
  it once, and promotes a non-complex operand to `(v, 0)` so mixed `z + r` works.
- Verified: `(3+4i)+(1+2i)=4+6i`, `−=2+2i`, `*=−5+10i`, `/=2.2−0.4i`. Test
  t-80-070-complex-arith. **e2e 86 green**, sema unchanged.

## SHIFT / ROTATE (deferred from Sprint A)
- `SYSTEM.SHIFT`/`SYSTEM.ROTATE` resolved to empty-param stub procs (no typing,
  no lowering). Implemented via two runtime helpers (`nm2_shift`, `nm2_rotate`
  in `bitops.rs`) taking `(value, signed count, bit width)`: SHIFT logically
  shifts left/right by the count's sign (bits past the width are lost); ROTATE
  wraps them. Both mask to the operand's width.
- Sema: `SHIFT`/`ROTATE` type as `(value, count) → value's type`. Lowering:
  `lower_shift_rotate_builtin` passes the value, count, and `int_bit_width(ty)`
  (8/16/32/64 from the operand type) to the runtime; the store coerces the
  result back to the destination width.
- Verified: `SHIFT(1,4)=16`, `SHIFT(48,-2)=12`, `ROTATE(1,4)=16`,
  `ROTATE(16,-2)=4`, and the distinguishing case `ROTATE(1,-1)=2^63` (wraps)
  vs `SHIFT(1,-1)=0` (drops). Test t-10-100-shift-rotate. **e2e 87 green.**

## Sprint H — coroutines (Win32 fibers)
- `SYSTEM.NEWPROCESS`/`TRANSFER` (and the whole COROUTINES surface) previously
  emitted a sema "Not yet implemented" error. Implemented the PIM coroutine
  model via Win32 fibers.
- Runtime `coroutine.rs`: each coroutine is a fiber. `ensure_main_fiber`
  (`ConvertThreadToFiber`, idempotent) makes the main thread a fiber the first
  time; `nm2_coroutine_new(body, size)` (`CreateFiber` + a trampoline) creates a
  coroutine; `nm2_coroutine_transfer(&from, to)` records the running coroutine
  in `*from` (a thread-local `CURRENT`, so no `GetCurrentFiber` TEB intrinsic is
  needed) and `SwitchToFiber`s to `to`. The trampoline switches back to the main
  fiber if a coroutine body returns, so falling off the end is survivable (a
  returning fiber function would otherwise terminate the thread).
- Sema: `NEWPROCESS`/`TRANSFER` removed from the unimplemented set and given
  argument typing; `IOTRANSFER` + the ISO `COROUTINES` module remain "Not yet
  implemented". Lowering: `lower_coroutine_builtin` passes the body procedure
  pointer + stack size to `nm2_coroutine_new` (storing the handle into the VAR
  `cor`), and the `from` lvalue + `to` value to `nm2_coroutine_transfer`.
- Verified: a main routine creates a worker coroutine and ping-pongs control to
  it three times (`worker 1/2/3`), the worker yielding back each time via
  `TRANSFER(worker, main)`, then main prints `done`. Test t-90-020-coroutine.
  **e2e 88 green.** (ISO `COROUTINES` module + `IOTRANSFER` still pending.)

### ISO COROUTINES module (NEWCOROUTINE / TRANSFER / CURRENT)
- The `COROUTINES` pseudo-module (with the `COROUTINE` = ADDRESS type) already
  existed but every primitive errored "Not yet implemented". Wired the core over
  the same fiber runtime: `NEWCOROUTINE` (4 or 5 args; the protection arg is
  accepted and ignored) reuses `nm2_coroutine_new`; `TRANSFER` reuses
  `nm2_coroutine_transfer`; `CURRENT()` calls the new `nm2_coroutine_current`
  (ensures the thread is a fiber, returns the running handle).
- Sema: the builtin-name extraction now recognises `COROUTINES.X` (not just
  `SYSTEM.X`); `NEWCOROUTINE`/`TRANSFER`/`CURRENT` removed from the unimplemented
  set and typed. The interrupt-driven primitives (`IOTRANSFER`, `ATTACH`,
  `DETACH`, `LISTEN`, `HANDLER`, `PROT`, …) remain "Not yet implemented".
- Verified: `main := CURRENT(); NEWCOROUTINE(Worker, …, worker)`, then two
  `TRANSFER(main, worker)` round-trips (`co 1/2`) and `end`. Test
  t-90-030-iso-coroutine. **e2e 89 green.**

## Remaining
- **OO/COM execution**: the class *type* model is built (vtable layout,
  inheritance flattening, ClassDesc globals), but class method bodies are never
  lowered to IR (`lower_proc_tree` handles only `Decl::Procedure`), and method
  dispatch, instantiation (`NEW` on a class), and `SELF` are unwired in
  sema/lowering. This is a large, focused feature, not a tail task.
- Coroutines: `IOTRANSFER` / interrupt-driven device-driver primitives.

## Status after this run
Done: Sprint A (numeric correctness), Sprint C (FOR + CASE ranges), Sprint D
(subrange host, multi-dim/non-zero arrays, VARIANT records), Sprint E start
(LOCAL MODULE guard). 9 commits, e2e 61 → 69, no regressions.
Next: Sprint E finalization/CONST-params, then Sprint F (exception model +
runtime checks + M2EXCEPTION + bare RAISE + CASE-no-match exception), then
G (sparse enums/const-eval), H (coroutine fibers), OO/COM. Deferred units:
WITH, whole-array-copy lower-bound on copy, SHIFT/ROTATE, COMPLEX operators.

## OO / COM execution (ISO 10514-2 classes)

Classes had a full type model (fields, vtables, OVERRIDE resolution, ClassDesc
globals, post-JIT vtable patching) but *zero* execution support. Brought up in
checkpoints, each green:

- **CP1 — object layout + NEW + fields** (c8b91de). Each class gets a synthesized
  object-record `{ __vtable, all_fields }`, so existing record machinery handles
  sizing/allocation/field GEPs. A class variable is a pointer to this heap
  object. `NEW(obj)` allocates the record, stores the pointer, installs the
  vtable pointer at field 0. Field access derefs the reference then GEPs
  (indices +1 past the vtable). Reference assignment aliases.
- **CP2 — methods, SELF, virtual dispatch** (4d25570). Each method lowers to
  `{Class}.{Method}(SELF, …)`; the vtable points at it; `obj.M(args)` loads the
  object's vtable pointer, loads the slot, and emits an `IndCall` with SELF
  prepended. Sema analyses method bodies with SELF in scope; bare field names
  resolve to SELF's fields (implicit `WITH SELF`). `SelectorBinding::Method`
  carries the vtable slot; each slot gets a synthesized `call_sig` (SELF +
  params) for indirect typing. ClassDesc globals emit only for classes declared
  in the current module.
- **CP3 — inheritance, OVERRIDE, polymorphism** (4379a5c). A derived object's
  vtable drives dispatch, so a base-typed reference or parameter holding a
  derived object calls the override. `class_is_subclass` allows Derived → Base
  assignment. Fixed a parser bug: a `VAR` field before `OVERRIDE` was misread as
  a field name (`at_class_member_boundary`).
- **CP4 — class builtins** (c3070f8). `SELF` as a value, `EMPTY` (the null class
  reference, a NIL-typed pervasive), `DESTROY(obj)` (free the instance).
- **COM interop** (this commit). NewM2's object layout `{ vtable, fields }` and
  dispatch (load vtable → load slot → call with the receiver first) *are* the
  Microsoft COM ABI. So an M2 class declaring an interface's methods in IUnknown
  order can consume a real OS COM object. Added the `windows-sys` crate to the
  runtime with `CoInitialize`/`CoGetMalloc`/GUID-equality glue (`com.rs`, exposed
  via NM2RT). Proof: `t-90-080-com-malloc` declares `IMalloc` as an abstract
  class, gets the process task allocator from `CoGetMalloc`, and calls
  `mem.Alloc(64)` / `mem.Free(p)` through ordinary virtual dispatch — invoking
  the real OS `IMalloc` vtable functions (`alloc-ok`, `freed`).

**e2e 89 → 95 green.** Tests t-90-040…080 cover fields, methods/dispatch,
inheritance/polymorphism, SELF/EMPTY/DESTROY, and live COM consumption.
