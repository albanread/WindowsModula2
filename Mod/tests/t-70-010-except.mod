MODULE T70010Except;
(*
 * Group 70 — Exceptions
 * Test: a module-body EXCEPT handler catches a raised exception, dispatches
 *       on the exception SOURCE (shared with the protected region), and reads
 *       the current exception number.
 *
 * EXPECTED:
 * guarded
 * mysrc n=42
 *)
IMPORT STextIO, SWholeIO, NM2RT;
VAR src: NM2RT.ExceptionSource;
BEGIN
  src := NM2RT.AllocateExceptionSource();
  STextIO.WriteString("guarded");
  STextIO.WriteLn;
  NM2RT.Raise(src, 42, "boom");
  STextIO.WriteString("unreached");
  STextIO.WriteLn;
EXCEPT
  IF NM2RT.IsCurrentExceptionSource(src) THEN
    STextIO.WriteString("mysrc n=");
    SWholeIO.WriteCard(NM2RT.CurrentExceptionNumber(), 0);
  ELSE
    STextIO.WriteString("other");
  END;
  STextIO.WriteLn;
END T70010Except.
