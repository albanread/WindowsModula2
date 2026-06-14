MODULE T91022NilCallReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * NIL is a constant, not a procedure; NIL(c) attempts to call it.
 *)
VAR c: CARDINAL;
BEGIN
  NIL (c)
END T91022NilCallReject.
