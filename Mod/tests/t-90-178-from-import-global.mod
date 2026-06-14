MODULE T90178FromImportGlobal;
(*
 * Group 90 — modules / codegen
 * Test: a FROM-imported module variable resolves to the *defining module's*
 *       global, for both reads and writes — the unqualified name must resolve
 *       to the defining module, not the importing one.
 *       Reads InOut.Done (initialised TRUE by InOut), writes it, reads it back.
 *
 * EXPECTED:
 * t f
 *)
FROM InOut IMPORT Done;
FROM StrIO IMPORT WriteString, WriteLn;

BEGIN
  IF Done THEN WriteString("t") ELSE WriteString("f") END;   (* t — InOut set it *)
  WriteString(" ");
  Done := FALSE;                                             (* write the global *)
  IF Done THEN WriteString("t") ELSE WriteString("f") END;   (* f *)
  WriteLn
END T90178FromImportGlobal.
