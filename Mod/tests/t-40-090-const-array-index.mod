MODULE T40090ConstArrayIndex;
(*
 * Group 40 — Records / arrays
 * Test: indexing a RECORD/ARRAY constant directly (`vecConst[i]`), including a
 *       constant that aliases another (`b = a`). The constant is materialised
 *       into a slot so it has an address to index.
 *
 * EXPECTED:
 * 20
 * 30
 * 99
 *)
FROM STextIO IMPORT WriteLn;
FROM SWholeIO IMPORT WriteCard;

TYPE V = ARRAY [1..3] OF CARDINAL;

CONST
  a = V{10, 20, 30};
  b = a;                       (* constant aliasing a constant *)

VAR x: CARDINAL;

BEGIN
  x := a[2]; WriteCard(x, 0); WriteLn;   (* 20 *)
  x := b[3]; WriteCard(x, 0); WriteLn;   (* 30 *)
  x := a[1] + b[2] + 69;                 (* 10 + 20 + 69 = 99 *)
  WriteCard(x, 0); WriteLn
END T40090ConstArrayIndex.
