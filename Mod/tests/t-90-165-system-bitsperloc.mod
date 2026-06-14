MODULE T90165SystemBitsPerLoc;
(*
 * Group 90 — SYSTEM
 * Test: the ISO SYSTEM constants BITSPERLOC / LOCSPERBYTE / LOCSPERWORD are
 *       exported and usable in expressions (a LOC is an 8-bit byte; a WORD is
 *       8 LOCs on this 64-bit build).
 *
 * EXPECTED:
 * 8 1 8 64
 *)
FROM SYSTEM IMPORT BITSPERLOC, LOCSPERBYTE, LOCSPERWORD;
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

BEGIN
  WriteCard(BITSPERLOC, 0); WriteString(" ");
  WriteCard(LOCSPERBYTE, 0); WriteString(" ");
  WriteCard(LOCSPERWORD, 0); WriteString(" ");
  WriteCard(BITSPERLOC * LOCSPERWORD, 0); WriteLn   (* bits per word = 64 *)
END T90165SystemBitsPerLoc.
