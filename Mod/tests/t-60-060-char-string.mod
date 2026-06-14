MODULE T60060CharString;
(*
 * Group 60 — ISO library / strings
 * Test: a single-character literal is dual-typed — usable as a CHAR and as a
 *       length-1 ARRAY OF CHAR string argument.
 *
 * EXPECTED:
 * x
 * abc
 *)
IMPORT STextIO, Strings;
VAR buf: ARRAY [0..15] OF CHAR;
    ch: CHAR;
BEGIN
  ch := "x";
  STextIO.WriteChar(ch);
  STextIO.WriteLn;
  Strings.Assign("ab", buf);
  Strings.Append("c", buf);
  STextIO.WriteString(buf);
  STextIO.WriteLn;
END T60060CharString.
