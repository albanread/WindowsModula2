MODULE T91014ArrayLengthMismatchReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * Arrays of different lengths are not assignment-compatible.
 *)
VAR
  a: ARRAY [0..3] OF REAL;
  b: ARRAY [0..4] OF REAL;
BEGIN
  a := b
END T91014ArrayLengthMismatchReject.
