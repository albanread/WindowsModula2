MODULE T90198EnumTypeImportMembers;
(*
 * Group 90 — imports
 * Test: `FROM M IMPORT EnumType` makes the enumeration's member constants
 *       visible without importing each by name (ISO semantics). Here only the
 *       type `Result` is imported, yet `opened` and `failed` are usable.
 *
 * EXPECTED:
 * yes
 * no
 *)
FROM T90EnumLib IMPORT Result, classify;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE report (r: Result);
BEGIN
  IF r = opened THEN WriteString("yes") ELSE WriteString("no") END;
  WriteLn
END report;

BEGIN
  report(classify(1));   (* opened -> yes *)
  report(classify(0))    (* failed -> no  *)
END T90198EnumTypeImportMembers.
