MODULE T70020Finally;
(*
 * Group 70 — Exceptions
 * Test: FINALLY runs after normal completion of the protected region.
 *
 * EXPECTED:
 * work
 * cleanup
 *)
IMPORT STextIO;
BEGIN
  STextIO.WriteString("work");
  STextIO.WriteLn;
FINALLY
  STextIO.WriteString("cleanup");
  STextIO.WriteLn;
END T70020Finally.
