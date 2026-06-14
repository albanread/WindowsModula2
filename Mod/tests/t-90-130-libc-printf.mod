MODULE T90130LibcPrintf;
(*
 * Group 90 — interop / runtime
 * Test: the simulated `libc` module — `printf` (variadic) writes its format
 *       string; extra (variadic) arguments are accepted by the ABI.
 *
 * EXPECTED:
 * one
 * two
 *)
FROM libc IMPORT printf;
FROM STextIO IMPORT WriteLn;

VAR r: INTEGER;

BEGIN
  r := printf("one");                 (* single argument *)
  WriteLn;
  r := printf("two", 1, 2, 3);        (* variadic extra args accepted *)
  WriteLn
END T90130LibcPrintf.
