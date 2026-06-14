MODULE T90171TBitSize;
(*
 * Group 90 — SYSTEM
 * Test: SYSTEM.TBITSIZE(T) yields a type's size in bits (TSIZE bytes x 8).
 *
 * EXPECTED:
 * 16 2 64 8
 *)
FROM SYSTEM IMPORT TBITSIZE, TSIZE, BITSPERLOC;
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

BEGIN
  WriteCard(TBITSIZE(CHAR), 0); WriteString(" ");      (* 16 *)
  WriteCard(TSIZE(CHAR), 0); WriteString(" ");         (* 2 *)
  WriteCard(TBITSIZE(CARDINAL), 0); WriteString(" ");  (* 64 *)
  WriteCard(BITSPERLOC, 0); WriteLn                    (* 8 *)
END T90171TBitSize.
