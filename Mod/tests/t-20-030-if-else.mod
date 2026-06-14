MODULE T20030IfElse;
(*
 * Group 20 — Control flow
 * Test: IF / ELSIF / ELSE branching.
 *
 * EXPECTED:
 * low
 * mid
 * high
 *)
IMPORT STextIO;

PROCEDURE Category(n : INTEGER);
BEGIN
  IF n < 10 THEN
    STextIO.WriteString("low");
  ELSIF n < 100 THEN
    STextIO.WriteString("mid");
  ELSE
    STextIO.WriteString("high");
  END;
  STextIO.WriteLn;
END Category;

BEGIN
  Category(3);
  Category(42);
  Category(200);
END T20030IfElse.
