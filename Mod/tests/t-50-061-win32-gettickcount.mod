MODULE T50061Win32GetTickCount;
(* Win32 API proof through the generated library/NewM2 defs: GetTickCount
   (KERNEL32.dll) returns milliseconds since boot. A real call returns a
   non-zero, monotonically non-decreasing value — better proof than Beep, whose
   result is just TRUE.

   EXPECTED:
   ok
*)
FROM WIN32 IMPORT DWORD;
FROM System_SystemInformation IMPORT GetTickCount;
FROM StrIO IMPORT WriteString, WriteLn;

VAR a, b: DWORD;
BEGIN
  a := GetTickCount();
  b := GetTickCount();
  IF (a # 0) AND (b >= a) THEN
    WriteString("ok")
  ELSE
    WriteString("bad")
  END;
  WriteLn
END T50061Win32GetTickCount.
