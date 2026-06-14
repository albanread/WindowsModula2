MODULE T91020SizeLiteralReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * SIZE requires a type name or a variable; SIZE(1) takes the size of a
 * literal, which is a type error.
 *)
FROM SYSTEM IMPORT SIZE;
VAR c: CARDINAL;
BEGIN
  c := SIZE(1)
END T91020SizeLiteralReject.
