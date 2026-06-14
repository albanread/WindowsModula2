MODULE T90221WinrtEnvironment;
(*
 * Group 90 — M2WINRT: Environment, a Win32-helper module.
 * Calls the Windows W-APIs DIRECTLY from M2 (Get/SetEnvironmentVariableW,
 * GetModuleFileNameW, GetCommandLineW) — NewM2's 16-bit CHAR is WCHAR, so an
 * ARRAY OF CHAR is the wide-string buffer. Assertions are machine-independent
 * (round-trip a var; removed/missing vars report not-found; exe-path and
 * command-line succeed and are non-empty).
 *
 * EXPECTED:
 * set: Y
 * get: Y [round-trip-value]
 * after-remove: N
 * missing: N
 * OS present: Y
 * exepath: Y Y
 * cmdline nonempty: Y
 *)
FROM Environment IMPORT GetVar, SetVar, RemoveVar, GetExePath, GetCommandLine;
FROM StrIO IMPORT WriteString, WriteLn;

CONST NUL = CHR(0);
VAR v: ARRAY [0..511] OF CHAR; ok: BOOLEAN;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

BEGIN
  ok := SetVar("M2WINRT_E", "round-trip-value");
  WriteString("set: "); YN(ok); WriteLn;
  ok := GetVar("M2WINRT_E", v);
  WriteString("get: "); YN(ok); WriteString(" ["); WriteString(v); WriteString("]"); WriteLn;
  ok := RemoveVar("M2WINRT_E"); ok := GetVar("M2WINRT_E", v);
  WriteString("after-remove: "); YN(ok); WriteLn;
  ok := GetVar("NO_SUCH_VAR_XYZ_123", v);
  WriteString("missing: "); YN(ok); WriteLn;
  ok := GetVar("OS", v);
  WriteString("OS present: "); YN(ok); WriteLn;
  ok := GetExePath(v);
  WriteString("exepath: "); YN(ok); WriteString(" "); YN(v[0] # NUL); WriteLn;
  GetCommandLine(v);
  WriteString("cmdline nonempty: "); YN(v[0] # NUL); WriteLn
END T90221WinrtEnvironment.
