# M2WINRT — a Modula-2 runtime support library for NewM2

**Status:** design + Phase 0 starter set landed
**Date:** 2026-06-13
**Branch:** `conformance-to-90`
**Source of requirements:** the clean-room knowledge base of the ADW / Stony Brook
Modula-2 library at `e:\cleanroom` (81 deep recreation docs + reference catalogs).

---

## 1. Why

NewM2 today ships three library families that cover the *standard* surface:

| Family | Dir | What it is |
|---|---|---|
| ISO | `library/isodef` + `isomod` (45/44) | ISO/IEC 10514-1 standard library (Strings, IOChan, StreamFile, WholeStr, RealStr, SysClock, …) |
| PIM | `library/pimdef` + `pimmod` (11) | Wirth PIM library (InOut, FIO, NumberIO, StrLib, MathLib0, …) |
| Runtime primitives | `library/rtdef` (9) | Thin DEFs over the Rust runtime (`NM2File`, `NM2IO`, `NM2Math`, `NM2Storage`, `NM2RT`, …) — bodies live in `newm2-runtime`, not in M2 |
| Win32 API defs | `library/NewM2` (326) | Our own generated Win32 bindings + the def-finder pack |
| COM framework | `library/comlibdef` + `comlibmod` (7) | Partial COM/OLE support |

What's **missing** is the rich *practical* layer the ADW library is famous for: the
utilities and Windows-service wrappers that sit between "the standard says X exists"
and "I can write a real Windows program". The clean-room catalogs that layer in detail.
**M2WINRT is that layer**, re-implemented in clean-room Modula-2 source on top of NewM2's
existing standard library and runtime primitives.

A second, equal goal: **the library is a compiler test.** Every module is real M2 source
the compiler must accept and lower correctly. Generating it exercises open arrays, CHAR
handling, bitwise operators, module-init bodies, procedure-typed parameters (callbacks),
64-bit arithmetic, SYSTEM low-level access, exceptions, and eventually CLASS/COM — i.e.
exactly the language surface conformance work has been hardening. A library that compiles
and produces correct results is a far stronger signal than any single test program.

---

## 2. Dialect bridge: ADW → NewM2

The clean-room docs describe ADW/Stony Brook Modula-2. NewM2 is a deliberately *lenient
ISO-ish* dialect with its own choices. The recreation must translate, not transliterate.
The differences that matter for the library:

| Concern | ADW | NewM2 | Consequence for M2WINRT |
|---|---|---|---|
| `CHAR` width | 8-bit (ASCII build) **or** 16-bit (Unicode build), from one source | **Fixed 16-bit** (Unicode) | NewM2 *is* the Unicode build. Drop the `%IF` dual-build machinery; keep code CHAR-width-neutral anyway (index + `ORD`/`CHR`, never assume byte width). Call the Win32 `…W` variant. |
| `REAL` | 32-bit | **64-bit** (= `LONGREAL`) | ADW `REAL` → NewM2 `REAL32`/`SHORTREAL` where 32-bit is meant; ADW `LONGREAL` → NewM2 `REAL`. Most real code wants `REAL` (f64). |
| `DIV`/`MOD` (signed) | C-like truncating / `REM` in later builds | **Wirth floored** | Number↔string code works on the *magnitude* (capture sign, `ABS` first) so the digit loop only ever divides non-negative values — identical under both rules. Never rely on truncating signed `DIV`. |
| Bitwise | `BAND BOR BXOR BNOT SHL SHR` operators | **Same operators** ✓ | CRC / crypto port directly. |
| Sized ints | `INTEGER8/16/32/64`, `CARDINAL8/16/32/64`, `LONGINT/LONGCARD` | `SHORTINT`(16), `INTEGER`/`CARDINAL` (64), `LONGINT`/`LONGCARD` | `CARDINAL` is **64-bit** here. A 32-bit CRC value is held in `CARDINAL` and masked with `BAND 0FFFFFFFFH`. |
| `SWAPENDIAN` | statement | **absent** | Provide a small portable byte-swap helper in M2WINRT (`MemUtils`/crypto) instead. |
| `IsThread` one-time-init guard | `IF NOT IsThread THEN …` in module bodies | runtime is single-attach today | Module-init bodies run once; the guard is unnecessary. Keep init bodies idempotent regardless. |
| Procedure attributes | `[LeftToRight] [PASS(…)] [ALTERS(…)] [WindowsCall]` | `[Windows]`, `[CDECL]`, EXTERNAL-name strings | Win32-helper layer binds with `[Windows]`; the raw bindings come from `library/NewM2`, not from M2WINRT. |
| Conditional compilation `%IF` | build matrix {ASCII×Unicode}×{IA32×AMD64}×{EXE×DLL} | single target (AMD64, Unicode, JIT+AOT) | Collapse to the one target; no `%IF` blocks. |
| Memory primitives | `SYSTEM.MOVE/FILL/MOVEBYTES`, `SYSTEMC` runtime | `SYSTEM` + `NM2Storage`/runtime | `MemUtils` is implemented over NewM2 `SYSTEM` + runtime helpers, not the ADW `SYSTEMC` asm. |
| Exceptions | ISO `EXCEPT … RETRY`, per-module sources | NewM2 `EXCEPT`/`FINALLY` + `NM2RT` source ids | Error-reporting modules use the NewM2 `EXCEPTIONS`/`NM2RT` surface. |

**Literals are identical** — hex `0EDB88320H` (must start `0`–`9`), octal `377B`, octal-char
`0C`/`15C`. Verified against the NewM2 lexer. CRC/crypto constants port verbatim.

---

## 3. Library layout

M2WINRT follows the established `<family>def`/`<family>mod` convention. The driver's
`push_library_def_dirs` auto-adds **any** `library/*def` subdir to the search path, and the
loader rewrites `winrtdef/Foo.def → winrtmod/Foo.mod` automatically — so **no driver change
is required.**

```
library/
  winrtdef/   M2WINRT DEFINITION MODULEs   (public interface)
  winrtmod/   M2WINRT IMPLEMENTATION MODULEs (bodies)
```

Module names match the ADW originals (`GenCRC`, `ExStrings`, `Conversions`, `MemUtils`,
`SortLib`, …) so each maps 1:1 to its clean-room doc. None of the chosen names collide with
existing ISO/PIM module names (ISO has `WholeConv`/`RealConv`, not `Conversions`; no
`ExStrings`/`GenCRC` anywhere).

---

## 4. Scope — reuse vs. implement vs. exclude

The clean-room library is 81 deep modules + catalogs. NewM2 already provides much of the
*base*. M2WINRT implements only the **delta** — the extensions and Windows-service wrappers.

### 4a. Already provided by NewM2 — DO NOT duplicate
- `Storage`, `Strings`, `WholeStr`/`WholeConv`, `RealStr`/`RealConv`, `SysClock`,
  `TextIO`/`STextIO`, `Semaphores`, `Processes`, math (`RealMath`/`LongMath`) → ISO family.
- `InOut`, `FIO`, `NumberIO`, `StrLib`, `MathLib0` → PIM family.
- Block I/O, storage, low math, program args, clock → `rtdef` primitives.
- Win32 API bindings → `library/NewM2` (326 defs). **M2WINRT never re-binds raw Win32**; it
  layers logic on those bindings (ADW's own `win32api*` modules are 🪟 vendor-binding tier =
  out of scope per the clean-room legend).

### 4b. M2WINRT implements (the delta) — in dependency order

**Tier C0 — self-contained core leaves** (depend only on `SYSTEM` / nothing). *These are the
Phase-0 starter set: pure compiler tests, no OS surface, fully verifiable.*
- `GenCRC` — CRC-32 (reflected poly `0EDB88320H`), 256-entry table built at init.
- `Conversions` — whole↔string, decimal + base 2..16, exact overflow detection.
- `ExStrings` — ISO `Strings` extensions: case-insensitive compare/search, NUL helpers,
  find/replace, appenders (the CHAR-neutral subset; ANSI/UTF-8/WINNLS parts deferred to the
  Win32 tier).
- `MemUtils` — fill/zero/scan/compare/overlap-safe move over `SYSTEM`.
- `SpecialReals` — IEEE-754 f64 special values + bit-pattern predicates.
- `SortLib` — callback-driven Quick/Heap/Shell/Insert/Merge sorts (exercises proc-typed params).
- `Money` (advapi) — 64-bit fixed-point currency (exercises `LONGINT` 64-bit arithmetic).

**Tier C1 — core, needs storage/clock** (depend on ISO `Storage`/`SysClock`).
- `FormatString` (printf-style), `RandomNumbers`/`RealRandomNumbers`, `TimeFunc`,
  `ElapsedTime`, `RConversions`, `BitVectors`.

**Tier W — Win32 helpers** (the "crown jewels"; depend on `library/NewM2` bindings).
- `Environment`, `Registry`, `FileFunc`, `Threads`, `Socket`, `NamedPipes`, `PipedExec`,
  `RunProg`, `FileMap`, `MemShare`, `ConfigSettings`, `Timers`.
- GUI frameworks (`WinShell`, `DlgShell`, `BasicDialogs`, `Terminal`, …) are a large later
  effort — designed but not scheduled here.

**Tier X — COM / crypto** (depend on the COM CLASS model and/or the Win32 tier).
- Crypto (`AES`, `SHA*`, `MD5`, `HMAC`, `GenCRC` already in C0) is *mostly self-contained* and
  excellent compiler fodder (big tables, bitwise, `SWAPENDIAN`-replacement) — can be pulled
  forward opportunistically.
- COM (`ClassFactory`, `QITable`, …) builds on NewM2's existing `comlibdef` + the CLASS/vtable
  work already proven (COM-server + native-callback sprints).

### 4c. Excluded (per clean-room legend / NewM2 scope)
- 🪟 **Vendor-binding tier**: ADW's `win32api*`, `OOle2`, `OleC`/`OleCtl`, OpenGL bindings —
  regenerated from public headers; NewM2 uses `library/NewM2` instead.
- 📖 **Catalog-only** ISO modules already covered by NewM2's ISO family.
- DLL-aggregator / link-trigger glue (`SBM2RTL`, `SetExStorageDebugMode`) — artifacts of the
  ADW build model, not meaningful under NewM2's loader.
- Insecure primitives the modernization sweep deprecates (RC4/DES/MD5/SHA-1 for *new* use,
  cleartext SMTP) are implemented only where needed for interop/compat and flagged, never as
  recommended defaults.

---

## 5. House style (matches existing `library/*`)

- File opens with a `(* … *)` clean-room provenance comment stating the interface is the
  standard/algorithm itself, not any vendor's expression — exactly like `pimdef/ASCII.def`.
- `DEFINITION MODULE` declares only `CONST`/`TYPE`/`VAR`/`PROCEDURE` headers; `IMPLEMENTATION
  MODULE` carries bodies and module-global state.
- Strings are NUL-terminated, capacity-bounded `ARRAY OF CHAR`; length by scanning to `0C`,
  never by `HIGH` (which is capacity−1). Open-array callees use `HIGH(a)`.
- No `%IF`, no `<*/…*>` build pragmas, no procedure register-attributes in portable modules.
- 64-bit `CARDINAL`/`INTEGER`; mask to 32 bits with `BAND 0FFFFFFFFH` where a 32-bit algorithm
  demands it.

---

## 6. Build / test strategy

Each M2WINRT module is validated three ways, cheapest first:

1. **`newm2 check`** — the def+mod parse, type-check, and sema-analyze cleanly.
2. **A driver `run` test** — a `Mod/tests/t-90-2xx-*.mod` program imports the module and prints
   results the JIT harness asserts (`check("t-90-2xx.mod", "expected\n")` in
   `tests/newm2-tests/tests/m2_tests.rs`). The library dir is on the search path automatically.
3. **Known-answer vectors** where they exist — CRC-32("123456789") = `0CBF43926H`; base-16 of
   255 = "FF"; etc. — so "compiles" is upgraded to "computes correctly".

M2WINRT adds library files, not conformance-corpus entries, so the ISO conformance
scoreboard is unaffected and must stay green.

---

## 7. Phase 0 starter set (this commit)

Landed under `library/winrtdef` + `library/winrtmod`, each with a `Mod/tests` proof:

| Module | Exercises | Known-answer proof |
|---|---|---|
| `GenCRC` | module-init table build, `BXOR`/`SHR`/`BAND`, hex literals, open `ARRAY OF CHAR`, 32-bit-in-64-bit masking | CRC-32("123456789") = `0CBF43926H` |
| `Conversions` | numeric loops, magnitude/sign split (DIV/MOD bridge), base 2..16, `VAR OUT` results, overflow flag | `CardBaseToStr(255,16)`="FF", round-trips |
| `ExStrings` | CHAR-neutral open-array string ops, `CAP`, case-insensitive compare/search, find/replace | deterministic string asserts |

These three are the bottom of the build order (Tier C0), need no OS surface, and are fully
deterministic — the ideal first compiler exercise. Subsequent phases add the rest of Tier C0,
then C1, then the Win32 crown jewels.

---

## 8. Security / Windows-11 deprecation discipline

The library is recreated with the modernization sweep baked in, not bolted on. The authoritative
per-finding, phase-gated checklist is **[m2winrt-security-checklist.md](m2winrt-security-checklist.md)**
(consolidated from the clean-room `modernization/` sweep). The rules that bind each phase:

- **Phase 1 (this set):** only `MemUtils` carries a real obligation — it is the home of the
  hardening primitives the crypto phase depends on, so it ships a **non-elidable `SecureZeroMem`**
  (anchored against dead-store elimination via a module-global observable sink) and a
  **constant-time `EqualCT`**, and a *working* `ZeroMem` (ADW shipped a stub). `Money` carries a
  financial-correctness obligation (checked overflow / defined rounding), met by the 128-bit
  intermediate. `SpecialReals`/`SortLib` are pure-compute with no obligation.
- **Later phases** inherit hard rules: **P2** splits a CSPRNG (`BCryptGenRandom`) away from the
  non-crypto `RandomNumbers` (which must carry a NOT-FOR-SECURITY contract); **P3** launches
  processes via `CreateProcessW` (no shell), defaults config to HKCU, re-bases locks on SRWLOCK;
  **P4** crypto is a **CNG façade** (no roll-your-own MD5/SHA-1/RC4/DES, AES-256-GCM by default);
  **P5** networking is TLS-only (Schannel/WinHTTP), IPC objects get least-privilege DACLs. Unicode
  (W APIs, `CP_UTF8`) and the exploit-mitigation/manifest/signing build flags are cross-cutting.

## 9. Compiler work driven by this library

Building the library is also a compiler test; gaps found get fixed in the compiler. Four real bugs
were found and fixed (the last three surfaced by an adversarial verification sweep over the Phase-1
modules — the happy-path tests passed while these latent faults hid in untaken branches):

- **`CONST = CAST(<floatType>, <bits>)` type + value** (needed by `SpecialReals`). Two linked
  fixes: (a) sema now types such a CONST as the cast's **target type** (it was inferring the
  value-derived type, so `CONST Inf = CAST(REAL, 07FF…H)` couldn't be assigned to a `REAL`); and
  (b) the const folder now **bit-reinterprets** across the int↔float boundary so the folded *value*
  is a real (matching a runtime `BitCast`) — previously the value stayed an integer bit pattern and
  codegen emitted a raw `i64` where a `double` was expected (an LLVM-verify failure on argument
  passing). `newm2-sema` (`analyze.rs eval_const_decl`, `constant.rs reinterpret_cast_const`).
- **Boolean `AND`/`OR`/`&` did not short-circuit** — a serious core-semantics bug. `FALSE AND f()`
  evaluated `f()`; the classic `(i <= HIGH(a)) AND (a[i] = x)` guard idiom would index out of range.
  They now lower as control flow (evaluate the rhs only when the lhs doesn't decide the result),
  merging through a boolean stack slot. `newm2-ir` (`lower.rs eval_short_circuit`). *This is what
  made `SortLib`'s Shell/Heap/Binary/Merge sorts crash on a left-shift — the module was correct;
  the compiler wasn't.*
- **REAL `#` was ordered not-equal** (`fcmp one`) so `NaN # NaN` was FALSE — i.e. NaN spuriously
  "equal" to NaN, and `#` not the negation of `=`. Now unordered (`fcmp une`), matching IEEE-754;
  the order comparisons stay ordered. `newm2-llvm` (`codegen.rs emit_binary`).
- **`CARDINAL DIV`/`MOD` by a non-negative named CONST used signed division** — a dividend with
  bit 63 set (e.g. `MAX(CARDINAL)/2 < x`) was divided as a negative value, so `mag DIV Scale`
  (Scale a `CONST = 10000`) returned garbage while `mag DIV 10000` was correct. The unsigned-select
  predicate now treats a non-negative compile-time constant as unsigned-compatible (it adapts to the
  unsigned operand like a literal), keeping the requirement that one operand be unsigned-*typed* so
  `intVal DIV Scale` stays signed. `newm2-ir` (`lower.rs unsigned_compatible`). *This surfaced via
  `Money`'s MIN/MAX-value arithmetic.*

All four landed with the conformance gate green; the latter three are locked by
`t-90-215-compiler-semantics`.

### Direct Win32 from M2 at AOT (Phase 2 enabler)

M2WINRT calls the Windows API **directly** from Modula-2 via the generated def pack's
`["Name" EXTERNAL FROM "x.dll"]` bindings — not through a Rust shim (those are retired). This worked
at JIT but not AOT; two fixes made it work end to end:

- **Symbol naming** (`newm2-ir lower.rs`): a DLL-imported proc now emits its *import name*
  (`QueryPerformanceFrequency`) as the LLVM symbol, not the M2-qualified
  `System_Performance.QueryPerformanceFrequency` (which left an unresolvable external at link time).
- **Import-library collection** (`newm2-driver main.rs`): the AOT linker now derives its `.lib` list
  from the program's actual `EXTERNAL FROM "x.dll"` declarations (`KERNEL32.dll` → `kernel32.lib`),
  so a direct call to any DLL links — `kernel32`, `winmm`, `bcrypt`, `gdi32`, … — not just a fixed set.

Verified JIT+AOT: `QueryPerformanceCounter` (kernel32), `timeGetTime` (winmm), `BCryptGenRandom`
(bcrypt). Conformance stayed green.

- **Integer → pointer FFI arg coercion** (`newm2-llvm codegen.rs`): an integer passed to a
  pointer-typed parameter now reinterprets via `inttoptr`, matching C FFI. `ADRCARD`/`ADRINT` params
  lower to `ptr`, so a literal `0` for `CreateThread`'s `dwStackSize: ADRCARD` was emitted as an `i64`
  and failed the LLVM verifier; it now becomes a null pointer. This is what unblocked direct
  `CreateThread` (and any Win32 call with an `ADRCARD`/`ADRINT` parameter).

**Known issue (pre-existing, deferred):** `CAST(<record/array>, <scalar>)` — e.g.
`CAST(BCRYPT_ALG_HANDLE, 0)` where the handle is `RECORD Value: ADDRESS END` — panics in codegen
(the transfer-cast classifier returns nothing for an aggregate, and the fallthrough evaluates the
type-name argument as a value). It only manifests on actual codegen (the ISO `iso/pass` corpus is check-only, so
the gate doesn't catch it). The idiomatic workaround works and is what M2WINRT uses: assign the
field directly (`h.Value := NIL`). A proper fix is a same-size memory-reinterpret in the lowering —
its own focused change.

## 10. A note on set sizing (out of scope here, tracked)

NewM2 represents **every** `SET`/`BITSET` as a 256-bit value regardless of element range, so a
`SET OF [0..63]` occupies 32 bytes, not 8. This is *not* a constant-folding problem (the symptom
that first looked like one was the `CONST CAST` bug above) — set *construction/assignment* across
sizes works fine. But it does mean a set cannot `CAST` to a same-width integer and won't overlay a
32/64-bit Win32 flags field, which the ADW library and ISO both assume. A global **set-size pragma
is the wrong fix** (mode-dependent layout is fragile and un-Modula-2); the right fix is
**range-sized sets** (`SET OF [0..N]` → the smallest natural byte width holding N+1 bits, capped at
32 bytes), which is ISO-faithful and restores set↔int CAST and FFI overlay. It's a substantial
codegen change (all union/intersection/`IN`/`INCL`/`EXCL` lowering) and is tracked as its own task,
not bundled into M2WINRT. For now M2WINRT simply does not export the few would-be sized-set types
(e.g. `SpecialReals.BITSET64`).

## 11. Roadmap

- **Phase 0 (done):** `GenCRC`, `Conversions`, `ExStrings` + proofs; this design doc.
- **Phase 1 (done):** rest of Tier C0 — `MemUtils`, `SpecialReals`, `SortLib`, `Money` + proofs
  (`t-90-211..214`); security checklist; the `CONST CAST` compiler fix.
- **Phase 2 (done):** the security split — `RandomNumbers` (non-crypto lagged-Fibonacci, loud
  NOT-FOR-SECURITY contract) + `SecureRandom` (OS CSPRNG via a **direct** `BCryptGenRandom` call,
  unbiased rejection sampling, fail-closed) — satisfies the P2 critical gating rule. Plus `TimeFunc`
  (proleptic-Gregorian calendar math: weekday, ANSI-C `time_t`, DOS/FAT), `ElapsedTime` (timing via
  **direct** QPC + `Sleep`), and `FormatString` (printf-style via a **non-variadic typed-argument
  vector** — NewM2 can't iterate C `...` varargs; the `%`-spec grammar/width/justification/escapes
  are otherwise faithful, numbers via `Conversions`). All known-answer / property verified, JIT+AOT.
  Proofs `t-90-216..220`.
- **Phase 3 (done):** the Win32-helper tier, calling the Windows W-APIs **directly** from M2
  (NewM2's 16-bit CHAR *is* WCHAR, so `ARRAY OF CHAR` is the wide buffer; `HANDLE`/`HKEY`/`HMODULE` are
  plain `ADDRESS`). `Environment` (env vars / exe path / command line), `Registry` (typed advapi32
  wrapper, **HKCU-default** per the P3 rule), `FileFunc` (binary file create/read/write/seek/size/
  delete), and `Threads` — **real OS threads running M2 code** plus a recursive `CRITICAL_SECTION`
  lock (`CreateThread`/`WaitForSingleObject`/`InitializeCriticalSection`/…). Feasible because the
  default/AOT memory mode has **no GC**, so a procedure runs on a thread NewM2 didn't create without
  root registration; the concurrency test (8 threads × 50k increments under the lock = exactly 400000)
  proves correct mutual exclusion. Proofs `t-90-221..224`, JIT+AOT. Richer `FileFunc` (FindFirst/Next
  enumeration, buffered line I/O) and the fuller `Threads` surface (TLS, condition variables, rwlocks)
  layer on the landed cores.
- **Phase 4 (done):** crypto as a **CNG façade** over `bcrypt.dll` — no algorithm re-implemented in
  M2, and only modern primitives exposed (MD5/SHA-1/RC4/DES/ECB are *not*). `Hash` (SHA-256/384/512
  via `BCryptHash` + Win10 pseudo-handles), `HMAC` (HMAC-SHA256, constant-time `Verify` via
  `MemUtils.EqualCT`), `CryptKey` (PBKDF2-HMAC-SHA256 via `BCryptDeriveKeyPBKDF2`, ≥600k-iter
  recommendation), and `SymCrypt` (**AES-256-GCM AEAD** — `BCryptEncrypt`/`Decrypt` with the
  authenticated-cipher-mode struct; **fail-closed** tag verification rejects tampered ciphertext *and*
  AAD). Nonces/salts come only from `SecureRandom`. Known-answer verified (FIPS-180 SHA, RFC 4231
  HMAC, RFC-6070-style PBKDF2 cross-checked vs Python) + AES-GCM round-trip/tamper. Proofs
  `t-90-225..228`, JIT+AOT.
- **Phase 5 (in progress) — COM:** `Com` (COM/OLE lifecycle + activation over ole32 —
  `CoInitializeEx`/`CoUninitialize`/`CoGetMalloc`/`CoCreateInstance`/`CoTaskMemFree`); `Guid`
  (GUID/CLSID parse/format + ProgID→CLSID resolution); and `Dispatch` (late-bound **IDispatch**
  Automation — resolve a member name to a DISPID and `Invoke` it, hiding the IID_NULL/DISPPARAMS/
  VARIANT machinery behind a by-name API). COM interfaces are consumed with the CLASS-as-interface
  pattern (an `ABSTRACT CLASS` with the methods in vtable order — NewM2's class layout *is* the COM
  ABI). `Dispatch` is a **complete late-bound Automation client**: a general `Invoke(obj, name, flags,
  args[], nargs, result)` over a VARIANT API — build arguments with `VInt`/`VBool`/`VStr`, read
  results with `AsInt`/`AsBool`/`AsStr`/`AsObj`, release with `Clear` (VariantClear). It marshals
  **multiple, mixed-type arguments** (BSTR via SysAllocString) and reads every common result type.
  Proven by driving a live `Scripting.Dictionary` end to end — `Add(string, int)` (2-arg method),
  `Count` (property-get), `Item(string)` → int (parameterized property), `Exists(string)` → bool —
  and `Scripting.FileSystemObject` string methods (`GetExtensionName`/`GetBaseName`). Proofs
  `t-90-229..233`, JIT+AOT. One subtlety baked in: a *virtual* COM method returns the 32-bit HRESULT
  in EAX (zeroing RAX's upper half), so success is the HRESULT severity bit (31), not the 64-bit
  sign; another: DISPPARAMS wants the argument VARIANTs in reverse order. The COM **server** side (an
  M2 CLASS *implements* a COM interface for external callers) is proven separately by `t-90-110` and
  the `comlibdef` ClassFactory/QITable. TLS networking is **out of scope** (per request); GUI last.

- **Phase 6 (started) — the runtime heap, in M2:** `Heap` is a self-hosted memory allocator
  written entirely in Modula-2. It obtains raw, zeroed pages straight from the OS via `VirtualAlloc`
  (no C/CRT or OS allocator underneath) and carves them with its own **boundary-tag free list**: each
  block header holds its own size (16-byte granular, low 4 bits = flags) plus the previous *physical*
  block's size, so adjacent free blocks coalesce in O(1) on free with no footer. First-fit search;
  oversized free blocks are split; each OS chunk ends in a permanently-"allocated" sentinel so
  coalescing and walks never run off the chunk; payloads are 16-byte aligned (SIMD-safe). The
  `Allocate`/`Deallocate` surface matches **ISO Storage**, and the standard ISO `Storage` module now
  **delegates to `Heap`** (`library/isomod/Storage.mod` — `ALLOCATE`/`DEALLOCATE`/`Available` call
  `Heap`), so the layering `Storage` (ISO façade) → `Heap` (M2 engine) → `VirtualAlloc` runs end to
  end. `NEW`/`DISPOSE` can also be routed onto the M2 heap with the **`--m2-heap`** compiler flag:
  codegen then lowers `Inst::Allocate`/`Inst::Deallocate` to call `Heap.Alloc`/`Heap.Free` (value
  entry points, same `(i64)->ptr` / `(ptr)->void` ABI as the Rust `nm2_alloc`/`nm2_free` they replace)
  and the driver force-links the `Heap` module even when the program never imports it
  (`build_module_graph_with_extra_roots`). The flag is **off by default** — without it, `NEW`/`DISPOSE`
  keep using the Rust runtime allocator (`src/newm2-runtime/src/heap.rs`), so the conformance corpus and
  every existing program are unaffected. This is the gating the self-hosted heap needed: opt-in, not a
  hard switch. Proven by `t-90-238` (NEW serviced by the M2 heap — `Heap.BytesInUse` moves) and
  `t-90-239` (a 10-node list built/freed with NEW/DISPOSE and **no `Heap` import** — force-link works),
  JIT+AOT.
  Proven by `t-90-234` (64 distinct-pattern blocks must not overlap; free/re-alloc must not corrupt
  neighbours; a 500 KB block must fit only after the freed blocks recoalesce) and `t-90-235` (4000
  rounds of pseudo-random alloc/free with per-block pattern checks and a `Validate()` structural walk
  every 200 rounds), JIT+AOT. Not yet covered: an internal recursive lock (ExStorage uses a
  `CRITICAL_SECTION` — callers currently serialise, per the "not thread-safe, callers lock" model),
  multi-heap partitions, `Reallocate`, and chunk release back to the OS on shrink.

Each phase is gated on the previous compiling and its proofs passing, on the conformance gate
staying green, and on honouring the security checklist rules that gate it.
