MODULE T90164FpuIO;
(*
 * Group 90 — library / I/O
 * Test: the clean-room FpuIO module — fixed-format REAL/LONGREAL output and
 *       LONGINT output, delegating to the ISO real/long/whole modules. Field
 *       width pads, fraction width sets the decimal places.
 *
 * EXPECTED:
 * |    3.14|
 * |   2.5|
 * |   42|
 *)
FROM FpuIO IMPORT WriteReal, WriteLongReal, WriteLongInt;
FROM StrIO IMPORT WriteString, WriteLn;

BEGIN
  WriteString("|"); WriteReal(3.14, 8, 2); WriteString("|"); WriteLn;
  WriteString("|"); WriteLongReal(2.5, 6, 1); WriteString("|"); WriteLn;
  WriteString("|"); WriteLongInt(42, 5); WriteString("|"); WriteLn
END T90164FpuIO.
