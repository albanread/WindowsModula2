MODULE T90176ModuleGlobalVar;
(*
 * Group 90 — modules / codegen
 * Test: reading an exported variable declared in another module's DEFINITION
 *       across the JIT module boundary. InOut.Done is initialised to TRUE by
 *       InOut's module body; this module reads it cross-module.
 *
 * EXPECTED:
 * done
 *)
IMPORT InOut;
FROM StrIO IMPORT WriteString, WriteLn;

BEGIN
  IF InOut.Done THEN
    WriteString("done")
  ELSE
    WriteString("not-done")
  END;
  WriteLn
END T90176ModuleGlobalVar.
