MODULE T70060IsoExceptions;
(*
 * Group 70 — Exceptions
 * Test: the ISO EXCEPTIONS module surface (AllocateSource / RAISE /
 *       IsCurrentSource / CurrentNumber) over the NM2RT runtime.
 *
 * EXPECTED:
 * try
 * caught 5
 *)
IMPORT STextIO, SWholeIO, EXCEPTIONS;
VAR src: EXCEPTIONS.ExceptionSource;
BEGIN
  EXCEPTIONS.AllocateSource(src);
  STextIO.WriteString("try");
  STextIO.WriteLn;
  EXCEPTIONS.RAISE(src, 5, "boom");
  STextIO.WriteString("unreached");
  STextIO.WriteLn;
EXCEPT
  IF EXCEPTIONS.IsCurrentSource(src) THEN
    STextIO.WriteString("caught ");
    SWholeIO.WriteCard(EXCEPTIONS.CurrentNumber(src), 0);
    STextIO.WriteLn;
  END;
END T70060IsoExceptions.
