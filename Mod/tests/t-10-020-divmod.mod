MODULE T10020DivMod;
(*
 * Group 10 — Arithmetic / constants
 * Test: integer division (DIV) and modulus (MOD).
 *
 * EXPECTED:
 * 3
 * 1
 *)
IMPORT STextIO, SWholeIO;
VAR q, r : INTEGER;
BEGIN
  q := 7 DIV 2;
  r := 7 MOD 2;
  SWholeIO.WriteInt(q, 0);
  STextIO.WriteLn;
  SWholeIO.WriteInt(r, 0);
  STextIO.WriteLn;
END T10020DivMod.
