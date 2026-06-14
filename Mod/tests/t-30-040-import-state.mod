MODULE T30040ImportState;
(*
 * Group 30 — Module imports / typed value calls
 * Test: imported procedures can accept INTEGER, CARDINAL, CHAR, and BOOLEAN
 * value parameters and use them in helper-side I/O and branching.
 *
 * EXPECTED:
 * -12
 * 21
 * Z
 * 1
 *)
IMPORT STextIO, SWholeIO;
FROM T30040StateHelper IMPORT EchoValues;

BEGIN
  EchoValues(-12, 21, 'Z', TRUE);
END T30040ImportState.