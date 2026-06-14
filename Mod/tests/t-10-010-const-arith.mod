MODULE T10010ConstArith;
(*
 * Group 10 — Arithmetic / constants
 * Test: compile-time constant arithmetic is evaluated correctly.
 *
 * EXPECTED:
 * 42
 *)
IMPORT STextIO, SWholeIO;
BEGIN
  SWholeIO.WriteInt(6 * 7, 0);
  STextIO.WriteLn;
END T10010ConstArith.
