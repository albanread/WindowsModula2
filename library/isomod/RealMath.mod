(* Copyright (c) xTech 1993, 94. All Rights Reserved. *)
(* Ported to NewM2 2026-05-13 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - Replaced `IMPORT math := xMath` with `IMPORT math := NM2Math`
       (library/rtdef/NM2Math.def). NM2Math is the NewM2 internal math
       surface; the front end is expected to lower its procedure calls
       to LLVM floating-point intrinsics (llvm.sin.f64, etc.).
     - Renamed `math.X2C_sqrt(x)` etc. to `math.sqrt(x)` — the XDS
       `X2C_` prefix is a C-binding convention with no analogue here.
     - Flattened `<* IF EXCEPTIONS *> ... %ELSE XRaise %END *>` chains
       to the EXCEPTIONS branch. XRaise removed entirely.
     - Dropped `<*+ M2EXTENSIONS *>` and the `s-` constant-parameter
       modifier.
     - `round` uses `LONGREAL` arithmetic via `LFLOAT` for the bounds
       check (so MAX(INTEGER) on 64-bit fits exactly). The XDS source
       used `X2C_floorl` (long-double floor); we use `math.Lfloor`.
*)
IMPLEMENTATION MODULE RealMath;

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
  Strings.Concat("RealMath.", s, m);
  EXCEPTIONS.RAISE(source, n, m);
END raise;

PROCEDURE sqrt(x: REAL): REAL;
BEGIN
  IF x < 0. THEN raise(0, "sqrt: negative argument") END;
  RETURN math.sqrt(x);
END sqrt;

PROCEDURE exp(x: REAL): REAL;
BEGIN
  RETURN math.exp(x);
END exp;

PROCEDURE ln(x: REAL): REAL;
BEGIN
  IF x <= 0. THEN raise(1, "ln: negative or zero argument") END;
  RETURN math.ln(x);
END ln;

PROCEDURE sin(x: REAL): REAL;
BEGIN
  RETURN math.sin(x);
END sin;

PROCEDURE cos(x: REAL): REAL;
BEGIN
  RETURN math.cos(x);
END cos;

PROCEDURE tan(x: REAL): REAL;
BEGIN
  RETURN math.tan(x);
END tan;

PROCEDURE arcsin(x: REAL): REAL;
BEGIN
  IF ABS(x) > 1. THEN raise(2, "arcsin: argument is not in range -1.0 .. 1.0") END;
  RETURN math.arcsin(x)
END arcsin;

PROCEDURE arccos(x: REAL): REAL;
BEGIN
  IF ABS(x) > 1. THEN raise(3, "arccos: argument is not in range -1.0 .. 1.0") END;
  RETURN math.arccos(x)
END arccos;

PROCEDURE arctan(x: REAL): REAL;
BEGIN
  RETURN math.arctan(x);
END arctan;

PROCEDURE power(base, exponent: REAL): REAL;
BEGIN
  IF base <= 0. THEN raise(4, "power: negative or zero base") END;
  RETURN math.pow(base, exponent)
END power;

PROCEDURE round(x: REAL): INTEGER;
  (* Nearest integer, halves away from zero (ISO RealMath.round). *)
  VAR y: LONGREAL;
BEGIN
  y := LFLOAT(x);
  IF y >= 0.0 THEN
    y := math.Lfloor(y + 0.5)
  ELSE
    y := -math.Lfloor((-y) + 0.5)
  END;
  IF (y < LFLOAT(MIN(INTEGER))) OR (y > LFLOAT(MAX(INTEGER))) THEN
    raise(5, "round: integer overflow")
  END;
  RETURN INT(y)
END round;

PROCEDURE IsRMathException(): BOOLEAN;
BEGIN
  RETURN EXCEPTIONS.IsCurrentSource(source)
END IsRMathException;

BEGIN
  EXCEPTIONS.AllocateSource(source);
END RealMath.
