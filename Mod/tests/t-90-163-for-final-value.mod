MODULE T90163ForFinalValue;
(*
 * Group 90 — control flow
 * Test: after a FOR loop, the control variable is left at its LAST in-range
 *       value (ISO), not the overshoot value. Covers an ascending step
 *       that does not land on the limit, a descending step, an exact landing,
 *       an empty loop, and a single iteration.
 *
 * EXPECTED:
 * asc 95 1176
 * desc 2 7
 * exact 10 3
 * empty 5 0
 * single 7 1
 *)
FROM SWholeIO IMPORT WriteInt;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE Report (tag: ARRAY OF CHAR; i, c: INTEGER);
BEGIN
  WriteString(tag); WriteString(" ");
  WriteInt(i, 0); WriteString(" "); WriteInt(c, 0); WriteLn
END Report;

VAR
  i, c: INTEGER;
BEGIN
  c := 0; FOR i := 3 TO 96 BY 4 DO INC(c, i) END;   (* last in-range 95 *)
  Report("asc", i, c);
  c := 0; FOR i := 20 TO 2 BY -3 DO INC(c) END;      (* 20..2 step -3 -> 2 *)
  Report("desc", i, c);
  c := 0; FOR i := 0 TO 10 BY 5 DO INC(c) END;       (* lands on 10 *)
  Report("exact", i, c);
  c := 0; FOR i := 5 TO 2 DO INC(c) END;             (* empty -> i = start *)
  Report("empty", i, c);
  c := 0; FOR i := 7 TO 7 DO INC(c) END;             (* single iteration *)
  Report("single", i, c)
END T90163ForFinalValue.
