MODULE T90193AggregateOpenArrayArg;
(*
 * Group 90 — parameters
 * Test: an aggregate constructor passed directly to an open `ARRAY OF` value
 *       parameter is spilled to a slot so the open-array (ptr, HIGH) ABI gets a
 *       data pointer, not the array value's bits.
 *
 * EXPECTED:
 * 5
 * 10
 * 15
 *)
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteLn;

TYPE Vector = ARRAY [0..2] OF CARDINAL;

PROCEDURE sumScale (v: ARRAY OF CARDINAL; k: CARDINAL; VAR r: ARRAY OF CARDINAL);
VAR h: CARDINAL;
BEGIN
  FOR h := 0 TO HIGH(v) DO r[h] := v[h] * k END
END sumScale;

VAR r: Vector;
BEGIN
  sumScale(Vector{1, 2, 3}, 5, r);
  WriteCard(r[0], 0); WriteLn;
  WriteCard(r[1], 0); WriteLn;
  WriteCard(r[2], 0); WriteLn
END T90193AggregateOpenArrayArg.
