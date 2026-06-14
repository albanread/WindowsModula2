MODULE T30030ImportScalars;
(*
 * Group 30 — Module imports / scalar round-trips
 * Test: imported constants and scalar procedure params/results work for
 * INTEGER, CARDINAL, CHAR, and BOOLEAN.
 *
 * EXPECTED:
 * 15
 * 16
 * A
 * 0
 * 1
 *)
IMPORT STextIO, SWholeIO;
FROM T30030ScalarHelper IMPORT BaseInt, BaseCard, BumpInt, BumpCard, NextChar, Flip;

BEGIN
  SWholeIO.WriteInt(BumpInt(BaseInt), 0);
  STextIO.WriteLn;

  SWholeIO.WriteCard(BumpCard(BaseCard), 0);
  STextIO.WriteLn;

  STextIO.WriteChar(NextChar('A'));
  STextIO.WriteLn;

  IF Flip(TRUE) THEN
    SWholeIO.WriteInt(1, 0)
  ELSE
    SWholeIO.WriteInt(0, 0)
  END;
  STextIO.WriteLn;

  IF Flip(FALSE) THEN
    SWholeIO.WriteInt(1, 0)
  ELSE
    SWholeIO.WriteInt(0, 0)
  END;
  STextIO.WriteLn;
END T30030ImportScalars.