MODULE T91018ForStepReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * The FOR-loop BY step must be a constant; here it is a variable.
 *)
VAR
  i, s: CARDINAL;
BEGIN
  s := 2;
  FOR i := 1 TO 10 BY s DO END
END T91018ForStepReject.
