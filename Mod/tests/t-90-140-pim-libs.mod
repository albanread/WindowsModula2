MODULE T90140PimLibs;
(*
 * Group 90 — interop / runtime
 * Test: the clean-room PIM library modules StrIO, StrLib, NumberIO (delegating
 *       to ISO STextIO / Strings / SWholeIO / WholeStr).
 *
 * EXPECTED:
 * pim libs
 * equal
 * 5
 * 42
 *)
FROM StrIO IMPORT WriteString, WriteLn;
FROM StrLib IMPORT StrEqual, StrLen;
FROM NumberIO IMPORT CardToStr;

VAR buf: ARRAY [0..20] OF CHAR;

BEGIN
  WriteString("pim libs"); WriteLn;
  IF StrEqual("abc", "abc") THEN WriteString("equal") END; WriteLn;
  CardToStr(StrLen("hello"), 0, buf);   (* 5 *)
  WriteString(buf); WriteLn;
  CardToStr(42, 0, buf);
  WriteString(buf); WriteLn
END T90140PimLibs.
