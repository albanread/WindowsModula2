MODULE T60017BitsetArith;
(*
 * Group 60 — Sets
 * Test: set arithmetic directly on BITSET variables (the pervasive set
 *       type) — union, difference, intersection — not just SET OF [..]
 *       custom types or set literals.
 *
 * EXPECTED:
 * union-ok
 * diff-ok
 * inter-ok
 *)
FROM STextIO IMPORT WriteString, WriteLn;

VAR b, c: BITSET;

BEGIN
  b := {1, 2} + {5..6};
  c := {3, 4};
  b := b + c;                                            (* union *)
  IF (1 IN b) AND (4 IN b) AND (6 IN b) AND NOT (0 IN b)
  THEN WriteString("union-ok") END; WriteLn;
  b := b - c;                                            (* difference *)
  IF (1 IN b) AND NOT (3 IN b) THEN WriteString("diff-ok") END; WriteLn;
  b := b * {1, 2};                                       (* intersection *)
  IF (1 IN b) AND NOT (5 IN b) THEN WriteString("inter-ok") END; WriteLn
END T60017BitsetArith.
