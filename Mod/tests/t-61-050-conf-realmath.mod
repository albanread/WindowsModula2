MODULE t61050;
(* Conformance: RealMath.round rounds to nearest + trig identities. *)
IMPORT STextIO, RealMath;
VAR ok : BOOLEAN;
PROCEDURE Near(a, b : REAL) : BOOLEAN;
VAR d : REAL; BEGIN d := a-b; IF d<0.0 THEN d:=-d END; RETURN d<0.001 END Near;
BEGIN
  ok := (RealMath.round(2.6) = 3) AND (RealMath.round(2.4) = 2)
    AND (RealMath.round(2.5) = 3) AND (RealMath.round(-2.5) = -3)
    AND Near(RealMath.sin(RealMath.pi/2.0), 1.0)
    AND Near(RealMath.arctan(1.0)*4.0, RealMath.pi);
  IF ok THEN STextIO.WriteString("PASS") ELSE STextIO.WriteString("FAIL") END; STextIO.WriteLn
END t61050.
