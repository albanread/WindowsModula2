MODULE T91027SetInSetReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * The left operand of IN must be an element; `setvar IN setvar` puts a set
 * on the left.
 *)
TYPE
  enums = (red, blue, green);
  set = SET OF enums;
VAR setvar: set;
BEGIN
  setvar := set{red, blue};
  IF NOT (setvar IN setvar) THEN HALT END
END T91027SetInSetReject.
