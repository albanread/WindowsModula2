MODULE T91017InclElementReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * INCL's element must match the set's base type; FALSE (BOOLEAN) is not a
 * BITSET element.
 *)
VAR
  s: BITSET;
BEGIN
  s := {};
  INCL(s, FALSE)
END T91017InclElementReject.
