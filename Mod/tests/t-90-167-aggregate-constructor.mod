MODULE T90167AggregateConstructor;
(*
 * Group 90 — constructors
 * Test: structured aggregate constructors `T{...}` for RECORD and ARRAY types
 *       with runtime (non-constant) element values must be analysed as
 *       structured aggregates, not set constructors.
 *
 * EXPECTED:
 * 1623 6 19
 * 10 20 30
 *)
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

TYPE
  Date = RECORD year, month, day: CARDINAL END;
  Triple = ARRAY [0..2] OF CARDINAL;

VAR
  d: Date;
  t: Triple;
  y, m, day, a, b, c: CARDINAL;

BEGIN
  y := 1623; m := 6; day := 19;
  d := Date{y, m, day};                 (* record constructor, runtime values *)
  WriteCard(d.year, 0); WriteString(" ");
  WriteCard(d.month, 0); WriteString(" ");
  WriteCard(d.day, 0); WriteLn;

  a := 10; b := 20; c := 30;
  t := Triple{a, b, c};                 (* array constructor, runtime values *)
  WriteCard(t[0], 0); WriteString(" ");
  WriteCard(t[1], 0); WriteString(" ");
  WriteCard(t[2], 0); WriteLn
END T90167AggregateConstructor.
