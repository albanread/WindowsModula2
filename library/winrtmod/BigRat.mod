IMPLEMENTATION MODULE BigRat;

(* A BigRat is a heap record holding two BigInt handles it owns. Every public op
   builds fresh num/den BigInts (disposing intermediates) and hands them to
   MakeRat, which enforces the invariant: den > 0, and num/den reduced by their
   gcd (0 is stored as 0/1).

   "BigInt" alone is the module; the BigInt type is "BigInt.BigInt". *)

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
IMPORT BigInt;

TYPE
  Int = BigInt.BigInt;                     (* shorthand for the BigInt type *)
  BigRat = POINTER TO Rec;
  Rec = RECORD num, den: Int END;

VAR gOne: Int;                             (* the constant 1 (program-lifetime) *)

PROCEDURE NewRecRaw (num, den: Int): BigRat;
  VAR p: BigRat; a: ADDRESS;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(Rec)); p := CAST(BigRat, a);
  p^.num := num; p^.den := den;
  RETURN p
END NewRecRaw;

(* take ownership of num and den, normalise in place, wrap in a BigRat *)
PROCEDURE MakeRat (num, den: Int): BigRat;
  VAR g, t: Int;
BEGIN
  IF BigInt.Sign(den) < 0 THEN
    t := BigInt.Neg(num); BigInt.Dispose(num); num := t;
    t := BigInt.Neg(den); BigInt.Dispose(den); den := t
  END;
  IF BigInt.IsZero(num) THEN
    BigInt.Dispose(den); den := BigInt.FromCard(1)
  ELSE
    g := BigInt.Gcd(num, den);             (* gcd of absolute values, >= 1 *)
    IF BigInt.Compare(g, gOne) # 0 THEN
      t := BigInt.Div(num, g); BigInt.Dispose(num); num := t;
      t := BigInt.Div(den, g); BigInt.Dispose(den); den := t
    END;
    BigInt.Dispose(g)
  END;
  RETURN NewRecRaw(num, den)
END MakeRat;

PROCEDURE Create (): BigRat;
BEGIN RETURN NewRecRaw(BigInt.FromCard(0), BigInt.FromCard(1)) END Create;

PROCEDURE Dispose (VAR r: BigRat);
  VAR pr: ADDRESS;
BEGIN
  IF r # NIL THEN
    BigInt.Dispose(r^.num); BigInt.Dispose(r^.den);
    pr := CAST(ADDRESS, r); DEALLOCATE(pr, SIZE(Rec)); r := NIL
  END
END Dispose;

PROCEDURE Copy (r: BigRat): BigRat;
BEGIN RETURN NewRecRaw(BigInt.Copy(r^.num), BigInt.Copy(r^.den)) END Copy;

PROCEDURE FromInt (v: INTEGER): BigRat;
BEGIN RETURN NewRecRaw(BigInt.FromInt(v), BigInt.FromCard(1)) END FromInt;

PROCEDURE FromRatio (num, den: INTEGER): BigRat;
BEGIN
  IF den = 0 THEN RETURN Create() END;
  RETURN MakeRat(BigInt.FromInt(num), BigInt.FromInt(den))
END FromRatio;

PROCEDURE FromBigInt (n: Int): BigRat;
BEGIN RETURN NewRecRaw(BigInt.Copy(n), BigInt.FromCard(1)) END FromBigInt;

PROCEDURE FromBigRatio (num, den: Int): BigRat;
BEGIN
  IF BigInt.IsZero(den) THEN RETURN Create() END;
  RETURN MakeRat(BigInt.Copy(num), BigInt.Copy(den))
END FromBigRatio;

PROCEDURE Num (r: BigRat): Int; BEGIN RETURN BigInt.Copy(r^.num) END Num;
PROCEDURE Den (r: BigRat): Int; BEGIN RETURN BigInt.Copy(r^.den) END Den;

PROCEDURE Add (a, b: BigRat): BigRat;
  VAR p1, p2, num, den: Int;
BEGIN
  p1 := BigInt.Mul(a^.num, b^.den); p2 := BigInt.Mul(b^.num, a^.den);
  num := BigInt.Add(p1, p2);
  den := BigInt.Mul(a^.den, b^.den);
  BigInt.Dispose(p1); BigInt.Dispose(p2);
  RETURN MakeRat(num, den)
END Add;

PROCEDURE Sub (a, b: BigRat): BigRat;
  VAR p1, p2, num, den: Int;
BEGIN
  p1 := BigInt.Mul(a^.num, b^.den); p2 := BigInt.Mul(b^.num, a^.den);
  num := BigInt.Sub(p1, p2);
  den := BigInt.Mul(a^.den, b^.den);
  BigInt.Dispose(p1); BigInt.Dispose(p2);
  RETURN MakeRat(num, den)
END Sub;

PROCEDURE Mul (a, b: BigRat): BigRat;
BEGIN RETURN MakeRat(BigInt.Mul(a^.num, b^.num), BigInt.Mul(a^.den, b^.den)) END Mul;

PROCEDURE Div (a, b: BigRat): BigRat;
BEGIN
  IF IsZero(b) THEN RETURN Create() END;
  RETURN MakeRat(BigInt.Mul(a^.num, b^.den), BigInt.Mul(a^.den, b^.num))
END Div;

PROCEDURE Neg (r: BigRat): BigRat;
BEGIN RETURN NewRecRaw(BigInt.Neg(r^.num), BigInt.Copy(r^.den)) END Neg;

PROCEDURE Recip (r: BigRat): BigRat;
BEGIN
  IF IsZero(r) THEN RETURN Create() END;
  RETURN MakeRat(BigInt.Copy(r^.den), BigInt.Copy(r^.num))
END Recip;

PROCEDURE Compare (a, b: BigRat): INTEGER;
  VAR p1, p2: Int; c: INTEGER;
BEGIN
  p1 := BigInt.Mul(a^.num, b^.den); p2 := BigInt.Mul(b^.num, a^.den);
  c := BigInt.Compare(p1, p2);
  BigInt.Dispose(p1); BigInt.Dispose(p2);
  RETURN c
END Compare;

PROCEDURE Sign (r: BigRat): INTEGER; BEGIN RETURN BigInt.Sign(r^.num) END Sign;
PROCEDURE IsZero (r: BigRat): BOOLEAN; BEGIN RETURN BigInt.IsZero(r^.num) END IsZero;
PROCEDURE IsInteger (r: BigRat): BOOLEAN; BEGIN RETURN BigInt.Compare(r^.den, gOne) = 0 END IsInteger;

PROCEDURE ToStr (r: BigRat; VAR s: ARRAY OF CHAR): BOOLEAN;
  VAR ns, ds: ARRAY [0..1023] OF CHAR; k, i: CARDINAL;
BEGIN
  IF NOT BigInt.ToStr(r^.num, 10, ns) THEN RETURN FALSE END;
  k := 0; i := 0;
  WHILE ns[i] # 0C DO
    IF k > HIGH(s) THEN RETURN FALSE END;
    s[k] := ns[i]; INC(k); INC(i)
  END;
  IF NOT IsInteger(r) THEN
    IF k > HIGH(s) THEN RETURN FALSE END;
    s[k] := '/'; INC(k);
    IF NOT BigInt.ToStr(r^.den, 10, ds) THEN RETURN FALSE END;
    i := 0;
    WHILE ds[i] # 0C DO
      IF k > HIGH(s) THEN RETURN FALSE END;
      s[k] := ds[i]; INC(k); INC(i)
    END
  END;
  IF k > HIGH(s) THEN RETURN FALSE END;
  s[k] := 0C; RETURN TRUE
END ToStr;

BEGIN
  gOne := BigInt.FromCard(1)
END BigRat.
