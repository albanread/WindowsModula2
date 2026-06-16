MODULE BigRatDemo;
(*
 * Exercises BigRat exact rational arithmetic against known values.
 *   build: newm2 build demos/bigrat_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard, WriteInt;
FROM BigRat IMPORT BigRat, Create, Dispose, FromInt, FromRatio,
  Add, Sub, Mul, Div, Neg, Recip, Compare, IsZero, IsInteger, ToStr;

VAR pass, fail: CARDINAL;

PROCEDURE StrEq (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  LOOP
    IF (i > HIGH(a)) OR (a[i] = 0C) THEN RETURN (i > HIGH(b)) OR (b[i] = 0C) END;
    IF (i > HIGH(b)) OR (a[i] # b[i]) THEN RETURN FALSE END;
    INC(i)
  END
END StrEq;

(* ToStr r, compare to expect, then dispose r *)
PROCEDURE CheckRat (label, expect: ARRAY OF CHAR; r: BigRat);
  VAR s: ARRAY [0..255] OF CHAR; ok: BOOLEAN;
BEGIN
  ok := ToStr(r, s);
  WriteString(label); WriteString(" = ");
  IF ok THEN WriteString(s) ELSE WriteString("?") END;
  IF ok AND StrEq(s, expect) THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteString(expect); INC(fail) END;
  WriteLn;
  Dispose(r)
END CheckRat;

PROCEDURE CheckI (label: ARRAY OF CHAR; got, want: INTEGER);
BEGIN
  WriteString(label); WriteString(" = "); WriteInt(got, 1);
  IF got = want THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteInt(want, 1); INC(fail) END;
  WriteLn
END CheckI;

PROCEDURE CheckB (label: ARRAY OF CHAR; got, want: BOOLEAN);
BEGIN
  WriteString(label); WriteString(" = ");
  IF got THEN WriteString("TRUE") ELSE WriteString("FALSE") END;
  IF got = want THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL]"); INC(fail) END;
  WriteLn
END CheckB;

VAR a, b, c, acc, term, t: BigRat; k: CARDINAL;

BEGIN
  pass := 0; fail := 0;
  WriteString("=== BigRat: exact rationals ==="); WriteLn;

  a := FromRatio(1, 2); b := FromRatio(1, 3);
  CheckRat("1/2 + 1/3   ", "5/6", Add(a, b));
  CheckRat("1/2 * 1/3   ", "1/6", Mul(a, b));
  CheckRat("1/2 - 1/3   ", "1/6", Sub(a, b));
  CheckRat("(1/2)/(1/3) ", "3/2", Div(a, b));
  CheckI ("cmp 1/2,1/3 ", Compare(a, b), 1);
  CheckI ("cmp 1/3,1/2 ", Compare(b, a), -1);
  Dispose(a); Dispose(b);

  CheckRat("2/4 reduces ", "1/2", FromRatio(2, 4));
  CheckRat("6/-8 signs  ", "-3/4", FromRatio(6, -8));
  CheckRat("3/3 = int   ", "1", FromRatio(3, 3));
  CheckRat("0/5 = 0     ", "0", FromRatio(0, 5));

  a := FromRatio(1, 2); b := FromRatio(1, 2);
  CheckRat("1/2 + 1/2   ", "1", Add(a, b));
  CheckB ("1/2 is int  ", IsInteger(a), FALSE);
  Dispose(a); Dispose(b);

  a := FromRatio(3, 4);
  CheckRat("recip 3/4   ", "4/3", Recip(a));
  CheckRat("neg 3/4     ", "-3/4", Neg(a));
  Dispose(a);

  a := FromRatio(-1, 2); b := FromRatio(1, 2);
  c := Add(a, b);
  CheckB ("-1/2+1/2 = 0", IsZero(c), TRUE);
  Dispose(a); Dispose(b); Dispose(c);

  (* harmonic sum H_10 = 1 + 1/2 + ... + 1/10 = 7381/2520 *)
  acc := FromInt(0); k := 1;
  WHILE k <= 10 DO
    term := FromRatio(1, VAL(INTEGER, k));
    t := Add(acc, term); Dispose(acc); Dispose(term); acc := t;
    INC(k)
  END;
  CheckRat("H_10        ", "7381/2520", acc);

  WriteLn;
  WriteString("PASS="); WriteCard(pass, 1);
  WriteString("  FAIL="); WriteCard(fail, 1); WriteLn
END BigRatDemo.
