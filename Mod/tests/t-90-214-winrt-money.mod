MODULE T90214WinrtMoney;
(*
 * Group 90 — M2WINRT: Money. Fixed-point currency (scaled x10000). Exercises
 * the synthesized 128-bit intermediate Mul/Div (the large-value product
 * 1000000.00 * 1000000.00 overflows 64-bit), half-up rounding, sign handling,
 * percentages, and positional string format/parse round-trips.
 *
 * EXPECTED:
 * 5.00
 * 2.75
 * -2.75
 * 10.00
 * 0.0000
 * 0.0100
 * 2.50
 * 0.3333
 * 1000000000000.00
 * 14.00
 * parse ok=Y -> -1234.5678
 * 3.5000
 * 0.1235
 * garbage rejected=Y
 *)
FROM Money IMPORT Money, IntToMoney, MakeMoney, Mul, Div, Percent,
  MoneyToString, StringToMoney;
FROM StrIO IMPORT WriteString, WriteLn;

VAR s: ARRAY [0..63] OF CHAR; m: Money; ok: BOOLEAN;

PROCEDURE P (v: Money; places: CARDINAL);
BEGIN IF MoneyToString(v, places, s) THEN WriteString(s) ELSE WriteString("?") END; WriteLn END P;

BEGIN
  P(IntToMoney(5), 2);
  P(MakeMoney(2, 7500), 2);
  P(MakeMoney(-2, 7500), 2);
  P(Mul(MakeMoney(2, 5000), MakeMoney(4, 0)), 2);
  P(Mul(1, 1), 4);
  P(Mul(MakeMoney(0, 1000), MakeMoney(0, 1000)), 4);
  P(Div(MakeMoney(10, 0), MakeMoney(4, 0)), 2);
  P(Div(IntToMoney(1), IntToMoney(3)), 4);
  P(Mul(IntToMoney(1000000), IntToMoney(1000000)), 2);
  P(Percent(MakeMoney(200, 0), 700), 2);
  ok := StringToMoney("-1234.5678", m);
  WriteString("parse ok="); IF ok THEN WriteString("Y") ELSE WriteString("N") END;
  WriteString(" -> "); P(m, 4);
  ok := StringToMoney("3.5", m); P(m, 4);
  ok := StringToMoney("0.123456", m); P(m, 4);
  WriteString("garbage rejected=");
  IF StringToMoney("12x", m) THEN WriteString("N") ELSE WriteString("Y") END; WriteLn
END T90214WinrtMoney.
