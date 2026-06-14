MODULE T30010WriteStr;
(*
 * Group 30 — Strings / I/O
 * Test: WriteString writes the expected text.
 *
 * EXPECTED:
 * hello world
 *)
IMPORT STextIO;
BEGIN
  STextIO.WriteString("hello world");
  STextIO.WriteLn;
END T30010WriteStr.
