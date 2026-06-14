MODULE T50070FloatLibrary;
(*
 * Group 50 — Library overrides / Float helper module
 * Test: the library Float implementation resolves through the harness search
 * path and its set-typed APIs compile and run in both memory modes.
 *
 * EXPECTED:
 * 2
 * 1
 * 0
 *)
IMPORT Float, STextIO, SWholeIO;

VAR
  flags: Float.FPExceptions;

BEGIN
  Float.Init;
  Float.ClearFPExceptions;

  SWholeIO.WriteInt(Float.NearestToInt32(1.75), 0);
  STextIO.WriteLn;

  flags := Float.GetFPExceptions() + Float.FPException{Float.exOverflow};
  IF Float.exOverflow IN flags THEN
    SWholeIO.WriteInt(1, 0)
  ELSE
    SWholeIO.WriteInt(0, 0)
  END;
  STextIO.WriteLn;

  Float.CheckFPException(flags);
  flags := Float.RaisedFPExceptions();
  IF Float.exOverflow IN flags THEN
    SWholeIO.WriteInt(1, 0)
  ELSE
    SWholeIO.WriteInt(0, 0)
  END;
  STextIO.WriteLn;
END T50070FloatLibrary.