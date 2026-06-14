(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-13 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - Dropped `<*+ M2EXTENSIONS *>` and the `<* IF NOT __GEN_C__ %THEN
       %- PROCINLINE %END *>` proc-inlining pragma.
     - Dropped `IMPORT SYSTEM` (unused in the body after the pragma flatten).
     - Replaced PIM-pervasive `COPY(NINF, s)` with `Strings.Assign(NINF, s)`
       — NewM2 does not define `COPY` as a pervasive. Semantics are
       identical for this open-array assignment.
     - `MAXPOW = 32` is preserved verbatim. Despite the name it is *not*
       a 32-bit-CARDINAL assumption — it bounds the `digits()` search
       loop. For IEEE-754 binary32 (REAL) the loop settles at 7; for
       binary64 (LONGREAL) at 17. The 32 is a defensive cap. Safe on
       64-bit.
     - The comment "MAX(float) < 10^(MAX(CARDINAL)/2)" in the upstream
       author's notes was a 32-bit-CARDINAL aside; the inequality is
       even more comfortably true on 64-bit. No code change needed.
     - PIM-style `IsRealSpecial` detects IEEE infinity via `R/2.0 = R`.
       NaN handling is upstream "not supported"; we preserve that. If
       NaN reaches RealToFloat/RealToFixed/RealToStr today the result
       is implementation-defined.
*)
IMPLEMENTATION MODULE RealStr; (* Andrew Cadach Aug 1993 *)

(* Modifications:
        14-Mar-94 Ned:   error in to_fixed (XDS upstream)
        22-Sep-93 Andy:  visualization of special 80387 values added (XDS upstream)
        08-Sep-93 Ned:   to_fixed, write (XDS upstream)
        28-Feb-95 Sem:   reimplemented (XDS upstream)
        2026-05-13:      pragma flatten; COPY → Strings.Assign (NewM2 port)
*)

IMPORT ConvTypes, CharClass, XReal, Strings;

CONST
  PINF  = "+inf.";
  NINF  = "-inf.";

PROCEDURE IsRealSpecial(R: REAL; VAR s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF (R # 0.0) & (R / 2.0 = R) THEN
    IF R < 0.0 THEN Strings.Assign(NINF, s) ELSE Strings.Assign(PINF, s) END;
    RETURN TRUE;
  END;
  RETURN FALSE;
END IsRealSpecial;

CONST
  EOS = 0C;
  MAXPOW = 32;

VAR
  max_digits: CARDINAL;
(* Find "digits". The store / add / div helpers below exist to inhibit
   constant folding in aggressive C compilers — we keep them for the
   port even though our front end won't fold across procedure calls. *)

PROCEDURE store (VAR r: float; v: float);
BEGIN
  r := v;
END store;

PROCEDURE add (a, b: float): float;
  VAR r: float;
BEGIN
  store(r, a + b); RETURN r;
END add;

PROCEDURE div (a, b: float): float;
  VAR r: float;
BEGIN
  store(r, a / b); RETURN r;
END div;

PROCEDURE digits(): CARDINAL;
  VAR u: float;
BEGIN
  IF max_digits = 0 THEN
    u := 0.1; max_digits := 1;
    LOOP
      IF (max_digits = 32) OR (add(1.0, u) = 1.0) THEN EXIT END;
      INC(max_digits);
      u := div(u, 10.0);
    END;
    DEC(max_digits);
  END;
  RETURN max_digits;
END digits;

PROCEDURE StrToReal (str: ARRAY OF CHAR; VAR real: float; VAR res: ConvResults);
  VAR
    s, i, e, n: CARDINAL;
    r, t, p: LONGREAL;
    c: CHAR;
    ovf, rovf, neg, rneg: BOOLEAN;
BEGIN
  (* spaces [-]  1[23] "." [456] ["E" ["-"] 1[23]] *)
  (* 0      0 1 1 2  2 2 3 3   3  3 4  4 5 5 6  6  *)
  (* finishing states are: 2, 3, 6 *)

  c := ' '; i := 0; e := 0;
  s := 0; r := 0.0; p := 1.0;
  neg := FALSE; rneg := FALSE; ovf := FALSE; rovf := FALSE;
  LOOP
    IF (c # EOS) & (i <= HIGH(str)) THEN c := str[i]; INC(i);
    ELSE c := EOS;
    END;
    IF CharClass.IsWhiteSpace(c) THEN c := ' ' END;
    CASE c OF
    |' ':
      IF s # 0 THEN EXIT END;
    |'+', '-':
      IF s = 0 THEN rneg := c = '-';
      ELSIF s = 4 THEN neg := c = '-';
      ELSE EXIT
      END;
      INC(s);
    |'.':
      IF s # 2 THEN EXIT END;
      INC(s);
    |'E':
      IF (s # 2) & (s # 3) THEN EXIT END;
      s := 4;
    |'0'..'9':
      n := ORD(c) - ORD('0');
      t := VAL(LONGREAL, n);
      CASE s OF
      |0..2:
        rovf := rovf OR (r >= (VAL(LONGREAL, MAX(REAL)) - t) / 10.0);
        IF NOT rovf THEN r := r * 10.0 + t; END;
        s := 2;
      |3:
        p := p / 10.0;
        IF NOT rovf THEN r := r + t * p; END;
      |4..6:
        ovf := ovf OR (e >= (MAX(CARDINAL) - n) DIV 10);
        IF NOT ovf THEN e := e * 10 + n; END;
        s := 6;
      ELSE EXIT
      END;
    ELSE EXIT
    END;
  END;

  IF (s = 2) OR (s = 3) OR (s = 6) THEN
    IF NOT ovf THEN t := XReal.power10(e, ovf) END;
    IF NOT ovf THEN
      IF neg THEN
        r := r / t;
      ELSE
        ovf := VAL(LONGREAL, MAX(REAL)) / t <= r;
        IF NOT ovf THEN r := r * t END;
      END;
    END;
    IF ovf THEN
      IF NOT rovf & neg THEN
        r := 0.0
      ELSE
        IF rneg THEN r := MIN(float)
        ELSE r := MAX(float)
        END;
      END;
      res := ConvTypes.strOutOfRange
    ELSE
      IF rneg THEN r := -r; END;
      res := ConvTypes.strAllRight;
    END;
    IF c = EOS THEN real := VAL(REAL, r); RETURN END;
  END;

  IF (c = EOS) & (s = 0) THEN res := ConvTypes.strEmpty; RETURN; END;
  res := ConvTypes.strWrongFormat;
END StrToReal;

PROCEDURE RealToFloat (real: float; sigFigs: CARDINAL; VAR str: ARRAY OF CHAR);
  VAR s: XReal.STR;
BEGIN
  IF IsRealSpecial(real, str) THEN RETURN END;
  XReal.to_float(real, sigFigs, 1, digits(), 'E', FALSE, TRUE, s);
  XReal.strcpy(s, str);
END RealToFloat;

PROCEDURE RealToEng (real: float; sigFigs: CARDINAL; VAR str: ARRAY OF CHAR);
  VAR s: XReal.STR;
BEGIN
  IF IsRealSpecial(real, str) THEN RETURN END;
  XReal.to_float(real, sigFigs, 3, digits(), 'E', FALSE, TRUE, s);
  XReal.strcpy(s, str);
END RealToEng;

PROCEDURE RealToFixed (real: float; place: INTEGER; VAR str: ARRAY OF CHAR);
  VAR s: XReal.STR;
BEGIN
  IF IsRealSpecial(real, str) THEN RETURN END;
  XReal.to_fixed(real, place, digits(), s);
  XReal.strcpy(s, str);
END RealToFixed;

PROCEDURE RealToStr (real: float; VAR str: ARRAY OF CHAR);
  VAR s: XReal.STR;
BEGIN
  IF IsRealSpecial(real, str) THEN RETURN END;
  XReal.to_any(real, digits(), s, LEN(str));
  XReal.strcpy(s, str);
END RealToStr;

BEGIN
  max_digits := 0;
END RealStr.
