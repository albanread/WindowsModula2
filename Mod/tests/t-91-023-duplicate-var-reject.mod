MODULE T91023DupVarReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * The variable x is declared twice in the same scope.
 *)
VAR
  x: CARDINAL;
  x: INTEGER;
BEGIN
  x := 0
END T91023DupVarReject.
