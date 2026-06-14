MODULE T20020For;
(*
 * Group 20 — Control flow
 * Test: FOR loop sums 1..10 = 55.
 *
 * EXPECTED:
 * 55
 *)
IMPORT STextIO, SWholeIO;
VAR i, sum : INTEGER;
BEGIN
  sum := 0;
  FOR i := 1 TO 10 DO
    sum := sum + i;
  END;
  SWholeIO.WriteInt(sum, 0);
  STextIO.WriteLn;
END T20020For.
