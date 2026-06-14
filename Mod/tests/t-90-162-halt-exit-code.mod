MODULE T90162HaltExitCode;
(*
 * Group 90 — termination
 * Test: HALT(n) carries its argument as the process exit status. This module
 *       prints, then HALT(7) — a clean, reachable termination that still runs
 *       output. The companion Rust test asserts the status is 7.
 *
 * EXPECTED:
 * before-halt
 *)
FROM StrIO IMPORT WriteString, WriteLn;
BEGIN
  WriteString("before-halt"); WriteLn;
  HALT(7);
  WriteString("after-halt"); WriteLn   (* unreachable *)
END T90162HaltExitCode.
