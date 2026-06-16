IMPLEMENTATION MODULE DirIter;

(* FindFirstFileW fills a WIN32_FIND_DATAW (~592 bytes on x64). The generated
   record collapses its inline WCHAR[260] cFileName to a pointer, so it is BOTH
   undersized and wrongly laid out — we back the call with an oversized opaque
   buffer and read fields at the real x64 offsets:
     dwFileAttributes  @ 0   (DWORD)
     nFileSizeHigh     @ 28  (DWORD)
     nFileSizeLow      @ 32  (DWORD)
     cFileName[260]    @ 44  (WCHAR == our 16-bit CHAR) *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM WIN32 IMPORT HANDLE, PWSTR, BOOL, DWORD;
FROM Storage_FileSystem IMPORT FindFirstFileW, FindNextFileW, FindClose;

CONST
  FILE_ATTR_DIR = 16;                    (* FILE_ATTRIBUTE_DIRECTORY *)
  INVALID       = 0FFFFFFFFFFFFFFFFH;    (* INVALID_HANDLE_VALUE = (HANDLE)-1 *)
  OffAttr   = 0;
  OffSizeHi = 28;
  OffSizeLo = 32;
  OffName   = 44;
  MaxIdx    = 1023;

TYPE
  Iter = POINTER TO IRec;
  IRec = RECORD handle: ADDRESS; pending: BOOLEAN; buf: ARRAY [0..1023] OF BYTE END;
  PDword = POINTER TO DWORD;
  PChars = POINTER TO ARRAY [0..MaxIdx] OF CHAR;

PROCEDURE Off (a: ADDRESS; n: CARDINAL): ADDRESS;
BEGIN RETURN CAST(ADDRESS, CAST(CARDINAL, a) + n) END Off;

PROCEDURE GetDword (base: ADDRESS; off: CARDINAL): CARDINAL;
  VAR p: PDword;
BEGIN p := CAST(PDword, Off(base, off)); RETURN VAL(CARDINAL, p^) END GetDword;

(* copy the UTF-16 cFileName at base+off into name (always NUL-terminated) *)
PROCEDURE GetName (base: ADDRESS; off: CARDINAL; VAR name: ARRAY OF CHAR);
  VAR p: PChars; i: CARDINAL;
BEGIN
  p := CAST(PChars, Off(base, off)); i := 0;
  WHILE (p^[i] # 0C) AND (i < HIGH(name)) DO name[i] := p^[i]; INC(i) END;
  name[i] := 0C
END GetName;

PROCEDURE IsDot (VAR name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF name[0] # '.' THEN RETURN FALSE END;
  IF name[1] = 0C THEN RETURN TRUE END;                 (* "." *)
  RETURN (name[1] = '.') AND (name[2] = 0C)             (* ".." *)
END IsDot;

PROCEDURE Open (dir: ARRAY OF CHAR; VAR it: Iter): BOOLEAN;
  VAR pat: ARRAY [0..1023] OF CHAR; p: Iter; a: ADDRESS; i: CARDINAL;
BEGIN
  it := NIL;
  (* build "<dir>\*" as a wide (UTF-16) string *)
  i := 0;
  WHILE (i <= HIGH(dir)) AND (dir[i] # 0C) AND (i < HIGH(pat) - 3) DO pat[i] := dir[i]; INC(i) END;
  IF (i > 0) AND (pat[i-1] # '\') AND (pat[i-1] # '/') THEN pat[i] := '\'; INC(i) END;
  pat[i] := '*'; INC(i); pat[i] := 0C;

  a := NIL; ALLOCATE(a, SIZE(IRec)); p := CAST(Iter, a);
  p^.handle := FindFirstFileW(CAST(PWSTR, ADR(pat)), ADR(p^.buf));
  IF CAST(CARDINAL, p^.handle) = INVALID THEN
    a := CAST(ADDRESS, p); DEALLOCATE(a, SIZE(IRec)); RETURN FALSE
  END;
  p^.pending := TRUE;
  it := p; RETURN TRUE
END Open;

PROCEDURE Next (it: Iter; VAR name: ARRAY OF CHAR; VAR isDir: BOOLEAN; VAR size: CARDINAL): BOOLEAN;
  VAR base: ADDRESS; attrs, hi, lo: CARDINAL; b: BOOL;
BEGIN
  base := ADR(it^.buf);
  WHILE it^.pending DO
    attrs := GetDword(base, OffAttr);
    GetName(base, OffName, name);
    hi := GetDword(base, OffSizeHi); lo := GetDword(base, OffSizeLo);
    (* advance to the next entry *)
    b := FindNextFileW(it^.handle, ADR(it^.buf));
    it^.pending := b # 0;
    IF NOT IsDot(name) THEN
      isDir := (attrs BAND FILE_ATTR_DIR) # 0;
      size := hi * 100000000H + lo;
      RETURN TRUE
    END
  END;
  RETURN FALSE
END Next;

PROCEDURE Close (VAR it: Iter);
  VAR a: ADDRESS; b: BOOL;
BEGIN
  IF it # NIL THEN
    b := FindClose(it^.handle);
    a := CAST(ADDRESS, it); DEALLOCATE(a, SIZE(IRec)); it := NIL
  END
END Close;

END DirIter.
