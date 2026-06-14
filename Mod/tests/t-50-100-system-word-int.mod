MODULE T50100SystemWordInt;
(*
 * Group 50 — SYSTEM / low-level
 * Test: SYSTEM.WORD / SYSTEM.BYTE are storage types assignment-compatible with
 *       integers (INTEGER -> WORD and back) and convertible via VAL. (They do
 *       not support arithmetic — that is a separate, rejected case.)
 *
 * EXPECTED:
 * 105
 * 66
 *)
FROM SYSTEM IMPORT WORD, BYTE;
FROM SWholeIO IMPORT WriteCard;
FROM STextIO IMPORT WriteLn;

VAR w: WORD; b: BYTE; i: INTEGER;

BEGIN
  i := 105;
  w := i;                          (* INTEGER -> WORD assignment *)
  WriteCard(VAL(CARDINAL, w), 0); WriteLn;   (* 105 *)
  b := 66;                         (* integer literal -> BYTE *)
  WriteCard(VAL(CARDINAL, b), 0); WriteLn    (* 66 *)
END T50100SystemWordInt.
