MODULE T90187LocalModuleImport;
(*
 * Group 90 — local modules
 * Test: a nested LOCAL MODULE imports a procedure and a variable from the
 *       enclosing scope (PIM semantics — `IMPORT WriteString` names a
 *       surrounding symbol, not a separate compilation unit) and EXPORTs a
 *       procedure back to the enclosing scope.
 *
 * EXPECTED:
 * outer
 * inner 7
 *)
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR n: CARDINAL;

PROCEDURE run;
  MODULE inner;
  IMPORT WriteString, WriteLn, WriteCard, n;
  EXPORT show;
  PROCEDURE show;
  BEGIN
    WriteString("inner "); WriteCard(n, 0); WriteLn
  END show;
  BEGIN
  END inner;
BEGIN
  show
END run;

BEGIN
  n := 7;
  WriteString("outer"); WriteLn;
  run
END T90187LocalModuleImport.
