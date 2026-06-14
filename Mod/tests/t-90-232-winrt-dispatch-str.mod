MODULE T90232WinrtDispatchStr;
(*
 * Group 90 — M2WINRT: Dispatch string marshalling. Late-bound
 * IDispatch method calls WITH a string argument returning a string (BSTR)
 * result — the common Automation case. Drives the real Scripting.FileSystemObject:
 * GetExtensionName("archive.tar.gz") = "gz" and GetBaseName of a path = "report".
 * Exercises SysAllocString/SysFreeString, a VT_BSTR VARIANT argument, and BSTR
 * result extraction.
 *
 * EXPECTED:
 * create: Y
 * gz
 * report
 *)
FROM SYSTEM IMPORT ADR;
FROM Com IMPORT Initialize, Uninitialize, CreateInstance;
FROM Guid IMPORT FromString, FromProgID;
FROM Dispatch IMPORT InvokeStr1;
FROM StrIO IMPORT WriteString, WriteLn;

VAR clsid, iidDisp: ARRAY [0..15] OF BYTE; obj: ADDRESS; r: ARRAY [0..255] OF CHAR; ok: BOOLEAN;
BEGIN
  ok := Initialize();
  ok := FromProgID("Scripting.FileSystemObject", clsid);
  ok := FromString("{00020400-0000-0000-C000-000000000046}", iidDisp);
  ok := CreateInstance(ADR(clsid), ADR(iidDisp), obj);
  WriteString("create: "); IF ok THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;
  IF InvokeStr1(obj, "GetExtensionName", "archive.tar.gz", r) THEN WriteString(r) ELSE WriteString("?") END; WriteLn;
  IF InvokeStr1(obj, "GetBaseName", "C:\dir\report.docx", r) THEN WriteString(r) ELSE WriteString("?") END; WriteLn;
  Uninitialize()
END T90232WinrtDispatchStr.
