MODULE T90172SetShiftRotate;
(*
 * Group 90 — SYSTEM / sets
 * Test: SHIFT and ROTATE on a BITSET operand. A set is an i256 bitmask; the
 *       result must stay a set value, not the corrupted output of an i256/i64
 *       ABI mismatch. ROTATE(BITSET{1}, 1) = BITSET{2}; SHIFT(BITSET{0,1}, 2)
 *       moves bits 0,1 to 2,3.
 *
 * EXPECTED:
 * rotate-ok
 * shift-ok
 *)
FROM SYSTEM IMPORT SHIFT, ROTATE;
FROM StrIO IMPORT WriteString, WriteLn;

VAR
  a, b: BITSET;

BEGIN
  b := ROTATE(BITSET{1}, 1);
  IF (2 IN b) AND NOT (1 IN b) THEN
    WriteString("rotate-ok")
  ELSE
    WriteString("rotate-bad")
  END;
  WriteLn;

  a := SHIFT(BITSET{0, 1}, 2);
  IF (2 IN a) AND (3 IN a) AND NOT (0 IN a) AND NOT (1 IN a) THEN
    WriteString("shift-ok")
  ELSE
    WriteString("shift-bad")
  END;
  WriteLn
END T90172SetShiftRotate.
