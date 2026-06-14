# NewM2 Manifesto

The commitments behind NewM2. The plan in [`../NewM2_PLAN.md`](../NewM2_PLAN.md)
is the *how*; this is the *what we will not compromise on*.

## What NewM2 commits to

1. **Rust-first, no hand-written assembly.** Storage allocator,
   coroutines, exception unwinding — all in safe Rust with scoped
   `unsafe`.
2. **LLVM via `inkwell`.** Single source of truth for codegen. Pinned
   to the same major version as the sister project NewCP.
3. **64-bit-first.** No 32-bit mode.
   `x86_64-pc-windows-msvc` is the first supported target.
4. **JIT-first; native `.exe` is the long-term deliverable.**
   `newm2 run` is the default execution model. `newm2 build` produces
   a standalone PE COFF executable that runs without NewM2 installed.
5. **Classical manual memory.** `Storage.ALLOCATE` = `HeapAlloc`;
   `Storage.DEALLOCATE` = `HeapFree`. Every `NEW` is paired with
   `DISPOSE`. No collector, no safepoints, no stack maps.
6. **Phase visibility is a design requirement, not a debug option.**
   Every compiler phase has a stable textual dump and a `dump-*`
   driver command. The driver can stop after any phase.
7. **Two GUI surfaces.** The **Win32 path** goes through `win32def/`
   and `win32apidef/` and is the load-bearing surface.
   The **iGui path** (copied from NewCP into `newm2-runtime/src/igui/`)
   is interim infrastructure — it gives us an editor and visible
   output early; it is *not* the long-term GUI deliverable.
8. **Implemented from specifications.** NewM2 is built from the
   published Modula‑2 language specifications (PIM 4th ed.,
   ISO 10514‑1). Standard library modules are written from
   the ISO interface definitions.
9. **Workspace lint:** `unsafe_op_in_unsafe_fn = "deny"`.
10. **No image format on disk.** The symbol-file cache is a
    regenerable side artifact, not a first-class deliverable.
    Delete the cache at any time without loss of correctness.

## What NewM2 is *not*

- Not a 32-bit compiler.
- Not bound to any specific IDE.
- Not a vehicle for Modula‑2 dialect experimentation. PIM 4 + ISO
  10514‑1 is the target. OO (10514‑2) and Generics (10514‑3) are
  deferred indefinitely.
