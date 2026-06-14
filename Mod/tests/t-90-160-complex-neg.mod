MODULE T90160ComplexNeg;
(*
 * Group 90 — arithmetic / codegen
 * Test: unary negation of a COMPLEX value negates both components,
 *       -(a+bi) = (-a) + (-b)i.
 *
 * EXPECTED:
 * ok
 *)
FROM StrIO IMPORT WriteString, WriteLn;

CONST
  one = CMPLX(1.0, 0.0);

VAR
  z, w: COMPLEX;
BEGIN
  z := CMPLX(2.0, -3.0);
  w := -z;                       (* (-2, 3) *)
  IF (RE(w) = -2.0) AND (IM(w) = 3.0) AND (-one = CMPLX(-1.0, 0.0)) THEN
    WriteString("ok")
  ELSE
    WriteString("bad")
  END;
  WriteLn
END T90160ComplexNeg.
