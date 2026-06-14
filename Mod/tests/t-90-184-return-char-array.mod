MODULE T90184ReturnCharArray;
(*
 * Group 90 — codegen / functions
 * Test: a function whose result type is a fixed ARRAY OF CHAR returns the array
 *       by value. RETURN of a string literal copies the characters into the
 *       result; the returned array can be assigned to a variable and passed to
 *       an open-array parameter (which spills it and supplies the correct HIGH).
 *
 * EXPECTED:
 * hello world
 * 11
 *)
FROM StrIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;

TYPE
  str = ARRAY [0..50] OF CHAR;

PROCEDURE greet (): str;
BEGIN
  RETURN "hello world"
END greet;

PROCEDURE Length (a: ARRAY OF CHAR): CARDINAL;
VAR n: CARDINAL;
BEGIN
  n := 0;
  WHILE (n <= HIGH(a)) AND (a[n] # 0C) DO INC(n) END;
  RETURN n
END Length;

VAR s: str;
BEGIN
  s := greet();
  WriteString(s); WriteLn;                  (* hello world *)
  WriteCard(Length(greet()), 0); WriteLn    (* 11 — open-array passing of a call result *)
END T90184ReturnCharArray.
