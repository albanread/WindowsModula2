(* Copyright (c) 1999-2003 Excelsior, LLC. All Rights Reserved. *)
(* Ported to NewM2 2026-05-13 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - The XDS source has TWO `StrToReal` implementations:

         (a) A "precise" branch gated by `<* IF __GEN_C__ OR __GEN_X86__ *>`
             that bit-aliases LONGREAL through `LongBits = ARRAY[0..1] OF
             CARDINAL` (two 32-bit CARDINALs), uses `LONGLONGREAL` (x87
             80-bit extended precision), and calls into `xrInt64.X2C_MUL64`
             / `X2C_CARDTO64` / `X2C_ADD64`. Bit constants like
             `negativeZeroLB`, `maxFloatLB`, `minFloatLB` directly encode
             IEEE-754 binary64 layouts as paired 32-bit CARDINALs.
             *None of this is wordsize-clean on 64-bit NewM2 — CARDINAL
             is 64 bits, there is no `LONGLONGREAL`, and there is no x87
             extended path.*

         (b) A `<* ELSE *>` branch labelled `(* old implementation,
             precision is bad *)`. Pure Modula-2, sequential
             `r := r*10 + digit` accumulation in a LONGREAL — mirrors
             the `RealStr.StrToReal` structure.

       We port branch (b). Branch (a) is the "run back to LLVM" case:
       a precise round-trip `strtod` belongs in compiler/runtime work
       (e.g. an LLVM-backed conversion or a David Gay / Ryū-inverse
       implementation exposed via NM2RT), not in a Modula-2 .mod file.
       Precision limit of this port: ~15-16 significant decimal digits
       round-trip; the last 1-2 ULPs may differ from a precise strtod.
     - Dropped `<*+ M2EXTENSIONS *>` and the `<* IF NOT __GEN_C__ %THEN
       %- PROCINLINE %END *>` proc-inlining pragma.
     - Dropped `IMPORT SYSTEM`, `IMPORT xPOSIX, xrInt64` (unused after
       the flatten).
     - Replaced PIM-pervasive `COPY` with `Strings.Assign`.
     - `init()` removed — it only existed to materialise the x87 bit
       patterns for branch (a).
     - LongStr.digits() does `DEC(max_digits, 2)` where RealStr does
       `DEC(max_digits)`; preserved verbatim (the doubled decrement is
       intentional for LONGREAL precision headroom).
*)
IMPLEMENTATION MODULE LongStr; (* Andrew Cadach Aug 1993 *)

(* Modifications:
        14-Mar-94 Ned:   error in to_fixed (XDS upstream)
        22-Sep-93 Andy:  visualization of special 80387 values added (XDS upstream)
        08-Sep-93 Ned:   to_fixed, write (XDS upstream)
        28-Feb-95 Sem:   reimplemented (XDS upstream)
        2026-05-13:      pragma flatten; portable StrToReal only (NewM2 port).
*)

IMPORT ConvTypes, CharClass, XReal, Strings;

CONST
  PINF  = "+inf.";
  NINF  = "-inf.";

PROCEDURE IsRealSpecial(R: LONGREAL; VAR s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF (R # 0.0) & (R / 2.0 = R) THEN
    IF R < 0.0 THEN Strings.Assign(NINF, s) ELSE Strings.Assign(PINF, s) END;
    RETURN TRUE;
  END;
  RETURN FALSE;
END IsRealSpecial;

CONST
  EOS = 0C;

VAR
  max_digits: CARDINAL;

(* See RealStr.mod for the rationale behind these constant-folding
   barriers. *)

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
    DEC(max_digits, 2);   (* LONGREAL precision headroom; see header note *)
  END;
  RETURN max_digits;
END digits;

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

(* Portable StrToReal (XDS upstream <* ELSE *> branch).
   Precision: ~15-16 significant decimal digits round-trip; ULP-accurate
   round-trip is a follow-up (see header note). *)
PROCEDURE StrToReal(str: ARRAY OF CHAR; VAR real: float; VAR res: ConvResults);
  VAR
    s, i, e, n: CARDINAL;
    r, t, p: float;
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
      t := VAL(float, n);
      CASE s OF
      |0..2:
        rovf := rovf OR (r >= (MAX(float) - t) / 10.0);
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
    IF NOT ovf THEN
      t := XReal.power10(e, ovf);
      IF neg THEN
        r := r / t;
      ELSE
        ovf := MAX(float) / t <= r;
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
    IF c = EOS THEN real := r; RETURN END;
  END;

  IF (c = EOS) & (s = 0) THEN res := ConvTypes.strEmpty; RETURN; END;
  res := ConvTypes.strWrongFormat;
END StrToReal;

BEGIN
  max_digits := 0;
END LongStr.
