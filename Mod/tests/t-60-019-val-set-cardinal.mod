MODULE T60019ValSetCardinal;
(*
 * Group 60 — Sets
 * Test: VAL(CARDINAL, set) reinterprets a BITSET as its underlying word
 *       (PIM BITSET-as-word), giving the bit-pattern value.
 *
 * EXPECTED:
 * 2048
 * 7
 *)
FROM SWholeIO IMPORT WriteCard;
FROM STextIO IMPORT WriteLn;

CONST flags = BITSET{11};

VAR c: CARDINAL;

BEGIN
  c := VAL(CARDINAL, flags);          (* bit 11 set -> 2048 *)
  WriteCard(c, 0); WriteLn;
  c := VAL(CARDINAL, BITSET{0, 1, 2}); (* bits 0,1,2 -> 7 *)
  WriteCard(c, 0); WriteLn
END T60019ValSetCardinal.
