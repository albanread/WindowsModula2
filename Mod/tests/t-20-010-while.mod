MODULE T20010While;
(*
 * Group 20 — Control flow
 * Test: WHILE loop iterates the correct number of times.
 *
 * EXPECTED:
 * 1
 * 2
 * 3
 * 4
 * 5
 *)
IMPORT STextIO, SWholeIO;
VAR i : INTEGER;
BEGIN
  i := 1;
  WHILE i <= 5 DO
    SWholeIO.WriteInt(i, 0);
    STextIO.WriteLn;
    i := i + 1;
  END;
END T20010While.
