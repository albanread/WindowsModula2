MODULE T60220LongComplex;
(* Group 60 — ISO LongComplexMath: LONGCOMPLEX type + abs/scalarMult. *)
IMPORT STextIO, LongStr, LongComplexMath;
VAR s: ARRAY [0..63] OF CHAR; c: LONGCOMPLEX;
PROCEDURE pr(x: LONGREAL);
BEGIN LongStr.RealToFixed(x, 2, s); STextIO.WriteString(s); STextIO.WriteLn; END pr;
BEGIN
  pr(LongComplexMath.abs(CMPLX(5.0, 12.0)));
  c := LongComplexMath.scalarMult(3.0, CMPLX(1.0, 2.0));
  pr(RE(c)); pr(IM(c));
END T60220LongComplex.
