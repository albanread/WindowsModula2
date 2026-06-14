MODULE T30020ImportModule;
(*
 * Group 30 — Strings / I/O / module loading
 * Test: imports a sibling helper module from Mod/tests and calls its code.
 *
 * EXPECTED:
 * 17
 * 22
 *)
FROM T30020Helper IMPORT Base, WriteValue;

BEGIN
  WriteValue(Base);
  WriteValue(Base + 5);
END T30020ImportModule.