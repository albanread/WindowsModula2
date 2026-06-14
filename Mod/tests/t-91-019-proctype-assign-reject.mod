MODULE T91019ProctypeAssignReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * ProcB (taking INTEGER) does not match the procedure variable's type
 * PA = PROCEDURE (REAL).
 *)
TYPE
  PA = PROCEDURE (REAL);
VAR
  pa: PA;
PROCEDURE ProcB (x: INTEGER);
BEGIN
END ProcB;
BEGIN
  pa := ProcB
END T91019ProctypeAssignReject.
