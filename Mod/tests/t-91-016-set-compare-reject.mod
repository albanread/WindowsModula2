MODULE T91016SetCompareReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * A set may only be compared with a set; `c = s` compares CARDINAL with a set.
 *)
VAR
  s: SET OF [1..10];
  c: CARDINAL;
BEGIN
  s := SET OF [1..10]{1};
  IF c = s THEN END
END T91016SetCompareReject.
