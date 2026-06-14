MODULE T70030Retry;
(*
 * Group 70 — Exceptions
 * Test: RETRY re-runs the protected region; a module-level counter persists
 *       across attempts until the raise condition clears.
 *
 * EXPECTED:
 * 1
 * 2
 * 3
 * ok
 *)
IMPORT STextIO, SWholeIO, NM2RT;
VAR src: NM2RT.ExceptionSource; attempts: CARDINAL;
BEGIN
  src := NM2RT.AllocateExceptionSource();
  INC(attempts);
  SWholeIO.WriteCard(attempts, 0);
  STextIO.WriteLn;
  IF attempts < 3 THEN
    NM2RT.Raise(src, 1, "again");
  END;
  STextIO.WriteString("ok");
  STextIO.WriteLn;
EXCEPT
  RETRY;
END T70030Retry.
