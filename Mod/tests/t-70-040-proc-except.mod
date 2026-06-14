MODULE T70040ProcExcept;
(*
 * Group 70 — Exceptions
 * Test: a FUNCTION procedure with EXCEPT. The protected body uses a param and
 *       a local and RETURNs a value (through the shared result slot); the
 *       handler RETURNs on a raised exception.
 *
 * EXPECTED:
 * 10
 * 0
 *)
IMPORT STextIO, SWholeIO, NM2RT;
VAR src: NM2RT.ExceptionSource;

PROCEDURE Risky(n: CARDINAL): CARDINAL;
VAR local: CARDINAL;
BEGIN
  local := n * 2;
  IF n = 0 THEN
    NM2RT.Raise(src, 99, "zero");
  END;
  RETURN local;
EXCEPT
  RETURN 0;
END Risky;

BEGIN
  src := NM2RT.AllocateExceptionSource();
  SWholeIO.WriteCard(Risky(5), 0);
  STextIO.WriteLn;
  SWholeIO.WriteCard(Risky(0), 0);
  STextIO.WriteLn;
END T70040ProcExcept.
