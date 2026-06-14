MODULE T90150M2rtsLocBuiltins;
(*
 * Group 90 — interop / runtime
 * Test: the location builtins __LINE__ / __FILE__ / __FUNCTION__ and the
 *       clean-room M2RTS module (Length). The assert pattern (Halt on failure)
 *       compiles; passing asserts never call Halt.
 *
 * EXPECTED:
 * 5
 * asserts-ok
 *)
FROM M2RTS IMPORT Length, Halt, ExitOnHalt;
FROM StrIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;

PROCEDURE Assert (b: BOOLEAN; line: CARDINAL);
BEGIN
  IF NOT b THEN
    Halt("assertion failed", __FILE__, __FUNCTION__, line)
  END
END Assert;

BEGIN
  ExitOnHalt(0);
  WriteCard(Length("hello"), 0); WriteLn;        (* 5 *)
  Assert(Length("abcd") = 4, __LINE__);
  Assert(Length("") = 0, __LINE__);
  WriteString("asserts-ok"); WriteLn
END T90150M2rtsLocBuiltins.
