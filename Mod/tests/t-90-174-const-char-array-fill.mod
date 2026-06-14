MODULE T90174ConstCharArrayFill;
(*
 * Group 90 — constants / strings
 * Test: a CONST ARRAY OF CHAR constructor whose single element is a string
 *       fills the array character by character (`array{ "ABC..." }`), rather
 *       than placing the whole string in cell 0.
 *
 * EXPECTED:
 * A Z
 * ABCDEFGHIJKLMNOPQRSTUVWXYZ
 *)
FROM StrIO IMPORT WriteString, WriteLn;

TYPE
  letters = ARRAY [0..25] OF CHAR;

CONST
  alpha = letters{ "ABCDEFGHIJKLMNOPQRSTUVWXYZ" };

VAR
  s: letters;
  one: ARRAY [0..1] OF CHAR;
BEGIN
  s := alpha;
  one[0] := s[0];  one[1] := CHR(0);  WriteString(one);   (* A *)
  WriteString(" ");
  one[0] := s[25]; one[1] := CHR(0);  WriteString(one);   (* Z *)
  WriteLn;
  WriteString(s); WriteLn                                 (* ABC...Z *)
END T90174ConstCharArrayFill.
