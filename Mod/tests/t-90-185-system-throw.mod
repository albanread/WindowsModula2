MODULE T90185SystemThrow;
(*
 * Group 90 — SYSTEM / exceptions
 * Test: SYSTEM.THROW(n) raises an exception that an enclosing EXCEPT handler
 *       catches; the statement after THROW is not reached.
 *
 * EXPECTED:
 * before
 * caught
 *)
FROM SYSTEM IMPORT THROW;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE risky;
BEGIN
  WriteString("before"); WriteLn;
  THROW(1);
  WriteString("after — not reached"); WriteLn
EXCEPT
  WriteString("caught"); WriteLn
END risky;

BEGIN
  risky
END T90185SystemThrow.
