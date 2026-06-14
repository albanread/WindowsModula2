MODULE T91011CaseDuplicateReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * The CASE label 1 is selected by two arms (duplicate / overlapping label).
 *)
FROM StrIO IMPORT WriteString;
VAR c: CARDINAL;
BEGIN
  c := 2;
  CASE c OF
  1: WriteString("one") |
  2: WriteString("two") |
  1: WriteString("mistake")
  ELSE
  END
END T91011CaseDuplicateReject.
