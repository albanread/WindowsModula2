MODULE t61030;
(* Conformance: ComplexMath arg/polarToComplex/scalarMult/power. *)
IMPORT STextIO, ComplexMath;
VAR c : COMPLEX; ok : BOOLEAN;
PROCEDURE Near(a, b : REAL) : BOOLEAN;
VAR dd : REAL; BEGIN dd := a-b; IF dd<0.0 THEN dd:=-dd END; RETURN dd<0.001 END Near;
BEGIN
  ok := Near(ComplexMath.arg(CMPLX(0.0,1.0)), 1.5708) AND Near(ComplexMath.abs(CMPLX(3.0,4.0)), 5.0);
  c := ComplexMath.polarToComplex(2.0, 0.0); ok := ok AND Near(RE(c),2.0) AND Near(IM(c),0.0);
  c := ComplexMath.scalarMult(2.0, CMPLX(3.0,4.0)); ok := ok AND Near(RE(c),6.0) AND Near(IM(c),8.0);
  c := ComplexMath.power(CMPLX(0.0,1.0), 2.0); ok := ok AND Near(RE(c),-1.0) AND Near(IM(c),0.0);
  IF ok THEN STextIO.WriteString("PASS") ELSE STextIO.WriteString("FAIL") END; STextIO.WriteLn
END t61030.
