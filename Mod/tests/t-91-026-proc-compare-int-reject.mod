MODULE T91026ProcCompareIntReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * A procedure-typed value may only be compared with another procedure or
 * NIL; comparing it with an integer (x = 0) is a type error.
 *)
TYPE xProc = PROCEDURE(): BOOLEAN;
VAR x: xProc;
BEGIN
  IF x = 0 THEN END
END T91026ProcCompareIntReject.
