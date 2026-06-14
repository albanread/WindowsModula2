MODULE T90230WinrtGuid;
(*
 * Group 90 — M2WINRT: Guid, COM GUID/CLSID parse/format/ProgID over
 * ole32 (direct from M2). Parses CLSID_ShellLink, round-trips it through
 * ToString, compares GUIDs, rejects a malformed string, and resolves a ProgID
 * present on all Windows (Scripting.FileSystemObject).
 *
 * EXPECTED:
 * parse: Y
 * {00021401-0000-0000-C000-000000000046}
 * equal-same: Y
 * equal-diff: N
 * bad-parse: N
 * progid: Y
 *)
FROM SYSTEM IMPORT ADR;
FROM Guid IMPORT FromString, ToString, FromProgID, Equal;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR g1, g2, clsid: ARRAY [0..15] OF BYTE; s: ARRAY [0..63] OF CHAR; ok: BOOLEAN;
BEGIN
  ok := FromString("{00021401-0000-0000-C000-000000000046}", g1);
  WriteString("parse: "); YN(ok); WriteLn;
  IF ToString(g1, s) THEN WriteString(s) END; WriteLn;
  ok := FromString("{00021401-0000-0000-C000-000000000046}", g2);
  WriteString("equal-same: "); YN(Equal(ADR(g1), ADR(g2))); WriteLn;
  ok := FromString("{00020400-0000-0000-C000-000000000046}", g2);
  WriteString("equal-diff: "); YN(Equal(ADR(g1), ADR(g2))); WriteLn;
  WriteString("bad-parse: "); YN(FromString("not-a-guid", g2)); WriteLn;
  WriteString("progid: "); YN(FromProgID("Scripting.FileSystemObject", clsid)); WriteLn
END T90230WinrtGuid.
