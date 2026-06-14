MODULE T90168ConstAggregateForwardType;
(*
 * Group 90 — constants
 * Test: a CONST aggregate that references a TYPE declared *later* in the same
 *       declaration block (forward reference) folds with its proper aggregate
 *       type, so it stays assignable to a variable of that type.
 *
 * EXPECTED:
 * 12 34 56 78
 *)
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

CONST
  table = Pair{ Cell{12, 34}, Cell{56, 78} };   (* uses Cell/Pair declared below *)

TYPE
  Cell = RECORD a, b: CARDINAL END;
  Pair = ARRAY [0..1] OF Cell;

VAR
  p: Pair;

BEGIN
  p := table;
  WriteCard(p[0].a, 0); WriteString(" ");
  WriteCard(p[0].b, 0); WriteString(" ");
  WriteCard(p[1].a, 0); WriteString(" ");
  WriteCard(p[1].b, 0); WriteLn
END T90168ConstAggregateForwardType.
