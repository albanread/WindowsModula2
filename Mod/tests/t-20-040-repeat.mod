MODULE T20040Repeat;
(*
 * Group 20 — Control flow
 * Test: REPEAT…UNTIL loop.
 *
 * EXPECTED:
 * 0
 * 1
 * 2
 * 3
 *)
IMPORT STextIO, SWholeIO;
VAR i : INTEGER;
BEGIN
  i := 0;
  REPEAT
    SWholeIO.WriteInt(i, 0);
    STextIO.WriteLn;
    i := i + 1;
  UNTIL i > 3;
END T20040Repeat.
