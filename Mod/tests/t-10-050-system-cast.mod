MODULE T10050SystemCast;
(*
 * Group 10 — Arithmetic / conversions
 * Test: qualified SYSTEM.CAST accepts a type-name first argument.
 *)
IMPORT SYSTEM;

VAR
  src: INTEGER;
  wide: INTEGER64;

BEGIN
  src := 17;
  wide := SYSTEM.CAST(INTEGER64, src);
END T10050SystemCast.