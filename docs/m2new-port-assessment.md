# M2NEW → NewModula2 port assessment

*Review date: 2026-06-06.*

Comparison of the donor tree **`E:\M2NEW`** (git `master`, ~last commit 2026-05-18)
against the active **NewModula2** tree (NewM2 compiler core + the manual-memory
pivot). Goal: grab anything genuinely better from M2NEW's **compiler and M2
source**, **excluding the IDE (`igui`) and the GC** (NewModula2 is manual-memory).

This is a **two-way divergence**: NewModula2 is newer in places (float
arithmetic/comparison lowering, `NEW`/`DISPOSE`/`INC`/… builtins, integer-literal
→ CARDINAL adaptation, integer-family assignment leniency, IMPL inherits
DEF consts/types, HeapAlloc manual heap, GC behind a feature). M2NEW is larger in
the compiler feature set (SET, exceptions, classes/vtables) and ships a much
bigger runtime/library.

## Size delta (Rust source, lines)

| crate | NewModula2 | M2NEW | Δ | where the delta is |
|---|---:|---:|---:|---|
| lexer | 1944 | 2000 | +56 | minor |
| parser | 4454 | 4618 | +164 | minor |
| sema | 5549 | 6630 | **+1081** | classes, CONST params, SpanKey, builtin checks |
| ir | 2824 | 5299 | **+2475** | SET, exceptions, vtables, open-array, globals |
| llvm | 2270 | 3228 | **+958** | SET, exceptions, module-init, string/array |
| loader | 1329 | 1524 | +195 | minor |
| driver | 1132 | 1474 | +342 | program-args, app-path (some IDE) |
| runtime | 1833 | 18119 | +16K | **~14K is `igui` IDE (SKIP)** + portable modules below |

Core-compiler delta ≈ **5K lines**, concentrated in IR/sema/codegen.

## Prioritized port backlog

Difficulty/risk are relative; "verifiable" = we have or can cheaply add a test
that exercises it.

### Tier 1 — high value, tractable
1. **SET constructors + SET ops** (sema + ir + llvm). OURS stubs `Expr::Set =>
   emit_nil()` (ir `lower.rs`). M2NEW lowers set literals/ranges to a bit-shifted
   OR chain (`lower.rs` ~1925-1990, `emit_set_const` ~2133-2176) and emits set
   codegen. **Unblocks the ignored `t-50-070-float-library` test.** Verifiable.
   Difficulty: medium. Risk: medium.
2. **ISO exception runtime + lowering** — runtime `exceptions.rs` (≈400 lines,
   `nm2_raise`/`nm2_reraise`/`nm2_run_protected`/`nm2_assert_failed`/…, no GC
   coupling) + IR protected-block lowering (`lower.rs` ~1126-1495) + codegen
   bindings (`lib.rs` ~356-387). OURS traps on `RAISE`. Closes a headline gap.
   Difficulty: large. Risk: medium-high (C-unwind ABI).
3. **Module-init sequencing** — M2NEW runs every imported module's `BEGIN` body in
   topological order before the entry body (`llvm/lib.rs` ~150-191). OURS runs
   only the entry body → imported module initialization never executes. Real
   correctness gap. Difficulty: low. Risk: medium (ordering). Add an init-order test.
4. **Portable runtime modules (new files, no GC/IDE coupling)** that back ISO defs
   we already ship:
   - `strings.rs` (COPY, LENGTH) — backs `Strings`/`COPY`. low.
   - `file.rs` (open/close/read/write/seek/…) — backs `SeqFile`/`StreamFile`/`RndFile`. low.
   - `fmath.rs` (frexp/ldexp/modf) — backs `LowReal`/`RealMath`. low.
   - `sysclock.rs` (GetClock) — backs `SysClock`. low (couples to DateTime record layout).
   - `program_args.rs` — backs `ProgramArgs`. low (driver calls `_set`).
   - `storage.rs` (ISO `Storage.ALLOCATE`/`DEALLOCATE`) — low.
   Each needs a `mod`/`pub use` in runtime `lib.rs` + JIT `bind()` lines (copy the
   mapping from M2NEW `llvm/lib.rs`).

### Tier 2 — good correctness/quality wins (sema)
5. **NIL ↔ ADDRESS-family compatibility** (`types.rs is_same_family`, ~2 arms). low.
6. **`HIGH`/`LEN`/`LENGTH` argument type-checking** + add **`LEN()`** builtin
   (`analyze.rs` ~2965-2989, 3231-3263). OURS uses an unchecked generic path. low.
7. **`CONST` parameter mode** (`ParamMode::Const`, types.rs + analyze.rs + print.rs).
   Pass-by-reference-immutable. low (additive).
8. **Const-eval qualified field flattening** — `M.const` lookup in constant
   expressions (`constant.rs` ~84-100). low.
9. **Module-scoped `SpanKey`** — include `module_id` so per-expression type/binding
   caches don't collide across modules at equal offsets (`analyze.rs` ~60-74).
   Correctness; ~40 call sites. medium.

### Tier 3 — larger features (defer / scope per need)
10. **Classes/vtables** — `VtableCall` IR + method-name mangling + dispatch
    (ir `lower.rs` ~3183-3293, inst.rs), sema `SelectorBinding::Method`
    (`analyze.rs` ~2222-2279), `class.rs` `is_subclass_of`/`method_is_overridden_below`.
    Whole OO feature; ISO 10514-2 / COM-facing. large.
11. **Open-array stride / `LoadPtr` + `Alloca` pointee hint** — fixes VAR LONGREAL
    parameter element-stride; enables `HIGH` on open arrays (ir inst.rs/lower.rs).
    medium. Correctness.
12. **Cross-module function-name mangling** (`Module.Proc`) for link-time
    uniqueness (ir `lower.rs` ~88-99). Verify against OURS' existing multi-module
    path before adopting. low-medium.
13. **CASE range expansion** into switch arms up to a cap (ir `lower.rs` ~1849-1857).
    Optimization. low.
14. **JIT symbol registration / BRK** (`brk.rs`, ~1100 lines, Windows-heavy
    debugger). Optional; not IDE but UI-adjacent. high. Defer.

### Not porting
- `igui/*` (the IDE, ~14K lines) — excluded by directive.
- `ui_thread.rs` — IDE-adjacent.
- GC anything (statepoints, collector) — NewModula2 is manual-memory; GC stays
  quarantined behind the `gc` feature.

### NewModula2-only (do NOT regress when merging)
- Inline **ASM procedure** lowering (`new-asm`) — M2NEW lacks it.
- Today's pivot fixes: float arith/compare lowering, `NEW`/`DISPOSE` builtins,
  integer-literal/CARDINAL adaptation, integer-family assignment leniency, IMPL
  inherits DEF consts/types, HeapAlloc manual heap, void-body exit-code fix,
  self-healing windows pack.

## Recommended order
SET constructors (1) → portable runtime modules (4) → ISO exceptions (2) →
module-init sequencing (3) → the Tier-2 sema wins (5-9) → classes (10) as a
dedicated effort when COM/OO is needed.

Each port lands with the test suite kept green; un-ignore `t-50-070` once SET
constructors are in.
