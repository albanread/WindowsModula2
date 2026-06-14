MODULE T90190MinMaxOfVariable;
(*
 * Group 90 — builtins
 * Test: MIN(v) / MAX(v) accept a *variable* and yield the bounds of its type
 *       (here a [10..40] subrange), used both in a set constructor and printed.
 *
 * EXPECTED:
 * 10
 * 40
 *)
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteLn;

TYPE
  Subrange = [10..40];
  Set = SET OF Subrange;

VAR
  u: Subrange;
  s: Set;
BEGIN
  u := MIN(u);
  s := Set{u};
  WriteCard(u, 0); WriteLn;
  u := MAX(u);
  WriteCard(u, 0); WriteLn
END T90190MinMaxOfVariable.
