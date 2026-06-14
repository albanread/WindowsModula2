MODULE T60210Complex;
(* Group 60 — ISO ComplexMath: COMPLEX type, RE/IM/CMPLX, abs/conj/sqrt,
   complex equality vs the exported CMPLX-CONST `zero`. *)
IMPORT STextIO, RealStr, ComplexMath;
VAR s: ARRAY [0..63] OF CHAR; c: COMPLEX;
PROCEDURE pr(x: REAL);
BEGIN RealStr.RealToFixed(x, 2, s); STextIO.WriteString(s); STextIO.WriteLn; END pr;
BEGIN
  pr(ComplexMath.abs(CMPLX(3.0, 4.0)));
  c := ComplexMath.conj(CMPLX(3.0, 4.0));
  pr(RE(c)); pr(IM(c));
  c := ComplexMath.sqrt(CMPLX(4.0, 0.0));
  pr(RE(c)); pr(IM(c));
  IF CMPLX(0.0, 0.0) = ComplexMath.zero THEN STextIO.WriteString("zero-ok")
  ELSE STextIO.WriteString("zero-bad") END;
  STextIO.WriteLn;
END T60210Complex.
