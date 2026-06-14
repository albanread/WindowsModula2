(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-15 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - XDS layers Semaphores on the cooperative Processes scheduler:
       Claim() suspends on a wait queue when count = 0. NewM2 doesn't
       have Processes yet (deferred until a coroutine runtime lands),
       so this single-threaded port can never block — Claim() on a
       count of 0 raises a Semaphores exception via NM2RT.
     - Once Processes are available this can be revised to actually
       suspend the calling process; the public API is unchanged so
       user code won't notice the upgrade.
*)
IMPLEMENTATION MODULE Semaphores;

IMPORT Storage, SYSTEM, NM2RT;

TYPE
  Semaphore  = POINTER TO SemaphoreRec;
  SemaphoreRec = RECORD
    count: CARDINAL;
    magic: CARDINAL;  (* tag for sanity checks *)
  END;
  SEMAPHORE = Semaphore;

CONST
  semMagic = 5365;  (* arbitrary tag to detect use-after-Destroy *)

VAR
  semExceptionSource: CARDINAL64;

PROCEDURE raiseSem(num: CARDINAL; msg: ARRAY OF CHAR);
BEGIN
  NM2RT.Raise(semExceptionSource, num, msg);
END raiseSem;

PROCEDURE Create(VAR s: SEMAPHORE; initialCount: CARDINAL);
  VAR a: SYSTEM.ADDRESS;
BEGIN
  Storage.ALLOCATE(a, SYSTEM.TSIZE(SemaphoreRec));
  s := SYSTEM.CAST(SEMAPHORE, a);
  IF s = NIL THEN
    raiseSem(1, "Semaphores.Create: out of memory");
    RETURN;
  END;
  s^.count := initialCount;
  s^.magic := semMagic;
END Create;

PROCEDURE Destroy(VAR s: SEMAPHORE);
  VAR a: SYSTEM.ADDRESS;
BEGIN
  IF s = NIL THEN RETURN END;
  IF s^.magic # semMagic THEN
    raiseSem(2, "Semaphores.Destroy: invalid semaphore");
    RETURN;
  END;
  s^.magic := 0;
  a := SYSTEM.CAST(SYSTEM.ADDRESS, s);
  Storage.DEALLOCATE(a, SYSTEM.TSIZE(SemaphoreRec));
  s := NIL;
END Destroy;

PROCEDURE Claim(s: SEMAPHORE);
BEGIN
  IF (s = NIL) OR (s^.magic # semMagic) THEN
    raiseSem(2, "Semaphores.Claim: invalid semaphore");
    RETURN;
  END;
  IF s^.count = 0 THEN
    (* In a single-threaded port we can't block; instead raise so
       user code can decide.  Use CondClaim if blocking-vs-fail-fast
       semantics matter. *)
    raiseSem(3, "Semaphores.Claim: would block (no Processes scheduler)");
    RETURN;
  END;
  DEC(s^.count);
END Claim;

PROCEDURE Release(s: SEMAPHORE);
BEGIN
  IF (s = NIL) OR (s^.magic # semMagic) THEN
    raiseSem(2, "Semaphores.Release: invalid semaphore");
    RETURN;
  END;
  INC(s^.count);
END Release;

PROCEDURE CondClaim(s: SEMAPHORE): BOOLEAN;
BEGIN
  IF (s = NIL) OR (s^.magic # semMagic) THEN
    raiseSem(2, "Semaphores.CondClaim: invalid semaphore");
    RETURN FALSE;
  END;
  IF s^.count = 0 THEN RETURN FALSE END;
  DEC(s^.count);
  RETURN TRUE;
END CondClaim;

PROCEDURE IsSemaphoreException(): BOOLEAN;
BEGIN
  RETURN NM2RT.IsExceptionalExecution() &
         NM2RT.IsCurrentExceptionSource(semExceptionSource);
END IsSemaphoreException;

BEGIN
  semExceptionSource := NM2RT.AllocateExceptionSource();
END Semaphores.
