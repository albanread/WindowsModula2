MODULE T90223WinrtFileFunc;
(*
 * Group 90 — M2WINRT: FileFunc, a binary file abstraction over the
 * Windows file W-APIs called DIRECTLY from M2 (CreateFileW/WriteFile/ReadFile/
 * SetFilePointerEx/GetFileSizeEx/CloseHandle/DeleteFileW). Creates a temp file,
 * writes 'A'..'P', reads it back and verifies, checks the size, seeks to byte 4
 * and reads ('E'=69..'H'=72), then deletes it (self-cleaning).
 *
 * EXPECTED:
 * create valid: Y
 * write n=16
 * size=16
 * read n=16
 * match: Y
 * seek-read: 69 72
 * delete: Y
 * exists-after: N
 *)
FROM SYSTEM IMPORT ADR;
FROM FileFunc IMPORT File, IsValid, Create, OpenRead, Close, WriteBytes,
  ReadBytes, Size, Seek, Delete, Exists;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

CONST Path = "m2winrt_file.tmp";
VAR f: File; wbuf, rbuf, sbuf: ARRAY [0..15] OF BYTE; i, n: CARDINAL; match: BOOLEAN;
BEGIN
  FOR i := 0 TO 15 DO wbuf[i] := VAL(BYTE, 65 + i) END;
  f := Create(Path);
  WriteString("create valid: "); YN(IsValid(f)); WriteLn;
  n := WriteBytes(f, ADR(wbuf), 16);
  WriteString("write n="); WriteCard(n, 1); WriteLn;
  Close(f);
  f := OpenRead(Path);
  WriteString("size="); WriteCard(Size(f), 1); WriteLn;
  n := ReadBytes(f, ADR(rbuf), 16);
  WriteString("read n="); WriteCard(n, 1); WriteLn;
  match := TRUE;
  FOR i := 0 TO 15 DO IF wbuf[i] # rbuf[i] THEN match := FALSE END END;
  WriteString("match: "); YN(match); WriteLn;
  IF Seek(f, 4) THEN END;
  n := ReadBytes(f, ADR(sbuf), 4);
  WriteString("seek-read: "); WriteCard(ORD(sbuf[0]), 1); WriteString(" ");
  WriteCard(ORD(sbuf[3]), 1); WriteLn;
  Close(f);
  WriteString("delete: "); YN(Delete(Path)); WriteLn;
  WriteString("exists-after: "); YN(Exists(Path)); WriteLn
END T90223WinrtFileFunc.
