MODULE T91012CyclicTypeReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * A = B and B = A form an infinite pure-alias cycle (no pointer to break it).
 *)
TYPE
  A = B;
  B = A;
VAR
  x: A;
BEGIN
  x := x
END T91012CyclicTypeReject.
