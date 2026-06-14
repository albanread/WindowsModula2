MODULE T90166BuiltinsMath;
(*
 * Group 90 — library / math
 * Test: the clean-room Builtins math subset (LONGREAL `l`-suffixed GCC
 *       intrinsics) delegating to ISO LongMath. Results rounded to integers
 *       to keep the expectation exact.
 *
 * EXPECTED:
 * 3 7 1024 12
 *)
FROM Builtins IMPORT log10l, fabsl, powl, sqrtl;
FROM SWholeIO IMPORT WriteInt;
FROM StrIO IMPORT WriteString, WriteLn;

BEGIN
  WriteInt(VAL(INTEGER, log10l(1000.0) + 0.5), 0); WriteString(" ");   (* 3 *)
  WriteInt(VAL(INTEGER, fabsl(-7.0)), 0); WriteString(" ");            (* 7 *)
  WriteInt(VAL(INTEGER, powl(2.0, 10.0) + 0.5), 0); WriteString(" ");  (* 1024 *)
  WriteInt(VAL(INTEGER, sqrtl(144.0) + 0.5), 0); WriteLn               (* 12 *)
END T90166BuiltinsMath.
