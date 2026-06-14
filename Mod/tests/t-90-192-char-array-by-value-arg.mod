MODULE T90192CharArrayByValueArg;
(*
 * Group 90 — parameters
 * Test: a string/char literal passed by value to a FIXED `ARRAY OF CHAR`
 *       parameter is copied into the array, not passed as a bare char or as a
 *       string pointer's bits.
 *
 * EXPECTED:
 * z
 * hi
 *)
FROM StrIO IMPORT WriteString, WriteLn;

TYPE T = ARRAY [0..19] OF CHAR;

PROCEDURE show (p: T);
BEGIN
  WriteString(p); WriteLn
END show;

BEGIN
  show('z');
  show("hi")
END T90192CharArrayByValueArg.
