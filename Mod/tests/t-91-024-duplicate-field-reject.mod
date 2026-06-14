MODULE T91024DupFieldReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * The record field f is declared twice.
 *)
TYPE
  t = RECORD
        f: CARDINAL;
        f: INTEGER;
      END;
VAR i: t;
BEGIN
  i.f := 0
END T91024DupFieldReject.
