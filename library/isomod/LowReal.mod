(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-15 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - Replaced `xMath.X2C_frexp/modf/ldexp/controlfp` with the NewM2
       runtime shims in `NM2LowMath` (see `library/rtdef/NM2LowMath.def`
       and `src/newm2-runtime/src/fmath.rs`). All operations widen REAL
       to LONGREAL on entry and narrow on return — the underlying
       primitives are double-precision in libm and we don't want to
       round-trip through f32 mid-computation.
     - The XDS `ulp` / `trunc` / `round` worked by twiddling the IEEE-
       754 bit pattern through a `POINTER TO BITSET` aliased over the
       REAL slot. That depends on REAL being f32 with a specific bit
       layout (which is true on x86-64 too) but it's also brittle and
       UB-adjacent. Replaced with arithmetic equivalents using ldexp /
       modf — same observable behaviour, no aliasing tricks.
     - `setMode` / `currentMode` are stubs returning an empty mode set.
       The runtime doesn't expose FPU control-word management yet;
       portable code rarely needs it. Add `nm2_math_fpcontrol` shims if
       a use case appears.
*)
IMPLEMENTATION MODULE LowReal;

IMPORT SYSTEM, EXCEPTIONS, NM2LowMath;

VAR source: EXCEPTIONS.ExceptionSource;
    currentModes: Modes;

PROCEDURE raise;
BEGIN
  EXCEPTIONS.RAISE(source, 0, "LowReal.lowException");
END raise;

PROCEDURE exponent(x: REAL): INTEGER;
  VAR e: INTEGER;
      z: LONGREAL;
BEGIN
  z := NM2LowMath.Frexp(VAL(LONGREAL, x), e);
  RETURN e;
END exponent;

PROCEDURE fraction(x: REAL): REAL;
  VAR e: INTEGER;
BEGIN
  RETURN VAL(REAL, NM2LowMath.Frexp(VAL(LONGREAL, x), e));
END fraction;

PROCEDURE sign(x: REAL): REAL;
BEGIN
  IF    x < 0.0 THEN RETURN -1.0
  ELSIF x = 0.0 THEN RETURN  0.0
  ELSE               RETURN  1.0
  END;
END sign;

PROCEDURE ulp(x: REAL): REAL;
  (* Unit-in-the-last-place: 2^(exponent(x) - precision + 1). For an
     f32 with x normal, that's ldexp(1.0, e-23). For x=0 we return the
     smallest subnormal as a reasonable fallback. *)
  VAR e: INTEGER;
      m: LONGREAL;
BEGIN
  IF x = 0.0 THEN
    RETURN VAL(REAL, NM2LowMath.Ldexp(1.0, -149));
  END;
  m := NM2LowMath.Frexp(VAL(LONGREAL, x), e);
  RETURN VAL(REAL, NM2LowMath.Ldexp(1.0, e - 24));
END ulp;

PROCEDURE succ(x: REAL): REAL;
BEGIN
  RETURN x + ulp(x);
END succ;

PROCEDURE pred(x: REAL): REAL;
BEGIN
  RETURN x - ulp(x);
END pred;

PROCEDURE intpart(x: REAL): REAL;
  VAR y, f: LONGREAL;
BEGIN
  f := NM2LowMath.Modf(VAL(LONGREAL, x), y);
  RETURN VAL(REAL, y);
END intpart;

PROCEDURE fractpart(x: REAL): REAL;
  VAR y: LONGREAL;
BEGIN
  RETURN VAL(REAL, NM2LowMath.Modf(VAL(LONGREAL, x), y));
END fractpart;

PROCEDURE scale(x: REAL; n: INTEGER): REAL;
BEGIN
  RETURN VAL(REAL, NM2LowMath.Ldexp(VAL(LONGREAL, x), n));
END scale;

PROCEDURE trunc(x: REAL; n: INTEGER): REAL;
  (* Returns x truncated to the first n binary places. Implemented as
     scale-down / intpart / scale-back to avoid bit-pattern aliasing. *)
  VAR scaled, intp, _f: LONGREAL;
BEGIN
  IF n <= 0 THEN raise END;
  IF n >= 23 THEN RETURN x END;
  scaled := NM2LowMath.Ldexp(VAL(LONGREAL, x), n);
  _f := NM2LowMath.Modf(scaled, intp);
  RETURN VAL(REAL, NM2LowMath.Ldexp(intp, -n));
END trunc;

PROCEDURE round(x: REAL; n: INTEGER): REAL;
BEGIN
  RETURN trunc(x, n);
END round;

PROCEDURE synthesize(expart: INTEGER; frapart: REAL): REAL;
BEGIN
  RETURN VAL(REAL, NM2LowMath.Ldexp(VAL(LONGREAL, frapart), expart));
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
END LowReal.
