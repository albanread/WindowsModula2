IMPLEMENTATION MODULE Builtins;

IMPORT RealMath, LongMath;

(* --- REAL --- *)

PROCEDURE sqrt (x: REAL): REAL;
BEGIN RETURN RealMath.sqrt(x) END sqrt;

PROCEDURE exp (x: REAL): REAL;
BEGIN RETURN RealMath.exp(x) END exp;

PROCEDURE log (x: REAL): REAL;
BEGIN RETURN RealMath.ln(x) END log;

PROCEDURE log10 (x: REAL): REAL;
BEGIN RETURN RealMath.ln(x) / RealMath.ln(10.0) END log10;

PROCEDURE sin (x: REAL): REAL;
BEGIN RETURN RealMath.sin(x) END sin;

PROCEDURE cos (x: REAL): REAL;
BEGIN RETURN RealMath.cos(x) END cos;

PROCEDURE tan (x: REAL): REAL;
BEGIN RETURN RealMath.tan(x) END tan;

PROCEDURE fabs (x: REAL): REAL;
BEGIN RETURN ABS(x) END fabs;

PROCEDURE pow (base, exponent: REAL): REAL;
BEGIN RETURN RealMath.power(base, exponent) END pow;

(* --- LONGREAL (C `l` suffix) --- *)

PROCEDURE sqrtl (x: LONGREAL): LONGREAL;
BEGIN RETURN LongMath.sqrt(x) END sqrtl;

PROCEDURE expl (x: LONGREAL): LONGREAL;
BEGIN RETURN LongMath.exp(x) END expl;

PROCEDURE logl (x: LONGREAL): LONGREAL;
BEGIN RETURN LongMath.ln(x) END logl;

PROCEDURE log10l (x: LONGREAL): LONGREAL;
BEGIN RETURN LongMath.ln(x) / LongMath.ln(10.0) END log10l;

PROCEDURE sinl (x: LONGREAL): LONGREAL;
BEGIN RETURN LongMath.sin(x) END sinl;

PROCEDURE cosl (x: LONGREAL): LONGREAL;
BEGIN RETURN LongMath.cos(x) END cosl;

PROCEDURE tanl (x: LONGREAL): LONGREAL;
BEGIN RETURN LongMath.tan(x) END tanl;

PROCEDURE fabsl (x: LONGREAL): LONGREAL;
BEGIN RETURN ABS(x) END fabsl;

PROCEDURE powl (base, exponent: LONGREAL): LONGREAL;
BEGIN RETURN LongMath.power(base, exponent) END powl;

END Builtins.
