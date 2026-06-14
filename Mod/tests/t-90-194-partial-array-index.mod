MODULE T90194PartialArrayIndex;
(*
 * Group 90 — arrays
 * Test: indexing a multi-dimensional array with fewer indices than dimensions
 *       yields a lower-rank sub-array. `m[r]` is a row; chained and mixed
 *       indexing must all reach the same element as full indexing.
 *
 * EXPECTED:
 * 7
 * ok
 *)
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

VAR
  m: ARRAY [0..2], [0..3] OF CARDINAL;
  ok: BOOLEAN;
BEGIN
  m[1, 2] := 7;
  WriteCard(m[1][2], 0); WriteLn;          (* chained partial reaches m[1,2] *)
  ok := (m[1][2] = m[1, 2]) AND (m[1][2] = 7);
  IF ok THEN WriteString("ok") ELSE WriteString("bad") END;
  WriteLn
END T90194PartialArrayIndex.
