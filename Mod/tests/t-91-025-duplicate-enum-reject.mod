MODULE T91025DupEnumReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * The enumeration member black is declared by two different enum types in
 * the same scope.
 *)
TYPE
  foo = (black, blue, green, red);
  bar = (black, white);
BEGIN
END T91025DupEnumReject.
