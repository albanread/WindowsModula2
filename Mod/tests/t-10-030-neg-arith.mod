MODULE T10030NegArith;
(*
 * Group 10 — Arithmetic / constants
 * Test: unary negation and subtraction.
 *
 * EXPECTED:
 * -5
 * 10
 *)
IMPORT STextIO, SWholeIO;
VAR a, b : INTEGER;
BEGIN
  a := -5;
  b := 15 + a;
  SWholeIO.WriteInt(a, 0);
  STextIO.WriteLn;
  SWholeIO.WriteInt(b, 0);
  STextIO.WriteLn;
END T10030NegArith.
