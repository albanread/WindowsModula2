IMPLEMENTATION MODULE MathLib0;

IMPORT RealMath;

PROCEDURE sqrt (x: REAL): REAL;
BEGIN RETURN RealMath.sqrt(x) END sqrt;

PROCEDURE exp (x: REAL): REAL;
BEGIN RETURN RealMath.exp(x) END exp;

PROCEDURE ln (x: REAL): REAL;
BEGIN RETURN RealMath.ln(x) END ln;

PROCEDURE sin (x: REAL): REAL;
BEGIN RETURN RealMath.sin(x) END sin;

PROCEDURE cos (x: REAL): REAL;
BEGIN RETURN RealMath.cos(x) END cos;

PROCEDURE tan (x: REAL): REAL;
BEGIN RETURN RealMath.tan(x) END tan;

PROCEDURE arctan (x: REAL): REAL;
BEGIN RETURN RealMath.arctan(x) END arctan;

(* entier(x) is the floor of x as an INTEGER. TRUNC rounds toward zero, so for
   a negative non-integer the result is one too high — adjust down. *)
PROCEDURE entier (x: REAL): INTEGER;
VAR
  t: INTEGER;
BEGIN
  t := TRUNC(x);
  IF FLOAT(t) > x THEN
    DEC(t)
  END;
  RETURN t
END entier;

END MathLib0.
