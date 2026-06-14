# Self-hosting the NewM2 runtime in Modula-2

**Goal.** Re-implement the NewM2 runtime — today the Rust crate `newm2-runtime`
(97 `nm2_*` C-ABI entry points) — in Modula-2, calling Win32 directly, so the
compiler can ultimately **switch its default off the Rust runtime**. The order
is: finish the M2 runtime behind a gate, prove it green across the conformance
corpus, then flip the default.

This continues the original clean-room library sprints (M2RTS, InOut, StdIO,
FIO, MathLib0, SysClock, …). Those built the M2 *library* layer; many modules
still **delegate to Rust `nm2_*` shims**. Self-hosting = replacing each
delegation with direct M2 / Win32, exactly as `Storage`→`Heap` and `SysClock`
did.

## Two integration styles

- **Service modules** (a `library/*mod` file delegates to a Rust shim): just
  rewrite the module to compute / call Win32 directly. Always-on, no flag, no
  codegen change. Risk is bounded to that module; gate is the conformance run.
  *Examples done:* `Storage`→`Heap`, `SysClock`→`GetSystemTime`.
- **Codegen-emitted intrinsics** (the compiler emits a call to `nm2_*`): provide
  an M2 implementation under a known symbol and have codegen target it, gated by
  a flag (the driver force-links the providing module). *Example done:*
  `NEW`/`DISPOSE`→`Heap.Alloc`/`Heap.Free` under `--m2-heap`.

The flags will converge into a single **`--m2-runtime`** umbrella (today
`--m2-heap`); when it's green across the corpus, it becomes the default.

## The 97-seam inventory

### Done
| Seam | Replacement | Style |
|---|---|---|
| `nm2_alloc` / `nm2_free` | `Heap.Alloc` / `Heap.Free` (VirtualAlloc free-list) | intrinsic, `--m2-heap` |
| `nm2_storage_allocate/deallocate` | `Storage`→`Heap` (ISO façade) | service (always-on); shim now orphaned |
| `nm2_sysclock_now` | `SysClock`→`GetSystemTime` | service (always-on) |

### Category A — codegen-emitted intrinsics (need M2 + gating)
- `nm2_shift`, `nm2_rotate` — `SYSTEM.SHIFT`/`ROTATE`; pure M2 (mask + shift). **Easy.**
- `nm2_string_length`, `nm2_wstr_length`, `nm2_copy_string`, `nm2_copy_wstring` — NUL-terminated helpers; pure M2. **Easy.**
- `nm2_sort_i64` — sort intrinsic; pure M2 (we already have `SortLib`). **Easy.**
- `nm2_assert_failed` — message + halt. **Easy** (needs IO + halt).
- `nm2_halt`, `nm2_term_*` — `HALT`/termination; `ExitProcess` + a halted flag. **Easy-medium** (watch the `aot_termination` exit-code question).
- `nm2_coroutine_*` — fibers; direct `CreateFiber`/`SwitchToFiber`. **Medium.**

### Category B — service modules delegating to Rust (convert in place)
- `nm2_math_*` (`frexp`/`ldexp`/`modf`/`arctan2`/`pow`/`trunc`) — `LongMath`/`RealMath`. `frexp`/`ldexp`/`modf`/`trunc` are pure bit/float ops in M2 (the `CAST(CARDINAL,REAL)` trick from `SpecialReals`); `arctan2`/`pow` need a series or the CRT. **Medium.** (`MathLib0`, Sprint Z, already has clean-room PIM reals to draw on.)
- `nm2_file_*` (`open`/`read`/`write`/`seek`/`size`/`tell`/`close`/`flush`/text) — `FIO`. Direct `CreateFileW`/`ReadFile`/`WriteFile`/… — `FileFunc` already proves the pattern. **Medium.**
- `nm2_io_*` (`write_str`/`int`/`card`/`char`/`ln`/`text`/`read_text`/`peek`/`consume`/`flush`) — `StdChans`/`TermFile`/console. Direct `WriteFile`/`ReadFile` on the std handles. **Hard-ish:** the JIT test harness captures stdout through the Rust `nm2_io_*` path (`nm2_test_capture`), so a direct-Win32 console module must preserve in-process capture for tests (or the harness must capture the real handle).
- `nm2_program_args_*` — `ProgramArgs`. **Coupled, not a clean win:** the Rust shim lets the *driver* inject the program's args independently of the host process; `GetCommandLineW` would feed the test runner's / launcher's command line in JIT. Needs a JIT-vs-AOT split or to keep the injection seam.

### Category C — host/bootstrap glue (likely stays Rust, or deep)
- Exceptions: `nm2_raise_m2`, `nm2_reraise`, `nm2_run_protected`, `nm2_exception_handled`, `nm2_current_*`, `nm2_*_source`, `GetExceptionMessage` — bound to codegen landing pads + the unwinder/personality. **Deep**; the hardest piece, probably last and possibly permanent-Rust.
- GC: `nm2_new_rec`, `nm2_register_module_roots`, `nm2_gc_*`, `nm2_pin`/`unpin`, `nm2_safepoint`, `nm2_collect`, `nm2_register_thread` — **out of scope** (no-GC is the default/AOT model).
- Bootstrap: `nm2_aot_run`, `nm2_finalize_jit_symbols`, `nm2_register_jit_symbol`, `nm2_install_crash_handler`, `nm2_libc_*` — JIT/AOT/CRT glue, stays Rust.
- COM server: `nm2_com_*`, `nm2_guid_eq` — the M2 COM *client* is done (`Com`/`Guid`/`Dispatch`); these back the server/driver glue.

## Ordering

1. **Category A easy intrinsics** under `--m2-runtime`: shift/rotate, strings, sort, assert. Pure computation, no OS subtlety. (Builds the umbrella flag.)
2. **Category B service modules**: math (the pure parts first), file (`FIO`). Always-on, conformance-gated.
3. **IO** — design the capture-preserving console module; the largest single win (433 Rust lines) and unblocks making `--m2-runtime` self-sufficient for I/O-heavy programs.
4. **Termination / halt / coroutines** under the umbrella.
5. **ProgramArgs** — JIT/AOT split.
6. Re-run the **full conformance corpus under `--m2-runtime`**; when green, **flip the default**. Category C (exceptions, GC, bootstrap) remains Rust unless/until separately tackled.

## Switch criterion

`--m2-runtime` (the unified gate) compiles and runs the whole conformance
corpus and the `t-90-*` suite with **no regression below baseline**, in both JIT
and AOT. At that point the M2 runtime is the default and the Rust `nm2_*`
entry points it replaced are retired (kept only for Category C).

## Status (Sprint N)

Heap (engine + ISO Storage façade + `--m2-heap` for NEW/DISPOSE) and SysClock
self-hosted; `NM2Storage` shim orphaned. Next: the Category-A easy intrinsics
behind `--m2-runtime`.
