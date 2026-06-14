# Real ⇄ String conversion library: diagnosis and fix design

Status: design only. No source files were modified. All observations below
were produced by building `newm2-driver` (`cargo build -p newm2-driver`) and
running the failing tests / minimal probes against the committed library.

## Summary

The five failing conformance-corpus tests fail for **three distinct root causes**, only one of
which is a real numeric-formatting bug:

1. **Missing library modules (4 of 5 tests).** `DynamicStrings`,
   `StringConvert`, `ConvStringReal`, and `SFIO` do **not exist** anywhere in
   `library/` (nor are they registered as intrinsics). `real1`, `realstr`,
   `sigfig`, and `stringreal2` import them and die at module-resolution time
   with `module "X" not found in search path`. This is a *gap*, not a bug.

2. **Case-insensitive filename / module-name collision (1 test, plus a latent
   trap for any test).** `realconv.mod` (lowercase) is paired by the loader
   against `library/isodef/RealConv.def` on the case-insensitive Windows
   filesystem, then rejected because the def declares `"RealConv"` ≠ entry
   `"realconv"`. The *test logic itself is correct*: renamed to a
   non-colliding identifier it compiles and **all its assertions pass (exit 0)**.

3. **A genuine `XReal.to_float` trailing-zero bug** that will surface in
   `realstr` (the float/eng ISO P445/P446 cases) once `ConvStringReal` exists.
   `RealToFloat`/`RealToEng` strip trailing zeros that the ISO significant-figure
   contract requires (`3.923E+6` instead of `3.9230E+6`). Fixed-point output
   (`to_fixed`) is already correct.

So the fixes are: **add four clean-room modules**, **de-collide the loader’s
def pairing** (or rename the test build artifacts), and **flip one `tail`
argument in two `RealStr` procedures**.

---

## The 5 failing tests & what each checks

Sources: the external conformance corpus (`isolib/run/pass`).

| Test | Imports the missing modules? | What it actually checks |
|---|---|---|
| `realconv.mod` | No — only `RealConv`, `M2RTS` | `Assert`s on `LengthFixedReal/LengthEngReal/LengthFloatReal` (the *length* of the formatted string). Signals failure via `M2RTS.Halt`. |
| `real1.mod` | `StringConvert` (`LongrealToString`, `ToSigFig`), `SFIO` (`WriteS`), `DynamicStrings` (`String`, `InitString`) | Prints π and a long literal to many significant figures. No exit-code assertion — diagnostic/visual; must at minimum *run*. |
| `realstr.mod` | `ConvStringReal` (`RealToFloatString/EngString/FixedString`), `DynamicStrings`, `SFIO` | 50-row table of fixed/eng/float conversions vs ISO P445/P446 expected strings; `EqualArray`; `exit(e)` with `e=1` on any mismatch. The real conformance test. |
| `sigfig.mod` | `StringConvert` (`ToSigFig`), `DynamicStrings` (`+PushAllocation/PopAllocation`), `SFIO` | 7-row significant-figure rounding table (e.g. `19.99`→3 figs→`20.0`, `99.999`→3→`100`); `exit(e)`. |
| `stringreal2.mod` | `ConvStringReal` (`RealToFixedString`), `DynamicStrings`, `SFIO` | Prints π to 3..10 fixed places. No exit assertion; must run. |

The driver invocation per test (from the test’s directory) is
`<repo>/target/debug/newm2-driver.exe run <name>.mod`.

> Harness note (confirmed): the corpus tests signal pass/fail via `libc.exit` and print
> via `libc.printf`, which NewM2 does **not** format — on-screen output is the
> literal format string. The real signal is the **exit code** (and any internal
> `Assert`/`Halt`). A tampered-assertion probe of `realconv` produced exit 127
> (Halt), confirming the harness is live.

---

## Observed vs expected (from running them)

Run from the external conformance corpus (`isolib/run/pass`):

| Test | Observed | Expected |
|---|---|---|
| `realconv` | `newm2: ...isodef\realconv.def: module name mismatch: file declares "RealConv" but was paired with "realconv"` — compile aborts (exit 1) | compiles, all asserts pass, exit 0 |
| `real1` | `newm2: module "DynamicStrings" not found in search path` | runs to completion |
| `realstr` | `newm2: ...isodef\realstr.def: module name mismatch: file declares "RealStr" but was paired with "realstr"` | runs; exit 0 (all rows pass) |
| `sigfig` | `newm2: module "DynamicStrings" not found in search path` | runs; exit 0 |
| `stringreal2` | `newm2: module "ConvStringReal" not found in search path` | runs to completion |

(The `module "X" not found` lines print to stderr and the driver currently
returns process exit 0 for that class — but the test never executes, so its own
`exit(e)`/`Halt` signal is never produced. Either way it is "wrong output".)

### Proof that the engine is correct where modules already exist

`realconv.mod` copied to a non-colliding module name (`MODULE rcprobe`) compiles
and exits **0** — every `Length*Real` assertion passes. A direct probe of the
existing `RealStr`/`XReal` formatting on the `realstr.mod` values:

```
fix(12.3456789,3)      = 12.346       (expect 12.346)        ✓
fix(1234.56789,-3)     = 1200         (expect 1200)          ✓
fix(3923009,0)         = 3923009.     (expect 3923009.)      ✓
fix(39.23009,-5)       = 0            (expect 0)             ✓
fix(0.0003923009,-2)   = 0            (expect 0)             ✓
fix(3923009,-5)        = 3920000      (expect 3920000)       ✓
eng(1234.56789,3)      = 1.23E+3      (expect 1.23E+3)       ✓
flt(0.0003923009,2)    = 3.9E-4       (expect 3.9E-4)        ✓
eng(0.0003923009,5)    = 392.3E-6     (expect 392.30E-6)     ✗  trailing zero dropped
flt(3923009,5)         = 3.923E+6     (expect 3.9230E+6)     ✗  trailing zero dropped
```

The two ✗ rows are the `to_float` `tail` bug (below). Everything else matches.

---

## Root-cause analysis (shared vs distinct)

### Cause A — Missing modules (shared by real1, realstr, sigfig, stringreal2)

Confirmed by exhaustive search (`find library -iname "<mod>.def"`):

| Module needed | Present in `library/`? |
|---|---|
| `DynamicStrings` | **MISSING** |
| `StringConvert` | **MISSING** |
| `ConvStringReal` | **MISSING** |
| `SFIO` | **MISSING** |
| `FIO` | `library/pimdef/FIO.def` ✓ |
| `StrIO`, `NumberIO`, `M2RTS` | `library/pimdef/…` ✓ |
| `RealStr`, `RealConv`, `ConvTypes`, `Strings`, `CharClass` | `library/iso{def,mod}/…` ✓ |
| `XReal` | `library/ulib{def,mod}/XReal.{def,mod}` ✓ |

There is no intrinsic/runtime registration of these names either
(`grep` over `newm2-sema`, `newm2-loader`, `newm2-runtime` finds nothing).
The loader builds the search path from `*def` subdirs only
(`src/newm2-driver/src/main.rs:349` `push_library_def_dirs`, gate at line 367
`name.ends_with("def") || name == "NewM2"`), so a module with no `.def` simply
cannot resolve (`src/newm2-loader/src/loader.rs:299`,
`module {name:?} not found in search path`).

This is the dominant blocker: **4 of 5 tests die here before any numeric code
runs.**

### Cause B — Case-insensitive def/name collision (realconv; latent for realstr)

When the entry file is a Program/Implementation module, the loader looks up a
sibling `.def` by the entry’s *module name*:
`src/newm2-loader/src/loader.rs:135` `search_path.find_def(&entry_name)`.
`find_def` (`src/newm2-loader/src/search_path.rs:34-47`) does
`dir.join("realconv.def").is_file()` — which on Windows’ case-insensitive FS
matches `library/isodef/RealConv.def`. The def is parsed, its declared name is
`"RealConv"`, and the equality check at
`src/newm2-loader/src/loader.rs:137` fails:

```
module name mismatch: file declares "RealConv" but was paired with "realconv"
```

`realstr.mod` hits the identical trap against `RealStr.def`. (`real1`/`sigfig`/
`stringreal2` would hit it too, but they die earlier on Cause A.)

This is a **driver/loader bug**, independent of any library content: a
lowercase top-level program whose name case-folds onto a library def is wrongly
rejected. It will bite any future test named like a library module.

### Cause C — `XReal.to_float` drops ISO significant-figure trailing zeros (realstr float/eng rows)

`library/ulibmod/XReal.mod:171-178`, fractional-digit emission in `to_float`:

```
171  IF d > pt THEN
172    k := ps; ch('.');
173    FOR l := 1 TO d - pt DO
174      c := get_digit(r); ch(c);
175      IF c # '0' THEN k := ps; nz := TRUE END;   (* k tracks last non-zero *)
176    END;
177    IF NOT tail THEN ps := k END;                 (* rewind: strip trailing 0s *)
178  END;
```

When `tail = FALSE`, line 177 rewinds the write cursor `ps` back to `k` (the
position just after the last *non-zero* fractional digit), discarding trailing
zeros. `RealStr.RealToFloat` and `RealStr.RealToEng` both call `to_float` with
`tail = FALSE`:

- `library/isomod/RealStr.mod:179` `XReal.to_float(real, sigFigs, 1, digits(), 'E', FALSE, TRUE, s)`
- `library/isomod/RealStr.mod:187` `XReal.to_float(real, sigFigs, 3, digits(), 'E', FALSE, TRUE, s)`

But the ISO `RealToFloatString`/`RealToEngString` contract (and the reference implementation's `realstr.mod`)
requires *exactly* `sigFigs` significant figures, **including** trailing zeros:
`3923009.0` to 5 figs is `3.9230E+6`, not `3.923E+6`. Direct probe confirms the
fix: calling `XReal.to_float(3923009.0, 5, 1, 17, 'E', TRUE, TRUE, s)` yields
`3.9230E+6`, and `(…, 5, 3, …, TRUE, …)` on `0.0003923009` yields `392.30E-6` —
both exactly the realstr expectations.

`to_fixed` does not have this problem (it pads with `'0'`, never rewinds), which
is why all fixed-point rows already pass.

**Shared vs distinct:** A and B are unrelated to numeric formatting (they are a
content gap and a loader bug). C is the only numeric-formatting defect, and it
is narrow (two call-sites, one `tail` flag). The 5 failures do **not** share a
single root; they cluster as {A: 4 tests}, {B: 1 test + latent}, {C: surfaces
inside realstr once A is fixed}.

---

## Proposed fixes (concrete, per routine)

All library additions are **clean-room**: built on NewM2’s existing
`RealStr`/`XReal`/`Strings` engine. **Do not copy the reference implementation's GPL sources.** The public
API surface required is fully determined by the tests’ `IMPORT` lists (the
contract), not by any GPL body.

### Fix C1 — `XReal.to_float` trailing zeros (the only numeric bug)

Make `RealStr.RealToFloat` and `RealStr.RealToEng` request trailing zeros by
passing `tail = TRUE`:

- `library/isomod/RealStr.mod:179` — change the 6th arg of `XReal.to_float`
  from `FALSE` to `TRUE` in `RealToFloat`.
- `library/isomod/RealStr.mod:187` — same change in `RealToEng`.

Leave `RealStr.RealToStr` → `XReal.to_any` (which itself calls `to_float(...,
FALSE, ...)` at `library/ulibmod/XReal.mod:283`) **unchanged**: `RealToStr`’s
"shortest reasonable" form legitimately wants trailing zeros stripped, and
`to_any` already manages width/precision itself. Do not edit `to_float`’s body;
the `tail` parameter already does the right thing — only the callers were wrong.

Risk: `RealConv.LengthFloatReal`/`LengthEngReal` (used by `realconv.mod`) return
`LENGTH` of these strings. `realconv` only asserts float/eng *lengths* for cases
whose significant digits contain **no** trailing zeros within range
(`LengthFloatReal(1234.56789,3)=7` → `1.23E+3`; `LengthEngReal(...)` cases
likewise), so the length is unchanged and `realconv` keeps passing. Re-run
`realconv` after the change to confirm (it must stay exit 0).

### Fix B1 — loader def/name case collision

Two options; prefer the first:

1. **Loader (preferred).** In `src/newm2-loader/src/loader.rs:135-145`, after
   `find_def` returns a path, require a **case-sensitive** module-name match
   before pairing. Concretely: if `def_ast.name != entry_name`, do not treat it
   as a hard error when the def was located by case-insensitive filename match
   for a *program/top-level* entry — instead treat "no matching def" (the entry
   is a self-contained program, which `realconv`/`realstr` are). Equivalent and
   simpler: have `find_def`/`find_impl_for_def` verify the on-disk filename
   stem matches the requested name **case-sensitively** (compare the actual
   directory entry’s name, not just `path.is_file()`), so `realconv` never
   resolves to `RealConv.def`. This also future-proofs every test.

2. **Test-build shim (fallback).** Have the test harness compile each corpus test
   from a uniquely-named temp copy whose `MODULE`/`END` identifier equals the
   file stem and does not case-fold onto any library def. Cheaper but only
   masks the loader bug.

This fix alone turns `realconv` green and unblocks `realstr` from Cause B.

### Fix A1 — `DynamicStrings` (clean-room)

New `library/pimdef/DynamicStrings.def` + `library/pimmod/DynamicStrings.mod`
(the reference implementation places it in the PIM library namespace; pimdef is on the search path).
Minimum API exercised by the tests:

- `TYPE String;` (opaque pointer to a heap record holding a `CHAR` buffer +
  length; NewM2 has `Storage`/`SYSTEM` for allocation).
- `InitString(a: ARRAY OF CHAR): String`
- `KillString(s: String): String` (frees, returns `NIL`)
- `EqualArray(s: String; a: ARRAY OF CHAR): BOOLEAN`
- `PushAllocation; PopAllocation(check: BOOLEAN): BOOLEAN` — `sigfig.mod` uses
  these as an allocation-leak scope. A **conformant no-op stack** is sufficient
  (push a marker, pop it, return TRUE); leak-checking is optional for passing.
- Internal helpers needed by StringConvert/ConvStringReal/SFIO below:
  `Length(s)`, `char(s,i)`, `ConCat`/`ConCatChar` or `Slice`, and a
  `string(s): ARRAY OF CHAR`-style read-out. Keep the surface minimal — only
  what the four new modules and the five tests touch.

Implementation can be a thin wrapper over a fixed-capacity buffer record
(maxString in the tests is 80–128); a growable buffer is nicer but not required
to pass. Use `Storage.ALLOCATE`/`DEALLOCATE`.

### Fix A2 — `SFIO` (clean-room)

New `library/pimdef/SFIO.def` + `library/pimmod/SFIO.mod`. Only one procedure is
used: `WriteS(f: FIO.File; s: DynamicStrings.String): DynamicStrings.String` —
write the string’s characters to `f` and return `s` unchanged. Implement via the
existing `FIO.WriteString(f, …)` (`library/pimdef/FIO.def:16`) after copying the
dynamic string into a local `ARRAY OF CHAR`.

### Fix A3 — `ConvStringReal` (clean-room, thin wrapper)

New `library/pimdef/ConvStringReal.def` + `.mod`. API used by tests:

- `RealToFixedString(r: REAL; place: INTEGER): String`
- `RealToFloatString(r: REAL; sigFigs: INTEGER): String`
- `RealToEngString(r: REAL; sigFigs: INTEGER): String`

Each: call the corresponding `RealStr.RealToFixed/RealToFloat/RealToEng` into a
local `ARRAY OF CHAR`, then `DynamicStrings.InitString` the result. This reuses
the already-correct (after Fix C1) ISO engine, so all 50 `realstr` rows pass.
Note `sigFigs` arrives as `INTEGER` in the test but `RealStr` takes `CARDINAL`
— convert with `VAL(CARDINAL, …)` for the non-negative sig-fig args.

### Fix A4 — `StringConvert` (clean-room)

New `library/pimdef/StringConvert.def` + `.mod`. API used by tests:

- `LongrealToString(r: LONGREAL; width, places: CARDINAL): String` — for
  `real1.mod`. With `(…, 0, 0)` it should render the value in a general form;
  delegate to `RealStr.RealToStr` (→ `XReal.to_any`) into a buffer, then
  `InitString`. `real1` has no exit assertion, so byte-exact output is not
  graded — it must run and produce a plausible string.
- `ToSigFig(s: String; n: CARDINAL): String` — for `real1` and **`sigfig`
  (graded)**. Round the decimal string `s` to `n` significant figures. `sigfig`
  expects e.g. `12.3456789`→3→`12.3`, →4→`12.35`, `19.99`→3→`20.0`,
  `99.999`→3→`100`. This is **string-domain** significant-figure rounding (round
  the digit sequence, propagate carries across the decimal point, keep `n`
  significant digits, drop a now-empty fraction). Implement as a clean-room
  digit-string rounder; do **not** round-trip through `f64` (precision loss
  would break `99.999`→`100`). This is the one genuinely new algorithm.

---

## Implementation plan (prioritized by tests unblocked)

1. **Fix B1 (loader case-collision).** ~1 small change in `newm2-loader`.
   Unblocks **`realconv` immediately (→ green)** and removes Cause B from
   `realstr`. Highest value-per-effort; touches no library content.
2. **Fix C1 (`tail=TRUE`).** Two-line change in `RealStr.mod`. Required for
   `realstr`’s float/eng rows to be correct. Trivial and verified.
3. **Fix A1 `DynamicStrings` + A2 `SFIO`.** Foundation for all remaining four
   tests. Until these exist, real1/realstr/sigfig/stringreal2 cannot even load.
4. **Fix A3 `ConvStringReal`.** With A1+A2+C1 in place, **`realstr` and
   `stringreal2` go green** (engine already correct for fixed; float/eng fixed
   by C1).
5. **Fix A4 `StringConvert`.** Unblocks **`real1`** (runs) and **`sigfig`**
   (graded — needs the `ToSigFig` digit-string rounder).

Ordering note: 1 and 2 are independent and cheap; do them first to bank
`realconv` and to make the engine correct before the wrappers are written.
The single fix that unblocks the **most** tests is the A1 `DynamicStrings`
foundation (4 tests depend on it), but it is only *useful* alongside A2–A4.

---

## Test plan

- **Per-test, after each fix:** from the test directory,
  `<repo>/target/debug/newm2-driver.exe run <name>.mod`, then check `$LASTEXITCODE`
  (PowerShell) / `echo $?`. Pass = exit 0 for the graded tests
  (`realconv`, `realstr`, `sigfig`); `real1`/`stringreal2` pass = "runs to
  completion without Halt/abort and prints the table".
- **Regression guard for C1:** re-run `realconv` after C1 — it must remain
  exit 0 (its float/eng length asserts must not shift).
- **Unit probes (kept out of tree):** for `realstr`’s float/eng rows, assert the
  exact strings `3.9230E+6`, `3.9E+6`, `4E+6`, `392.30E-6`, `390E-6`, `400E-6`,
  `3.9230E+1`, etc. (ISO P445/P446, enumerated in `realstr.mod:72-115`).
- **`ToSigFig` table:** the 7 rows in `sigfig.mod:47-54` are the acceptance set;
  add the boundary carries `19.99`→3→`20.0` and `99.999`→3→`100` as explicit
  unit cases (these break naive `f64` rounding).
- **Wire into the corpus runner:** add the five `.mod` files to whatever drives
  the external conformance corpus (`isolib/run/pass`) so they’re tracked going forward.

---

## Risks / open questions

- **Loader fix scope (B1).** Tightening def-pairing to case-sensitive could in
  principle affect other modules that *intend* to pair across a case difference.
  Audit: NewM2 library files use canonical CamelCase names matching their
  `MODULE` identifiers, so a case-sensitive stem match should be safe — but the
  change must be validated against the full corpus, not just these five tests.
- **`DynamicStrings` allocation semantics.** `sigfig.mod` wraps each row in
  `PushAllocation`/`PopAllocation(TRUE)`. If `PopAllocation`’s `TRUE` (check)
  argument is meant to *assert no leak* and our no-op returns `TRUE`
  unconditionally, the test still passes; a future strict implementation must
  actually balance allocations or it could `Halt`. Decide now whether to ship
  the no-op (pragmatic) or real leak tracking.
- **`StringConvert.ToSigFig` is the only novel algorithm** and the only place a
  subtle rounding bug could re-enter. Must be implemented in the **string/digit
  domain** (carry propagation, e.g. `99.999`→`100`), never via `f64`. This is
  also where `real1`’s high-precision π output is produced, though `real1` is
  ungraded.
- **`LongrealToString(r,0,0)` exact form is unspecified** by the test (no
  assertion). Delegating to `RealToStr`/`to_any` is a judgement call; acceptable
  because only "runs + plausible output" is graded for `real1`.
- **REAL = LONGREAL = f64.** No precision distinction exists in NewM2, so the
  17-significant-digit `digits()` cap in `RealStr`/`XReal` is the binary64 value
  for both. This is correct for these tests and not a source of any failure
  here; `real1`’s "30-figure" displays will simply be f64-accurate (~17 figs),
  which is expected and ungraded.
- **`SEH base-address sanity check failed` JIT warnings** appear on stderr
  during `run`. They are unrelated to these tests (exception-unwind table
  registration is skipped) and did not affect exit codes in any probe; noted so
  they are not mistaken for a conversion fault.
