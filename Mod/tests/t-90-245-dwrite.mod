MODULE T90245DWrite;
(*
 * Group 90 — modern Terminal rendering foundation: DirectWrite reachable from
 * pure M2. Creates the DWrite factory (DWriteCreateFactory + IID via Guid) and a
 * monospaced text format, consuming IDWriteFactory through the CLASS-as-COM
 * vtable pattern. Critically this also proves a FLOAT argument (the font size)
 * passes correctly through a virtual COM call — the enabler for Direct2D/
 * DirectWrite rendering from M2.
 *
 * EXPECTED:
 * startup: Y
 * format: Y
 *)
FROM DWrite IMPORT Startup, CreateFormat;
FROM SYSTEM IMPORT ADDRESS;
FROM StrIO IMPORT WriteString, WriteLn;
PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;
VAR ok: BOOLEAN; fmt: ADDRESS;
BEGIN
  ok := Startup();
  WriteString("startup: "); YN(ok); WriteLn;
  fmt := CreateFormat("Consolas", VAL(SHORTREAL, 14.0));
  WriteString("format: "); YN(fmt # NIL); WriteLn
END T90245DWrite.
