IMPLEMENTATION MODULE Decimal;

(* value = coeff * 10^exp. Add/Sub align both coefficients to the lower (more
   negative) exponent and add/subtract exactly; Mul multiplies coefficients and
   adds exponents; Div and Round scale to the requested decimal places and round
   the integer quotient. Every BigInt temporary is Disposed; "BigInt" is the
   module, the type is "BigInt.BigInt" (aliased Int). *)

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
IMPORT BigInt;

TYPE
  Int = BigInt.BigInt;
  Decimal = POINTER TO Rec;
  Rec = RECORD coeff: Int; exp: INTEGER END;

VAR gOne: Int;

PROCEDURE NewRecRaw (coeff: Int; exp: INTEGER): Decimal;
  VAR p: Decimal; a: ADDRESS;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(Rec)); p := CAST(Decimal, a);
  p^.coeff := coeff; p^.exp := exp;
  RETURN p
END NewRecRaw;

PROCEDURE Pow10 (k: CARDINAL): Int;
  VAR ten, r: Int;
BEGIN ten := BigInt.FromCard(10); r := BigInt.Pow(ten, k); BigInt.Dispose(ten); RETURN r END Pow10;

(* d's coefficient scaled to exponent e (requires e <= d^.exp); fresh BigInt *)
PROCEDURE ScaleToExp (d: Decimal; e: INTEGER): Int;
  VAR p, r: Int;
BEGIN
  IF d^.exp = e THEN RETURN BigInt.Copy(d^.coeff) END;
  p := Pow10(VAL(CARDINAL, d^.exp - e));
  r := BigInt.Mul(d^.coeff, p); BigInt.Dispose(p);
  RETURN r
END ScaleToExp;

(* round num/den (both non-negative magnitudes, den>0) to an integer; fresh *)
PROCEDURE DivRound (num, den: Int; mode: RoundMode): Int;
  VAR q, r, r2, t: Int; ok: BOOLEAN; c: INTEGER;
BEGIN
  ok := BigInt.DivMod(num, den, q, r);
  IF mode = RoundHalfUp THEN
    r2 := BigInt.Add(r, r);
    c := BigInt.Compare(r2, den);
    BigInt.Dispose(r2);
    IF c >= 0 THEN t := BigInt.Add(q, gOne); BigInt.Dispose(q); q := t END
  END;
  BigInt.Dispose(r);
  RETURN q
END DivRound;

PROCEDURE Create (): Decimal;
BEGIN RETURN NewRecRaw(BigInt.FromCard(0), 0) END Create;

PROCEDURE Dispose (VAR d: Decimal);
  VAR pd: ADDRESS;
BEGIN
  IF d # NIL THEN
    BigInt.Dispose(d^.coeff);
    pd := CAST(ADDRESS, d); DEALLOCATE(pd, SIZE(Rec)); d := NIL
  END
END Dispose;

PROCEDURE Copy (d: Decimal): Decimal;
BEGIN RETURN NewRecRaw(BigInt.Copy(d^.coeff), d^.exp) END Copy;

PROCEDURE FromInt (v: INTEGER): Decimal;
BEGIN RETURN NewRecRaw(BigInt.FromInt(v), 0) END FromInt;

PROCEDURE FromBigInt (n: Int): Decimal;
BEGIN RETURN NewRecRaw(BigInt.Copy(n), 0) END FromBigInt;

PROCEDURE FromCoeffExp (coeff: Int; exp: INTEGER): Decimal;
BEGIN RETURN NewRecRaw(BigInt.Copy(coeff), exp) END FromCoeffExp;

PROCEDURE FromStr (s: ARRAY OF CHAR; VAR d: Decimal): BOOLEAN;
  VAR digits: ARRAY [0..1023] OF CHAR;
      i, k, fracLen: CARDINAL; neg, seenDot, anyDigit: BOOLEAN;
      coeff, t: Int; ok: BOOLEAN;
BEGIN
  i := 0; k := 0; fracLen := 0; neg := FALSE; seenDot := FALSE; anyDigit := FALSE;
  WHILE (i <= HIGH(s)) AND ((s[i] = ' ') OR (s[i] = CHR(9))) DO INC(i) END;
  IF (i <= HIGH(s)) AND ((s[i] = '-') OR (s[i] = '+')) THEN neg := s[i] = '-'; INC(i) END;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO
    IF s[i] = '.' THEN
      IF seenDot THEN d := Create(); RETURN FALSE END;
      seenDot := TRUE
    ELSIF (s[i] >= '0') AND (s[i] <= '9') THEN
      IF k >= HIGH(digits) THEN d := Create(); RETURN FALSE END;
      digits[k] := s[i]; INC(k); anyDigit := TRUE;
      IF seenDot THEN INC(fracLen) END
    ELSE
      d := Create(); RETURN FALSE
    END;
    INC(i)
  END;
  IF NOT anyDigit THEN d := Create(); RETURN FALSE END;
  digits[k] := 0C;
  IF NOT BigInt.FromStr(digits, 10, coeff) THEN BigInt.Dispose(coeff); d := Create(); RETURN FALSE END;
  IF neg AND (BigInt.Sign(coeff) > 0) THEN t := BigInt.Neg(coeff); BigInt.Dispose(coeff); coeff := t END;
  d := NewRecRaw(coeff, -VAL(INTEGER, fracLen));
  RETURN TRUE
END FromStr;

PROCEDURE MinExp (a, b: Decimal): INTEGER;
BEGIN IF a^.exp <= b^.exp THEN RETURN a^.exp ELSE RETURN b^.exp END END MinExp;

PROCEDURE Add (a, b: Decimal): Decimal;
  VAR ca, cb, num: Int; e: INTEGER;
BEGIN
  e := MinExp(a, b);
  ca := ScaleToExp(a, e); cb := ScaleToExp(b, e);
  num := BigInt.Add(ca, cb);
  BigInt.Dispose(ca); BigInt.Dispose(cb);
  RETURN NewRecRaw(num, e)
END Add;

PROCEDURE Sub (a, b: Decimal): Decimal;
  VAR ca, cb, num: Int; e: INTEGER;
BEGIN
  e := MinExp(a, b);
  ca := ScaleToExp(a, e); cb := ScaleToExp(b, e);
  num := BigInt.Sub(ca, cb);
  BigInt.Dispose(ca); BigInt.Dispose(cb);
  RETURN NewRecRaw(num, e)
END Sub;

PROCEDURE Mul (a, b: Decimal): Decimal;
BEGIN RETURN NewRecRaw(BigInt.Mul(a^.coeff, b^.coeff), a^.exp + b^.exp) END Mul;

PROCEDURE Div (a, b: Decimal; places: CARDINAL; mode: RoundMode): Decimal;
  VAR an, bn, num, den, q, p, t: Int; shift, sgn: INTEGER;
BEGIN
  IF BigInt.IsZero(b^.coeff) THEN RETURN Create() END;
  sgn := BigInt.Sign(a^.coeff) * BigInt.Sign(b^.coeff);
  an := BigInt.Abs(a^.coeff); bn := BigInt.Abs(b^.coeff);
  shift := a^.exp + VAL(INTEGER, places) - b^.exp;
  IF shift >= 0 THEN
    p := Pow10(VAL(CARDINAL, shift)); num := BigInt.Mul(an, p); den := BigInt.Copy(bn); BigInt.Dispose(p)
  ELSE
    p := Pow10(VAL(CARDINAL, -shift)); den := BigInt.Mul(bn, p); num := BigInt.Copy(an); BigInt.Dispose(p)
  END;
  BigInt.Dispose(an); BigInt.Dispose(bn);
  q := DivRound(num, den, mode);
  BigInt.Dispose(num); BigInt.Dispose(den);
  IF sgn < 0 THEN t := BigInt.Neg(q); BigInt.Dispose(q); q := t END;
  RETURN NewRecRaw(q, -VAL(INTEGER, places))
END Div;

PROCEDURE Neg (d: Decimal): Decimal;
BEGIN RETURN NewRecRaw(BigInt.Neg(d^.coeff), d^.exp) END Neg;

PROCEDURE Abs (d: Decimal): Decimal;
BEGIN RETURN NewRecRaw(BigInt.Abs(d^.coeff), d^.exp) END Abs;

PROCEDURE Round (d: Decimal; places: CARDINAL; mode: RoundMode): Decimal;
  VAR targetExp, sgn: INTEGER; num, den, q, p, coeff, t: Int; k: CARDINAL;
BEGIN
  targetExp := -VAL(INTEGER, places);
  IF d^.exp >= targetExp THEN
    IF d^.exp = targetExp THEN RETURN Copy(d) END;
    k := VAL(CARDINAL, d^.exp - targetExp);             (* pad with zeros, exact *)
    p := Pow10(k); coeff := BigInt.Mul(d^.coeff, p); BigInt.Dispose(p);
    RETURN NewRecRaw(coeff, targetExp)
  END;
  k := VAL(CARDINAL, targetExp - d^.exp);               (* round off *)
  sgn := BigInt.Sign(d^.coeff);
  num := BigInt.Abs(d^.coeff); den := Pow10(k);
  q := DivRound(num, den, mode);
  BigInt.Dispose(num); BigInt.Dispose(den);
  IF sgn < 0 THEN t := BigInt.Neg(q); BigInt.Dispose(q); q := t END;
  RETURN NewRecRaw(q, targetExp)
END Round;

PROCEDURE Compare (a, b: Decimal): INTEGER;
  VAR ca, cb: Int; e, c: INTEGER;
BEGIN
  e := MinExp(a, b);
  ca := ScaleToExp(a, e); cb := ScaleToExp(b, e);
  c := BigInt.Compare(ca, cb);
  BigInt.Dispose(ca); BigInt.Dispose(cb);
  RETURN c
END Compare;

PROCEDURE Sign (d: Decimal): INTEGER; BEGIN RETURN BigInt.Sign(d^.coeff) END Sign;
PROCEDURE IsZero (d: Decimal): BOOLEAN; BEGIN RETURN BigInt.IsZero(d^.coeff) END IsZero;
PROCEDURE Exponent (d: Decimal): INTEGER; BEGIN RETURN d^.exp END Exponent;

PROCEDURE ToStr (d: Decimal; VAR s: ARRAY OF CHAR): BOOLEAN;
  VAR mag: ARRAY [0..1023] OF CHAR; absd: Int;
      len, nfrac, intLen, i, k, z: CARDINAL; neg, ok: BOOLEAN;

  PROCEDURE Put (c: CHAR): BOOLEAN;
  BEGIN IF k > HIGH(s) THEN RETURN FALSE END; s[k] := c; INC(k); RETURN TRUE END Put;

BEGIN
  neg := BigInt.Sign(d^.coeff) < 0;
  absd := BigInt.Abs(d^.coeff);
  ok := BigInt.ToStr(absd, 10, mag); BigInt.Dispose(absd);
  IF NOT ok THEN RETURN FALSE END;
  len := 0; WHILE mag[len] # 0C DO INC(len) END;
  k := 0;
  IF neg THEN IF NOT Put('-') THEN RETURN FALSE END END;

  IF d^.exp >= 0 THEN
    i := 0; WHILE i < len DO IF NOT Put(mag[i]) THEN RETURN FALSE END; INC(i) END;
    z := 0; WHILE z < VAL(CARDINAL, d^.exp) DO IF NOT Put('0') THEN RETURN FALSE END; INC(z) END
  ELSE
    nfrac := VAL(CARDINAL, -d^.exp);
    IF len > nfrac THEN
      intLen := len - nfrac;
      i := 0; WHILE i < intLen DO IF NOT Put(mag[i]) THEN RETURN FALSE END; INC(i) END;
      IF NOT Put('.') THEN RETURN FALSE END;
      WHILE i < len DO IF NOT Put(mag[i]) THEN RETURN FALSE END; INC(i) END
    ELSE
      IF NOT Put('0') THEN RETURN FALSE END;
      IF NOT Put('.') THEN RETURN FALSE END;
      z := 0; WHILE z < nfrac - len DO IF NOT Put('0') THEN RETURN FALSE END; INC(z) END;
      i := 0; WHILE i < len DO IF NOT Put(mag[i]) THEN RETURN FALSE END; INC(i) END
    END
  END;
  IF k > HIGH(s) THEN RETURN FALSE END;
  s[k] := 0C; RETURN TRUE
END ToStr;

BEGIN
  gOne := BigInt.FromCard(1)
END Decimal.
