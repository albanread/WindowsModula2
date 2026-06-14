MODULE T90186NestedAggregateStrings;
(*
 * Group 90 — constructors
 * Test: a runtime aggregate constructor whose record/array slots are fixed
 *       ARRAY OF CHAR fields initialised from string literals copies the
 *       characters into each slot (not the string pointer's bits).
 *       Covers a nested array-of-records constructor.
 *
 * EXPECTED:
 * 12|34
 * 56|78
 *)
FROM StrIO IMPORT WriteString, WriteLn;

TYPE
  rec = RECORD i, o: ARRAY [0..15] OF CHAR END;
  arr = ARRAY [0..1] OF rec;

VAR a: arr;
BEGIN
  a := arr{ rec{"12", "34"}, rec{"56", "78"} };
  WriteString(a[0].i); WriteString("|"); WriteString(a[0].o); WriteLn;
  WriteString(a[1].i); WriteString("|"); WriteString(a[1].o); WriteLn
END T90186NestedAggregateStrings.
