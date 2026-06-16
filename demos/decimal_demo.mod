MODULE DecimalDemo;
(*
 * Exercises Decimal arbitrary-precision base-10 arithmetic.
 *   build: newm2 build demos/decimal_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard, WriteInt;
IMPORT Decimal;

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

(* ToStr d, compare to expect, dispose d *)
PROCEDURE CheckDec (label, expect: ARRAY OF CHAR; d: Decimal.Decimal);
  VAR s: ARRAY [0..255] OF CHAR; ok: BOOLEAN;
BEGIN
  ok := Decimal.ToStr(d, s);
  WriteString(label); WriteString(" = ");
  IF ok THEN WriteString(s) ELSE WriteString("?") END;
  IF ok AND StrEq(s, expect) THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteString(expect); INC(fail) END;
  WriteLn;
  Decimal.Dispose(d)
END CheckDec;

PROCEDURE CheckI (label: ARRAY OF CHAR; got, want: INTEGER);
BEGIN
  WriteString(label); WriteString(" = "); WriteInt(got, 1);
  IF got = want THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteInt(want, 1); INC(fail) END;
  WriteLn
END CheckI;

(* parse a literal (assumes valid) *)
PROCEDURE D (lit: ARRAY OF CHAR): Decimal.Decimal;
  VAR d: Decimal.Decimal; ok: BOOLEAN;
BEGIN ok := Decimal.FromStr(lit, d); RETURN d END D;

VAR a, b: Decimal.Decimal;

BEGIN
  pass := 0; fail := 0;
  WriteString("=== Decimal: arbitrary-precision base-10 ==="); WriteLn;

  (* parse / format round trips *)
  CheckDec("parse 123.45 ", "123.45", D("123.45"));
  CheckDec("parse -0.001 ", "-0.001", D("-0.001"));
  CheckDec("parse 42     ", "42", D("42"));
  CheckDec("parse 0.50   ", "0.50", D("0.50"));     (* trailing zero preserved (scale) *)

  (* exact arithmetic — incl the float-killer 0.1+0.2 *)
  a := D("0.1"); b := D("0.2");
  CheckDec("0.1 + 0.2    ", "0.3", Decimal.Add(a, b));
  Decimal.Dispose(a); Decimal.Dispose(b);
  a := D("1.5"); b := D("2.25");
  CheckDec("1.5 + 2.25   ", "3.75", Decimal.Add(a, b));
  Decimal.Dispose(a); Decimal.Dispose(b);
  a := D("10"); b := D("0.1");
  CheckDec("10 - 0.1     ", "9.9", Decimal.Sub(a, b));
  Decimal.Dispose(a); Decimal.Dispose(b);
  a := D("1.5"); b := D("2");
  CheckDec("1.5 * 2      ", "3.0", Decimal.Mul(a, b));
  Decimal.Dispose(a); Decimal.Dispose(b);

  (* division with rounding *)
  a := D("1"); b := D("3");
  CheckDec("1/3 @5 dp    ", "0.33333", Decimal.Div(a, b, 5, Decimal.RoundHalfUp));
  Decimal.Dispose(a); Decimal.Dispose(b);
  a := D("2"); b := D("3");
  CheckDec("2/3 @5 hu    ", "0.66667", Decimal.Div(a, b, 5, Decimal.RoundHalfUp));
  Decimal.Dispose(a); Decimal.Dispose(b);
  a := D("2"); b := D("3");
  CheckDec("2/3 @5 down  ", "0.66666", Decimal.Div(a, b, 5, Decimal.RoundDown));
  Decimal.Dispose(a); Decimal.Dispose(b);
  a := D("10"); b := D("4");
  CheckDec("10/4 @2      ", "2.50", Decimal.Div(a, b, 2, Decimal.RoundHalfUp));
  Decimal.Dispose(a); Decimal.Dispose(b);
  a := D("-1"); b := D("8");
  CheckDec("-1/8 @3      ", "-0.125", Decimal.Div(a, b, 3, Decimal.RoundHalfUp));
  Decimal.Dispose(a); Decimal.Dispose(b);

  (* round *)
  CheckDec("round 3.14159", "3.14", Decimal.Round(D("3.14159"), 2, Decimal.RoundHalfUp));
  CheckDec("round 3.145  ", "3.15", Decimal.Round(D("3.145"), 2, Decimal.RoundHalfUp));
  CheckDec("round 2.5 @0 ", "3", Decimal.Round(D("2.5"), 0, Decimal.RoundHalfUp));
  CheckDec("round -2.5 @0", "-3", Decimal.Round(D("-2.5"), 0, Decimal.RoundHalfUp));

  (* compare / sign *)
  a := D("1.5"); b := D("1.50");
  CheckI("cmp 1.5,1.50 ", Decimal.Compare(a, b), 0);
  Decimal.Dispose(a); Decimal.Dispose(b);
  a := D("0.1"); b := D("0.2");
  CheckI("cmp 0.1,0.2  ", Decimal.Compare(a, b), -1);
  Decimal.Dispose(a); Decimal.Dispose(b);
  a := D("-5.5");
  CheckI("sign -5.5    ", Decimal.Sign(a), -1);
  Decimal.Dispose(a);
  CheckDec("neg 3.75     ", "-3.75", Decimal.Neg(D("3.75")));

  WriteLn;
  WriteString("PASS="); WriteCard(pass, 1);
  WriteString("  FAIL="); WriteCard(fail, 1); WriteLn
END DecimalDemo.
