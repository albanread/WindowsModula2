IMPLEMENTATION MODULE Money;

CONST NUL = CHR(0);

TYPE
  ResultArray = ARRAY [0 .. 3] OF CARDINAL;   (* 128-bit value, four 32-bit limbs, little-endian *)

(* ---- magnitude / sign helpers ------------------------------------------ *)

PROCEDURE MagU (x: INTEGER): CARDINAL;
  (* |x| without overflowing on MIN(INTEGER). *)
BEGIN
  IF x < 0 THEN RETURN VAL(CARDINAL, -(x + 1)) + 1 ELSE RETURN VAL(CARDINAL, x) END
END MagU;

PROCEDURE Signed (mag: CARDINAL; neg: BOOLEAN): Money;
BEGIN
  IF neg THEN RETURN -VAL(INTEGER, mag) ELSE RETURN VAL(INTEGER, mag) END
END Signed;

(* ---- 128-bit limb arithmetic ------------------------------------------- *)

(* Schoolbook 64x64 -> 128 unsigned multiply into r[0..3]. *)
PROCEDURE MulPrim (a, b: CARDINAL; VAR r: ResultArray);
  VAR a1, b1: ARRAY [0 .. 1] OF CARDINAL;
      ai, bi, ri, carry, temp: CARDINAL;
BEGIN
  a1[0] := a BAND 0FFFFFFFFH; a1[1] := a SHR 32;
  b1[0] := b BAND 0FFFFFFFFH; b1[1] := b SHR 32;
  r[0] := 0; r[1] := 0; r[2] := 0; r[3] := 0;
  FOR ai := 0 TO 1 DO
    FOR bi := 0 TO 1 DO
      ri := ai + bi;
      temp := a1[ai] * b1[bi] + r[ri];   (* fits 64 bits: (2^32-1)^2 + (2^32-1) < 2^64 *)
      r[ri] := temp BAND 0FFFFFFFFH;
      carry := temp SHR 32;
      INC(ri);
      WHILE (carry # 0) AND (ri <= 3) DO
        temp := r[ri] + carry;
        r[ri] := temp BAND 0FFFFFFFFH;
        carry := temp SHR 32;
        INC(ri)
      END
    END
  END
END MulPrim;

(* Add a 64-bit value to the 128-bit accumulator. *)
PROCEDURE AddPrim (VAR r: ResultArray; v: CARDINAL);
  VAR carry, temp: CARDINAL;
BEGIN
  temp := r[0] + (v BAND 0FFFFFFFFH); r[0] := temp BAND 0FFFFFFFFH; carry := temp SHR 32;
  temp := r[1] + (v SHR 32) + carry;  r[1] := temp BAND 0FFFFFFFFH; carry := temp SHR 32;
  temp := r[2] + carry;               r[2] := temp BAND 0FFFFFFFFH; carry := temp SHR 32;
  temp := r[3] + carry;               r[3] := temp BAND 0FFFFFFFFH
END AddPrim;

(* Divide the 128-bit `r` by the 64-bit `divisor`, returning a 64-bit quotient
   (which fits for all in-range Money operations). Restoring shift-subtract:
   the remainder stays < divisor (<= 2^63 for Money), so it never overflows. *)
PROCEDURE DivPrim (r: ResultArray; divisor: CARDINAL): CARDINAL;
  VAR q, rem, bitval: CARDINAL; bit, limb, pos: CARDINAL;
BEGIN
  IF divisor = 0 THEN RETURN 0 END;
  q := 0; rem := 0;
  bit := 128;
  WHILE bit > 0 DO
    DEC(bit);
    limb := bit DIV 32; pos := bit MOD 32;
    bitval := (r[limb] SHR pos) BAND 1;
    rem := (rem SHL 1) BOR bitval;
    q := q SHL 1;
    IF rem >= divisor THEN
      rem := rem - divisor;
      q := q BOR 1
    END
  END;
  RETURN q
END DivPrim;

(* ---- conversions ------------------------------------------------------- *)

PROCEDURE IntToMoney (intVal: INTEGER): Money;
BEGIN RETURN intVal * Scale END IntToMoney;

PROCEDURE MoneyToInt (num: Money): INTEGER;
BEGIN RETURN Signed(MagU(num) DIV Scale, num < 0) END MoneyToInt;

PROCEDURE MakeFraction (fract: Fraction): Money;
BEGIN RETURN VAL(Money, fract) END MakeFraction;

PROCEDURE GetFraction (num: Money): Fraction;
BEGIN RETURN VAL(Fraction, MagU(num) MOD Scale) END GetFraction;

PROCEDURE MakeMoney (whole: INTEGER; fract: Fraction): Money;
  VAR mag: CARDINAL;
BEGIN
  mag := MagU(whole) * Scale + VAL(CARDINAL, fract);
  RETURN Signed(mag, whole < 0)
END MakeMoney;

PROCEDURE RealToMoney (fltVal: REAL): Money;
BEGIN
  IF fltVal < 0.0 THEN
    RETURN -VAL(INTEGER, TRUNC(-fltVal * FLOAT(Scale)))
  ELSE
    RETURN VAL(INTEGER, TRUNC(fltVal * FLOAT(Scale)))
  END
END RealToMoney;

PROCEDURE MoneyToReal (num: Money): REAL;
BEGIN RETURN FLOAT(num) / FLOAT(Scale) END MoneyToReal;

(* ---- arithmetic -------------------------------------------------------- *)

PROCEDURE Add (a, b: Money): Money;
BEGIN RETURN a + b END Add;
PROCEDURE AddInt (a: Money; intVal: INTEGER): Money;
BEGIN RETURN a + IntToMoney(intVal) END AddInt;
PROCEDURE Sub (a, b: Money): Money;
BEGIN RETURN a - b END Sub;
PROCEDURE SubInt (a: Money; intVal: INTEGER): Money;
BEGIN RETURN a - IntToMoney(intVal) END SubInt;
PROCEDURE Neg (a: Money): Money;
BEGIN RETURN -a END Neg;
PROCEDURE Abs (a: Money): Money;
BEGIN IF a < 0 THEN RETURN -a ELSE RETURN a END END Abs;

PROCEDURE Mul (a, b: Money): Money;
  VAR neg: BOOLEAN; r: ResultArray; q: CARDINAL;
BEGIN
  neg := (a < 0) # (b < 0);
  MulPrim(MagU(a), MagU(b), r);   (* r = |a|*|b| = |a_real*b_real|*Scale^2 *)
  AddPrim(r, Half);               (* round half-up before the /Scale rescale *)
  q := DivPrim(r, Scale);         (* drop one factor of Scale *)
  RETURN Signed(q, neg)
END Mul;

PROCEDURE MulInt (a: Money; intVal: INTEGER): Money;
BEGIN RETURN Mul(a, IntToMoney(intVal)) END MulInt;

PROCEDURE Div (a, b: Money): Money;
  VAR neg: BOOLEAN; r: ResultArray; q: CARDINAL;
BEGIN
  IF b = 0 THEN RETURN 0 END;
  neg := (a < 0) # (b < 0);
  MulPrim(MagU(a), Scale, r);     (* pre-scale the dividend into 128 bits *)
  q := DivPrim(r, MagU(b));       (* (|a|*Scale^2)/(|b|*Scale) = (|a|/|b|)*Scale *)
  RETURN Signed(q, neg)
END Div;

PROCEDURE DivInt (a: Money; intVal: INTEGER): Money;
BEGIN RETURN Div(a, IntToMoney(intVal)) END DivInt;

PROCEDURE Percent (m: Money; fract: Fraction): Money;
BEGIN RETURN Mul(m, MakeFraction(fract)) END Percent;

(* ---- string I/O -------------------------------------------------------- *)

PROCEDURE MoneyToString (num: Money; places: CARDINAL; VAR str: ARRAY OF CHAR): BOOLEAN;
  VAR neg: BOOLEAN; mag, whole, frac, disp, i, pos, k: CARDINAL;
      bias: ARRAY [0 .. 4] OF CARDINAL;
      chop: ARRAY [0 .. 4] OF CARDINAL;
      wbuf, fbuf: ARRAY [0 .. 23] OF CHAR;

  PROCEDURE Put (ch: CHAR): BOOLEAN;
  BEGIN
    IF pos > HIGH(str) THEN RETURN FALSE END;
    str[pos] := ch; INC(pos); RETURN TRUE
  END Put;

BEGIN
  bias[0] := 5000; bias[1] := 500; bias[2] := 50; bias[3] := 5; bias[4] := 0;
  chop[0] := 1;    chop[1] := 1000; chop[2] := 100; chop[3] := 10; chop[4] := 1;
  IF places > DecPlaces THEN places := DecPlaces END;
  neg := num < 0;
  mag := MagU(num) + bias[places];      (* round half-up to `places` *)
  whole := mag DIV Scale;
  frac := mag MOD Scale;
  pos := 0;
  IF neg AND ((whole # 0) OR (frac # 0)) THEN
    IF NOT Put('-') THEN RETURN FALSE END
  END;
  (* whole part, most-significant first *)
  i := 0;
  REPEAT wbuf[i] := CHR(ORD('0') + (whole MOD 10)); whole := whole DIV 10; INC(i) UNTIL whole = 0;
  WHILE i > 0 DO DEC(i); IF NOT Put(wbuf[i]) THEN RETURN FALSE END END;
  IF places > 0 THEN
    IF NOT Put('.') THEN RETURN FALSE END;
    disp := frac DIV chop[places];      (* drop the unwanted low ten-thousandth digits *)
    k := 0;                             (* exactly `places` digits, zero-padded *)
    WHILE k < places DO fbuf[k] := CHR(ORD('0') + (disp MOD 10)); disp := disp DIV 10; INC(k) END;
    i := places;
    WHILE i > 0 DO DEC(i); IF NOT Put(fbuf[i]) THEN RETURN FALSE END END
  END;
  IF pos <= HIGH(str) THEN str[pos] := NUL END;
  RETURN TRUE
END MoneyToString;

PROCEDURE StringToMoney (str: ARRAY OF CHAR; VAR num: Money): BOOLEAN;
  VAR neg, anyDigit: BOOLEAN;
      cap, pos, d, wholeMag, frac, place, nd: CARDINAL;
BEGIN
  cap := HIGH(str) + 1;
  pos := 0;
  WHILE (pos < cap) AND (str[pos] = ' ') DO INC(pos) END;
  neg := FALSE;
  IF pos < cap THEN
    IF str[pos] = '-' THEN neg := TRUE; INC(pos)
    ELSIF str[pos] = '+' THEN INC(pos) END
  END;
  wholeMag := 0; anyDigit := FALSE;
  WHILE (pos < cap) AND (str[pos] >= '0') AND (str[pos] <= '9') DO
    wholeMag := wholeMag * 10 + (ORD(str[pos]) - ORD('0'));
    anyDigit := TRUE; INC(pos)
  END;
  frac := 0;
  IF (pos < cap) AND (str[pos] = '.') THEN
    INC(pos);
    place := 1000; nd := 0;
    WHILE (pos < cap) AND (str[pos] >= '0') AND (str[pos] <= '9') DO
      d := ORD(str[pos]) - ORD('0');
      IF nd < 4 THEN
        frac := frac + d * place; place := place DIV 10
      ELSIF nd = 4 THEN
        IF d >= 5 THEN frac := frac + 1 END   (* round half-up on the 5th digit *)
      END;
      anyDigit := TRUE; INC(nd); INC(pos)
    END;
    IF frac >= Scale THEN INC(wholeMag); frac := frac - Scale END
  END;
  IF NOT anyDigit THEN RETURN FALSE END;
  (* must be fully consumed (end, NUL, or trailing spaces only) *)
  WHILE (pos < cap) AND (str[pos] = ' ') DO INC(pos) END;
  IF (pos < cap) AND (str[pos] # NUL) THEN RETURN FALSE END;
  num := Signed(wholeMag * Scale + frac, neg);
  RETURN TRUE
END StringToMoney;

END Money.
