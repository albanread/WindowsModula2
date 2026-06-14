MODULE T90173MathLib0;
(*
 * Group 90 — library / math
 * Test: the clean-room MathLib0 module — `pi`, the trig/exp/sqrt functions
 *       (delegating to ISO RealMath), and `entier` (floor of a REAL as an
 *       INTEGER, including the negative-non-integer case).
 *
 * EXPECTED:
 * 2 -3 4 3
 *)
IMPORT MathLib0;
FROM SWholeIO IMPORT WriteInt;
FROM StrIO IMPORT WriteString, WriteLn;

BEGIN
  WriteInt(MathLib0.entier(2.7), 0); WriteString(" ");                 (* 2 *)
  WriteInt(MathLib0.entier(-2.3), 0); WriteString(" ");                (* -3 *)
  WriteInt(VAL(INTEGER, MathLib0.sqrt(16.0) + 0.5), 0); WriteString(" "); (* 4 *)
  WriteInt(MathLib0.entier(MathLib0.pi), 0); WriteLn                   (* 3 *)
END T90173MathLib0.
