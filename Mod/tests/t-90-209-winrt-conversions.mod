MODULE T90209WinrtConversions;
(*
 * Group 90 — M2WINRT runtime library: Conversions (whole <-> string, decimal
 * and base 2..16, overflow-checked). Exercises numeric loops, the magnitude/
 * sign split (so floored vs truncating DIV/MOD is moot), VAR result params,
 * and field-width padding.
 *
 * EXPECTED:
 * 255
 * FF
 * 11111111
 * DEADBEEF
 * 12345
 * -678
 * 255
 * 10
 * [   -42]
 *)
FROM Conversions IMPORT CardToStr, CardBaseToStr, StrToCard, StrToInt,
                        StrBaseToCard, IntToString;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard, WriteInt;

VAR
  s    : ARRAY [0..63] OF CHAR;
  c    : CARDINAL;
  n    : INTEGER;
  pos  : CARDINAL;
  ok   : BOOLEAN;
  done : BOOLEAN;
BEGIN
  IF CardToStr(255, s) THEN WriteString(s) END; WriteLn;
  IF CardBaseToStr(255, 16, s) THEN WriteString(s) END; WriteLn;
  IF CardBaseToStr(255, 2, s) THEN WriteString(s) END; WriteLn;
  IF CardBaseToStr(3735928559, 16, s) THEN WriteString(s) END; WriteLn;  (* DEADBEEF *)

  ok := StrToCard("12345", c);     WriteCard(c, 1); WriteLn;
  ok := StrToInt("-678", n);       WriteInt(n, 1);  WriteLn;
  ok := StrBaseToCard("FF", 16, c); WriteCard(c, 1); WriteLn;
  ok := StrBaseToCard("1010", 2, c); WriteCard(c, 1); WriteLn;

  pos := 0;
  IntToString(-42, 6, s, pos, done);
  WriteString("["); WriteString(s); WriteString("]"); WriteLn
END T90209WinrtConversions.
