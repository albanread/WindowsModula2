IMPLEMENTATION MODULE FileFunc;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM Storage_FileSystem IMPORT
  CreateFileW, ReadFile, WriteFile, DeleteFileW, GetFileSizeEx, SetFilePointerEx;
FROM Foundation IMPORT CloseHandle;
FROM WIN32 IMPORT DWORD, BOOL, HANDLE;

CONST
  GENERIC_READ          = 80000000H;
  GENERIC_WRITE         = 40000000H;
  AccessRW              = 0C0000000H;   (* GENERIC_READ BOR GENERIC_WRITE *)
  FILE_SHARE_READ       = 1;
  CREATE_ALWAYS         = 2;
  OPEN_EXISTING         = 3;
  FILE_ATTRIBUTE_NORMAL = 80H;
  FILE_BEGIN            = 0;

PROCEDURE IsValid (f: File): BOOLEAN;
BEGIN
  RETURN CAST(CARDINAL, f) # MAX(CARDINAL)   (* INVALID_HANDLE_VALUE = (HANDLE)(-1) *)
END IsValid;

PROCEDURE Create (path: ARRAY OF CHAR): File;
  VAR nullH: HANDLE;
BEGIN
  nullH := NIL;
  RETURN CreateFileW(ADR(path), AccessRW, FILE_SHARE_READ, NIL,
                     CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullH)
END Create;

PROCEDURE OpenRead (path: ARRAY OF CHAR): File;
  VAR nullH: HANDLE;
BEGIN
  nullH := NIL;
  RETURN CreateFileW(ADR(path), GENERIC_READ, FILE_SHARE_READ, NIL,
                     OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullH)
END OpenRead;

PROCEDURE Close (f: File);
  VAR ok: BOOL;
BEGIN
  ok := CloseHandle(f)
END Close;

PROCEDURE WriteBytes (f: File; buf: ADDRESS; count: CARDINAL): CARDINAL;
  VAR written: DWORD; ok: BOOL;
BEGIN
  written := 0;
  ok := WriteFile(f, buf, VAL(DWORD, count), ADR(written), NIL);
  RETURN VAL(CARDINAL, written)
END WriteBytes;

PROCEDURE ReadBytes (f: File; buf: ADDRESS; count: CARDINAL): CARDINAL;
  VAR rd: DWORD; ok: BOOL;
BEGIN
  rd := 0;
  ok := ReadFile(f, buf, VAL(DWORD, count), ADR(rd), NIL);
  RETURN VAL(CARDINAL, rd)
END ReadBytes;

PROCEDURE Size (f: File): CARDINAL;
  VAR sz: INTEGER64; ok: BOOL;
BEGIN
  sz := 0;
  ok := GetFileSizeEx(f, ADR(sz));
  RETURN VAL(CARDINAL, sz)
END Size;

PROCEDURE Seek (f: File; pos: CARDINAL): BOOLEAN;
  VAR ok: BOOL;
BEGIN
  ok := SetFilePointerEx(f, VAL(INTEGER64, pos), NIL, FILE_BEGIN);
  RETURN ok # 0
END Seek;

PROCEDURE Delete (path: ARRAY OF CHAR): BOOLEAN;
  VAR ok: BOOL;
BEGIN
  ok := DeleteFileW(ADR(path));
  RETURN ok # 0
END Delete;

PROCEDURE Exists (path: ARRAY OF CHAR): BOOLEAN;
  VAR f: File;
BEGIN
  f := OpenRead(path);
  IF IsValid(f) THEN
    Close(f);
    RETURN TRUE
  END;
  RETURN FALSE
END Exists;

END FileFunc.
