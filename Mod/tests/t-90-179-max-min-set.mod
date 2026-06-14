MODULE T90179MaxMinSet;
(*
 * Group 90 — builtins / sets
 * Test: MAX(T) / MIN(T) of a SET type range over the set's element type, not
 *       the set itself — so `MAX(SET OF [0..127])` is 127 and the value is
 *       usable as a FOR bound, e.g. `FOR i := 0 TO MAX(LargeSet)`.
 *
 * EXPECTED:
 * 127 0
 * counted 128
 *)
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

TYPE
  LargeSet = SET OF [0..127];

VAR
  i, n: CARDINAL;
BEGIN
  WriteCard(MAX(LargeSet), 0); WriteString(" ");
  WriteCard(MIN(LargeSet), 0); WriteLn;        (* 127 0 *)

  n := 0;
  FOR i := MIN(LargeSet) TO MAX(LargeSet) DO
    INC(n)
  END;
  WriteString("counted "); WriteCard(n, 0); WriteLn   (* 128 *)
END T90179MaxMinSet.
