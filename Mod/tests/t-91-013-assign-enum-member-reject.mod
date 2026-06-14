MODULE T91013AssignEnumMemberReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * `red` is an enumeration member (a constant); it cannot be assigned to.
 *)
TYPE
  colour = (red, blue, green);
BEGIN
  red := 1
END T91013AssignEnumMemberReject.
