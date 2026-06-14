MODULE T60018BitsetConstructor;
(*
 * Group 60 — Sets
 * Test: an explicitly-typed BITSET constructor with integer elements,
 *       `BITSET{3, 5}`, type-checks (its elements are whole numbers) and
 *       evaluates correctly.
 *
 * EXPECTED:
 * ctor-ok
 *)
FROM STextIO IMPORT WriteString, WriteLn;

VAR x: BITSET;

BEGIN
  x := BITSET{3, 5} + BITSET{7};
  IF (3 IN x) AND (5 IN x) AND (7 IN x) AND NOT (4 IN x)
  THEN WriteString("ctor-ok") END; WriteLn
END T60018BitsetConstructor.
