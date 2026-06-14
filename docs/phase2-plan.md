# NewM2 — Phase 2 plan: Conformance, Robustness & Productization

Phase 1 (Sprints A–H + WITH/COMPLEX/SHIFT-ROTATE/coroutines + OO/COM) made the
language **execute** — e2e 61 → 95, all green, pushed. Phase 2 makes it
**trustworthy, complete, and shippable**. Per the ISO read, the remaining
distance is dominated by *verification* and a few capability gaps, not missing
language features.

## Scope decisions (2026-06-10)
- **North-star: conformance & hardening first** — lead with I → J → K.
- **AOT standalone `.exe` output: IN** (Sprint L).
- **OS-thread Processes: DEFERRED** — stays interface-only (`.def` without
  `.mod`); cooperative concurrency is covered by coroutines/fibers. Document it
  as an explicit non-goal for this phase.
- **COM server: sink/callback proof only** (Sprint M scoped down) — `IUnknownImpl`
  base + a callback/sink interface passed to an OS API; full in-proc server
  (`CoRegisterClassObject`/`DllGetClassObject` + class factory) deferred.

## Grounded facts shaping the plan
- Compiler is **JIT-only**: driver has `run` / `emit-asm` / `emit-llvm-ir` /
  `dump-*` but no link-to-`.exe`. → Sprint L.
- ISO library is **real, not stubs** (RndFile 366 lines, math 110–176, …) but
  only the I/O subset is test-verified. → Sprints I/J are *audit + harden*, not
  *rewrite*.
- `library/isodef/Processes.def` has **no `.mod`** (interface-only). → deferred.
- Only standard ISO 10514-1 library module *missing* entirely: **TERMINATION**.

## Sprints

### I — Conformance harness + library audit (foundation; first)
Highest-leverage: converts "works in practice" → "provably conformant" and
produces the defect list that drives J–K. Exercise **every** ISO library module
(not just the tested I/O subset) — port a reference M2 conformance suite if one
exists, else systematic per-module tests — into the existing DB-backed harness.
**Deliverable:** a feature×module pass/fail matrix + ranked bug list.

### J — Library hardening (gated on I)
Fix surfaced defects module-by-module (RndFile, the four math modules,
RawIO/SRawIO, conversion overflow/precision, Strings edge cases, channel
error/result semantics). Add **TERMINATION**. **Deliverable:** the standard
library passes the matrix.

### K — Language-conformance gaps
**LOCAL MODULE** real implementation (today a guard); method bodies with
`EXCEPT`/`FINALLY` (today simplified); semantics audit — exact range/overflow
checks, exact M2EXCEPTION raising conditions, `FLOAT`/`TRUNC`/`ENTIER` rounding,
numeric-promotion corners. **Deliverable:** language gaps closed or explicitly
documented.

### L — AOT executable output (productization)
Emit object files (LLVM → `.obj`), link to a Windows `.exe` (lld-link/link.exe),
bundle the statically-linked runtime + a C entry stub that runs module
initializers (topo) then finalizers (LIFO) and installs the crash/SEH handler.
New `build -o prog.exe` driver command; resolve NM2RT/Win32 externals.
**Deliverable:** `newm2 build prog.mod -o prog.exe` → a standalone runnable.
**Risk:** linking, runtime bundling, SEH-in-AOT.

### M — OO/COM completion (sink/callback scope)
COM **server** sink/callback proof: `IUnknownImpl` base (Interlocked
ref-counting + IID-table `QueryInterface`) + implement a callback/sink interface
passed to an OS API. Also: **type guards** (`obj(T)` runtime checks via class
identity), **REVEAL** access enforcement (parsed, not enforced). Full in-proc
server + multi-interface QI deferred. **Deliverable:** M2 implements a COM
interface the OS calls back; 10514-2 OO more complete. See
`docs/com-server-design.md`.

### N — Real-world validation + perf + diagnostics (capstone; last)
Compile + run a substantial real Modula-2 program end-to-end (M2NEW donor tree
or a known ISO program); tune `-O` levels + baseline benchmarks;
diagnostics-quality pass (messages, source locations). **Deliverable:** a
non-trivial real program builds and runs; perf baseline.

## Sequencing
`I → J` gated. `K`, `L`, `M` independent, parallelizable after `I`. `N` capstone.
Conformance-first order: **I, J, K**, then **L** and **M**, then **N**.
