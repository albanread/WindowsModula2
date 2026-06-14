MODULE T90242FileMap;
(*
 * Group 90 — Win32 helper library: FileMap (clean-room recreation). Memory-
 * mapped file access in pure M2 over direct Win32 (CreateFileMappingW /
 * OpenFileMappingW / MapViewOfFile / UnmapViewOfFile). This drives the most
 * telling path: a *named*, page-file-backed mapping created by one MappedFile
 * and OPENED by a second — writing through the first view and reading the same
 * bytes through the second proves the mapping object is genuinely shared.
 *
 * EXPECTED:
 * created: Y
 * mapped1: Y
 * opened: Y
 * shared read: Y
 * closed: Y
 *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM FileMap IMPORT MappedFile, FileMapResults, FileMapCreated, FileMapOpened,
  MapMode, MapReadWrite, CreateFileMap, CloseFileMap, MapFileView;
FROM StrIO IMPORT WriteString, WriteLn;

TYPE CardPtr = POINTER TO CARDINAL;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR mf1, mf2: MappedFile; r1, r2: FileMapResults; p1, p2: ADDRESS; pc: CardPtr; ok: BOOLEAN;
BEGIN
  r1 := CreateFileMap(mf1, "", "NewM2FileMapTest", MapReadWrite, 4096);
  WriteString("created: "); YN(r1 = FileMapCreated); WriteLn;
  p1 := MapFileView(mf1, 0, 0);
  WriteString("mapped1: "); YN(p1 # NIL); WriteLn;
  pc := CAST(CardPtr, p1); pc^ := 0DEADBEEFH;          (* write through view 1 *)

  r2 := CreateFileMap(mf2, "", "NewM2FileMapTest", MapReadWrite, 4096);
  WriteString("opened: "); YN(r2 = FileMapOpened); WriteLn;
  p2 := MapFileView(mf2, 0, 0);
  pc := CAST(CardPtr, p2);                              (* read through view 2 *)
  WriteString("shared read: "); YN(pc^ = 0DEADBEEFH); WriteLn;

  ok := CloseFileMap(mf2); ok := CloseFileMap(mf1);
  WriteString("closed: "); YN(ok); WriteLn
END T90242FileMap.
