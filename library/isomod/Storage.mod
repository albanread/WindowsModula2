(* Copyright (c) xTech 1993,95. All Rights Reserved. *)
(* Ported to NewM2 2026-05-15 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - ALLOCATE / DEALLOCATE are backed by `Heap`, the self-hosted
       Modula-2 allocator (a boundary-tag free list carved from raw
       VirtualAlloc pages — no C/CRT or OS allocator underneath). This
       module is the ISO Storage façade in the heap_synthesis layering:
         Storage (this module)  ->  Heap (the M2 engine)  ->  VirtualAlloc.
       Same semantics as before: ALLOCATE writes NIL for size=0 or on
       out-of-memory; DEALLOCATE clears the slot to NIL after freeing.
     - The XDS source guarded DEALLOCATE-of-NIL with an EXCEPTIONS RAISE
       — kept here. `StorageException` reports the underlying source.
     - NewM2's `NEW` / `DISPOSE` builtins still lower directly to
       `Inst::Allocate` / `Inst::Deallocate` (the Rust nm2_alloc/nm2_free)
       and do NOT yet route through this module; doing so is the next
       self-hosting step. `Storage.ALLOCATE` is used by code that calls it
       explicitly (ISO `FROM Storage IMPORT ALLOCATE, DEALLOCATE`).
*)
IMPLEMENTATION MODULE Storage;

IMPORT SYSTEM, EXCEPTIONS, Heap;

VAR source: EXCEPTIONS.ExceptionSource;

PROCEDURE ALLOCATE(VAR a: SYSTEM.ADDRESS; size: CARDINAL);
BEGIN
  Heap.Allocate(a, size);
END ALLOCATE;

PROCEDURE DEALLOCATE(VAR a: SYSTEM.ADDRESS; size: CARDINAL);
BEGIN
  IF a = NIL THEN
    EXCEPTIONS.RAISE(source, VAL(CARDINAL, ORD(nilDeallocation)),
                     "Storage.DEALLOCATE: first argument is NIL");
  END;
  Heap.Deallocate(a, size);
END DEALLOCATE;

PROCEDURE Available(amount: CARDINAL): BOOLEAN;
VAR a: SYSTEM.ADDRESS;
BEGIN
  IF amount = 0 THEN
    RETURN TRUE;
  END;
  (* Probe the heap: a successful trial allocation is freed again. *)
  Heap.Allocate(a, amount);
  IF a = NIL THEN
    RETURN FALSE;
  END;
  Heap.Deallocate(a, amount);
  RETURN TRUE;
END Available;

PROCEDURE IsStorageException(): BOOLEAN;
BEGIN
  RETURN EXCEPTIONS.IsCurrentSource(source);
END IsStorageException;

PROCEDURE StorageException(): StorageExceptions;
BEGIN
  RETURN VAL(StorageExceptions, EXCEPTIONS.CurrentNumber(source));
END StorageException;

BEGIN
  EXCEPTIONS.AllocateSource(source);
END Storage.
