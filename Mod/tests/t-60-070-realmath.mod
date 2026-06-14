MODULE T60070RealMath;
(*
 * Group 60 — ISO library
 * Test: RealMath transcendental/power functions over the NM2Math runtime.
 *
 * EXPECTED:
 * 4
 * 1024
 * 1
 * 0
 *)
IMPORT STextIO, SWholeIO, RealMath;
BEGIN
  SWholeIO.WriteCard(TRUNC(RealMath.sqrt(16.0)), 0); STextIO.WriteLn;
  SWholeIO.WriteCard(TRUNC(RealMath.power(2.0, 10.0) + 0.5), 0); STextIO.WriteLn;
  SWholeIO.WriteCard(TRUNC(RealMath.exp(0.0) + 0.5), 0); STextIO.WriteLn;
  SWholeIO.WriteCard(TRUNC(RealMath.ln(1.0) + 0.5), 0); STextIO.WriteLn;
END T60070RealMath.
