(* Copyright (c) xTech 1993, 94. All Rights Reserved. *)
(* Ported to NewM2 2026-05-13 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes (see RealMath.mod for the canonical rationale):
     - IMPORT math := xMath  →  IMPORT math := NM2Math
     - math.X2C_sqrtl, _expl, _lnl, _sinl, _cosl, _tanl, _arcsinl,
       _arccosl, _arctanl, _powl, _floorl  →  math.Lsqrt, .Lexp, .Lln,
       .Lsin, .Lcos, .Ltan, .Larcsin, .Larccos, .Larctan, .Lpow, .Lfloor.
       The `L`-prefix is the NM2Math convention for the LONGREAL surface.
     - Flatten `<* IF EXCEPTIONS *> ... %ELSE XRaise %END *>` to the
       EXCEPTIONS branch. XRaise removed entirely.
     - Dropped `<*+ M2EXTENSIONS *>` and the `s-` constant-parameter
       modifier.
     - Note: the XDS source carried `XRaise.RealMath` as the
       exception-source enum for the XRaise branch — that was a bug
       upstream (LongMath using the RealMath source). In the flattened
       EXCEPTIONS path each module allocates its own source, so the bug
       does not survive the port.
*)
IMPLEMENTATION MODULE LongMath;

(* Modifications:
   22-Mar-94 Ned: merging implementations (XDS upstream)
   2026-05-13: substitute xMath → NM2Math; flatten pragmas (NewM2 port).
*)

IMPORT Strings;
IMPORT math := NM2Math;
IMPORT EXCEPTIONS;

VAR source: EXCEPTIONS.ExceptionSource;

PROCEDURE raise(n: CARDINAL; s: ARRAY OF CHAR);
  VAR m: ARRAY [0..79] OF CHAR;
BEGIN
  Strings.Concat("LongMath.", s, m);
  EXCEPTIONS.RAISE(source, n, m);
END raise;

PROCEDURE sqrt(x: LONGREAL): LONGREAL;
BEGIN
  IF x < 0. THEN raise(0, "sqrt: negative argument") END;
  RETURN math.Lsqrt(x);
END sqrt;

PROCEDURE exp(x: LONGREAL): LONGREAL;
BEGIN
  RETURN math.Lexp(x)
END exp;

PROCEDURE ln(x: LONGREAL): LONGREAL;
BEGIN
  IF x <= 0. THEN raise(1, "ln: negative or zero argument") END;
  RETURN math.Lln(x)
END ln;

PROCEDURE sin(x: LONGREAL): LONGREAL;
BEGIN
  RETURN math.Lsin(x)
END sin;

PROCEDURE cos(x: LONGREAL): LONGREAL;
BEGIN
  RETURN math.Lcos(x)
END cos;

PROCEDURE tan(x: LONGREAL): LONGREAL;
BEGIN
  RETURN math.Ltan(x)
END tan;

PROCEDURE arcsin(x: LONGREAL): LONGREAL;
BEGIN
  IF ABS(x) > 1. THEN raise(2, "arcsin: argument is not in range -1.0 .. 1.0") END;
  RETURN math.Larcsin(x)
END arcsin;

PROCEDURE arccos(x: LONGREAL): LONGREAL;
BEGIN
  IF ABS(x) > 1. THEN raise(3, "arccos: argument is not in range -1.0 .. 1.0") END;
  RETURN math.Larccos(x)
END arccos;

PROCEDURE arctan(x: LONGREAL): LONGREAL;
BEGIN
  RETURN math.Larctan(x)
END arctan;

PROCEDURE power(base, exponent: LONGREAL): LONGREAL;
BEGIN
  IF base <= 0. THEN raise(4, "power: negative or zero base") END;
  RETURN math.Lpow(base, exponent)
END power;

PROCEDURE round(x: LONGREAL): INTEGER;
  (* Nearest integer, halves away from zero (ISO LongMath.round). *)
BEGIN
  IF x >= 0.0 THEN
    x := math.Lfloor(x + 0.5)
  ELSE
    x := -math.Lfloor((-x) + 0.5)
  END;
  IF (x < LFLOAT(MIN(INTEGER))) OR (x > LFLOAT(MAX(INTEGER))) THEN
    raise(5, "round: integer overflow")
  END;
  RETURN INT(x)
END round;

PROCEDURE IsRMathException(): BOOLEAN;
BEGIN
  RETURN EXCEPTIONS.IsCurrentSource(source)
END IsRMathException;

BEGIN
  EXCEPTIONS.AllocateSource(source);
END LongMath.
