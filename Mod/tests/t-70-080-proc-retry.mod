MODULE T70080ProcRetry;
(*
 * Group 70 — Exceptions
 * Test: RETRY inside a procedure handler re-runs the protected region (re-using
 *       the exception frame, which is freed only on final exit). A VAR
 *       out-parameter persists the attempt counter across retries.
 *
 * EXPECTED:
 * 3
 *)
IMPORT STextIO, SWholeIO, NM2RT;
VAR src: NM2RT.ExceptionSource;
    c: CARDINAL;

PROCEDURE Attempt(VAR counter: CARDINAL): CARDINAL;
BEGIN
  INC(counter);
  IF counter < 3 THEN
    NM2RT.Raise(src, 1, "retry");
  END;
  RETURN counter;
EXCEPT
  RETRY;
END Attempt;

BEGIN
  src := NM2RT.AllocateExceptionSource();
  c := 0;
  SWholeIO.WriteCard(Attempt(c), 0);
  STextIO.WriteLn;
END T70080ProcRetry.
