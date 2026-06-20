MODULE HeapGuardTest;
(* Exercises the --protect-heap runtime guard:
   - an aliased double-free (b still points at a block a already DISPOSEd)
   - a leak (never DISPOSEd).
   Run plain: no guard output. Run with --protect-heap (or NM2_PROTECT_HEAP=1):
   the double free is caught + skipped, and the leak is reported at exit. *)
FROM STextIO IMPORT WriteString, WriteLn;

TYPE P = POINTER TO INTEGER;
VAR a, b, leak: P;

BEGIN
  NEW(a); a^ := 42;
  b := a;               (* alias the same block *)
  DISPOSE(a);           (* free once (a := NIL; b still dangles at the old block) *)
  DISPOSE(b);           (* DOUBLE FREE of the same address -> guard catches + skips *)

  NEW(leak); leak^ := 99;   (* never disposed -> a leak at exit *)

  WriteString("program finished"); WriteLn
END HeapGuardTest.
