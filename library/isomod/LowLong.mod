(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-15 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes mirror those in LowReal.mod — same NM2LowMath
   shims, same replacement of bit-pattern aliasing with arithmetic
   equivalents. Operates natively on LONGREAL (no widening needed).
*)
IMPLEMENTATION MODULE LowLong;

IMPORT EXCEPTIONS, NM2LowMath;

VAR source: EXCEPTIONS.ExceptionSource;
    currentModes: Modes;

PROCEDURE raise;
BEGIN
  EXCEPTIONS.RAISE(source, 0, "LowLong.lowException");
END raise;

PROCEDURE exponent(x: LONGREAL): INTEGER;
  VAR e: INTEGER;
      z: LONGREAL;
BEGIN
  z := NM2LowMath.Frexp(x, e);
  RETURN e;
END exponent;

PROCEDURE fraction(x: LONGREAL): LONGREAL;
  VAR e: INTEGER;
BEGIN
  RETURN NM2LowMath.Frexp(x, e);
END fraction;

PROCEDURE sign(x: LONGREAL): LONGREAL;
BEGIN
  IF    x < 0.0 THEN RETURN -1.0
  ELSIF x = 0.0 THEN RETURN  0.0
  ELSE               RETURN  1.0
  END;
END sign;

PROCEDURE ulp(x: LONGREAL): LONGREAL;
  (* For an f64 with x normal, ulp = 2^(exponent(x) - 53). Subnormals
     return the smallest positive subnormal. *)
  VAR e: INTEGER;
      m: LONGREAL;
BEGIN
  IF x = 0.0 THEN
    RETURN NM2LowMath.Ldexp(1.0, -1074);
  END;
  m := NM2LowMath.Frexp(x, e);
  RETURN NM2LowMath.Ldexp(1.0, e - 53);
END ulp;

PROCEDURE succ(x: LONGREAL): LONGREAL;
BEGIN
  RETURN x + ulp(x);
END succ;

PROCEDURE pred(x: LONGREAL): LONGREAL;
BEGIN
  RETURN x - ulp(x);
END pred;

PROCEDURE intpart(x: LONGREAL): LONGREAL;
  VAR y, _f: LONGREAL;
BEGIN
  _f := NM2LowMath.Modf(x, y);
  RETURN y;
END intpart;

PROCEDURE fractpart(x: LONGREAL): LONGREAL;
  VAR y: LONGREAL;
BEGIN
  RETURN NM2LowMath.Modf(x, y);
END fractpart;

PROCEDURE scale(x: LONGREAL; n: INTEGER): LONGREAL;
BEGIN
  RETURN NM2LowMath.Ldexp(x, n);
END scale;

PROCEDURE trunc(x: LONGREAL; n: INTEGER): LONGREAL;
  VAR scaled, intp, _f: LONGREAL;
BEGIN
  IF n <= 0 THEN raise END;
  IF n >= 52 THEN RETURN x END;
  scaled := NM2LowMath.Ldexp(x, n);
  _f := NM2LowMath.Modf(scaled, intp);
  RETURN NM2LowMath.Ldexp(intp, -n);
END trunc;

PROCEDURE round(x: LONGREAL; n: INTEGER): LONGREAL;
BEGIN
  RETURN trunc(x, n);
END round;

PROCEDURE synthesize(expart: INTEGER; frapart: LONGREAL): LONGREAL;
BEGIN
  RETURN NM2LowMath.Ldexp(frapart, expart);
END synthesize;

PROCEDURE setMode(m: Modes);
BEGIN
  currentModes := m;
END setMode;

PROCEDURE currentMode(): Modes;
BEGIN
  RETURN currentModes;
END currentMode;

PROCEDURE IsLowException(): BOOLEAN;
BEGIN
  RETURN EXCEPTIONS.IsCurrentSource(source);
END IsLowException;

BEGIN
  EXCEPTIONS.AllocateSource(source);
  currentModes := Modes{};
END LowLong.
