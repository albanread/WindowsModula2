MODULE MathLib;
(*
 * Exercises the extended NM2Math surface (the raw math primitive layer).
 * Each result is printed as truncToInt(value * 1000) so exact integer
 * checks are easy. Build/run:  newm2 run demos/mathlib.mod
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
FROM NM2Math IMPORT
  ceil, round, trunc, floor, log10, log, exp2, cbrt, expm1, log1p,
  hypot, fmod, copysign, sign, min, max, degrees, radians, truncToInt,
  pi, tau, e, sqrt2;

PROCEDURE Show (label: ARRAY OF CHAR; v: REAL);
BEGIN
  WriteString(label); WriteString(" *1000 = "); WriteInt(truncToInt(v * 1000.0), 1); WriteLn
END Show;

BEGIN
  Show("ceil(2.3)      ", ceil(2.3));            (*  3000 *)
  Show("floor(2.7)     ", floor(2.7));           (*  2000 *)
  Show("round(2.5)     ", round(2.5));           (*  3000 *)
  Show("trunc(-2.7)    ", trunc(-2.7));          (* -2000 *)
  Show("log10(1000)    ", log10(1000.0));        (*  3000 *)
  Show("log(8,2)       ", log(8.0, 2.0));        (*  3000 *)
  Show("exp2(10)       ", exp2(10.0));           (* 1024000 *)
  Show("cbrt(27)       ", cbrt(27.0));           (*  3000 *)
  Show("expm1(0)       ", expm1(0.0));           (*     0 *)
  Show("log1p(0)       ", log1p(0.0));           (*     0 *)
  Show("hypot(3,4)     ", hypot(3.0, 4.0));      (*  5000 *)
  Show("fmod(10,3)     ", fmod(10.0, 3.0));      (*  1000 *)
  Show("copysign(3,-1) ", copysign(3.0, -1.0)); (* -3000 *)
  Show("sign(-5)       ", sign(-5.0));           (* -1000 *)
  Show("sign(0)        ", sign(0.0));            (*     0 *)
  Show("min(3,7)       ", min(3.0, 7.0));        (*  3000 *)
  Show("max(3,7)       ", max(3.0, 7.0));        (*  7000 *)
  Show("degrees(pi)    ", degrees(pi));          (* 180000 *)
  Show("radians(180)   ", radians(180.0));       (*  3141 *)
  Show("pi             ", pi);                   (*  3141 *)
  Show("tau            ", tau);                  (*  6283 *)
  Show("e              ", e);                    (*  2718 *)
  Show("sqrt2          ", sqrt2)                 (*  1414 *)
END MathLib.
