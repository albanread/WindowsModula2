MODULE T91010SubrangeRangeReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * A constant assigned to a subrange variable must lie within the subrange;
 * 9 is outside [10..20].
 *)
TYPE
  foo = [10..20];
VAR
  c: foo;
BEGIN
  c := 9
END T91010SubrangeRangeReject.
