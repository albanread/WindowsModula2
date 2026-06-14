MODULE T90200CharConcat;
(*
 * Group 90 — constant expressions
 * Test: `+` concatenates characters and strings (it is never arithmetic on
 *       characters in Modula-2). A chain of single-char literals builds a
 *       string; a constant char concatenation passed to an open ARRAY OF CHAR
 *       carries the right length.
 *
 * EXPECTED:
 * World 5
 * 2
 *)
FROM StrIO IMPORT WriteString, WriteLn;
FROM StrLib IMPORT StrLen;
FROM NumberIO IMPORT WriteCard;

CONST World = "W" + "o" + "r" + "l" + "d";

PROCEDURE len (a: ARRAY OF CHAR): CARDINAL;
BEGIN
  RETURN StrLen(a)
END len;

BEGIN
  WriteString(World); WriteString(" "); WriteCard(StrLen(World), 0); WriteLn;
  WriteCard(len(015C + 012C), 0); WriteLn
END T90200CharConcat.
