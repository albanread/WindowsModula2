MODULE T90183WordWidths;
(*
 * Group 90 — SYSTEM
 * Test: SYSTEM exports the exact-width word types WORD16 / WORD32 / WORD64
 *       (unsigned storage units), assignable and TSIZE-able.
 *
 * EXPECTED:
 * 2 4 8
 * 70000
 *)
FROM SYSTEM IMPORT WORD16, WORD32, WORD64, TSIZE;
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

VAR
  a: WORD16;
  b: WORD32;
  c: WORD64;
BEGIN
  WriteCard(TSIZE(WORD16), 0); WriteString(" ");
  WriteCard(TSIZE(WORD32), 0); WriteString(" ");
  WriteCard(TSIZE(WORD64), 0); WriteLn;        (* 2 4 8 *)
  a := 5;
  b := 70000;        (* exceeds 16-bit, fits 32 *)
  c := b;
  WriteCard(c, 0); WriteLn                       (* 70000 *)
END T90183WordWidths.
