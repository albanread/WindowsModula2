MODULE T10040ValRoundtrip;
(*
 * Group 10 — Arithmetic / conversions
 * Test: VAL accepts a type-name first argument and round-trips between
 * integer and floating scalar types.
 *
 * EXPECTED:
 * 42
 * 42
 *)
IMPORT STextIO, SWholeIO;

VAR
  src: LONGREAL;
  mid: INTEGER64;

BEGIN
  src := 42.0;
  mid := VAL(INTEGER64, src);

  SWholeIO.WriteInt(VAL(INTEGER, mid), 0);
  STextIO.WriteLn;

  SWholeIO.WriteInt(VAL(INTEGER, VAL(LONGREAL, mid)), 0);
  STextIO.WriteLn;
END T10040ValRoundtrip.