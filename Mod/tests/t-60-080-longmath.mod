MODULE T60080LongMath;
(*
 * Group 60 — ISO library
 * Test: LongMath (LONGREAL) over the NM2Math runtime.
 *
 * EXPECTED:
 * 9
 * 81
 *)
IMPORT STextIO, SWholeIO, LongMath;
BEGIN
  SWholeIO.WriteCard(TRUNC(LongMath.sqrt(81.0) + 0.5), 0); STextIO.WriteLn;
  SWholeIO.WriteCard(TRUNC(LongMath.power(3.0, 4.0) + 0.5), 0); STextIO.WriteLn;
END T60080LongMath.
