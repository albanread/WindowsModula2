IMPLEMENTATION MODULE FileMap;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM System_Memory IMPORT
  MEMORY_MAPPED_VIEW_ADDRESS, CreateFileMappingW, OpenFileMappingW,
  MapViewOfFile, UnmapViewOfFile, FlushViewOfFile,
  FILE_MAP_READ, FILE_MAP_ALL_ACCESS, PAGE_READONLY, PAGE_READWRITE;
FROM Storage_FileSystem IMPORT CreateFileW, GetFileSizeEx;
FROM Foundation IMPORT CloseHandle, GetLastError;
FROM WIN32 IMPORT DWORD, BOOL, HANDLE;

CONST
  GENERIC_READ          = 80000000H;
  AccessRW              = 0C0000000H;   (* GENERIC_READ BOR GENERIC_WRITE *)
  OPEN_EXISTING         = 3;
  FILE_ATTRIBUTE_NORMAL = 80H;
  ErrBadArgs            = 2;

PROCEDURE Invalid (): HANDLE;            (* INVALID_HANDLE_VALUE = -1 as a handle *)
BEGIN RETURN CAST(HANDLE, MAX(CARDINAL)) END Invalid;

PROCEDURE IsInvalid (h: ADDRESS): BOOLEAN;
BEGIN RETURN CAST(CARDINAL, h) = MAX(CARDINAL) END IsInvalid;

PROCEDURE CopyZ (VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (i < HIGH(dst)) AND (src[i] # 0C) DO
    dst[i] := src[i]; INC(i)
  END;
  dst[i] := 0C
END CopyZ;

PROCEDURE CreateFileMap (VAR mf: MappedFile; fileName, mapName: ARRAY OF CHAR;
                         mode: MapMode; maxSize: CARDINAL): FileMapResults;
  VAR fbuf, nbuf: ARRAY [0..519] OF CHAR;
      fh, mh: HANDLE; hForMap, namePtr: ADDRESS;
      access, prot: DWORD; sz: CARDINAL; ok: BOOL;
BEGIN
  mf.status := 0; mf.maxSize := maxSize; mf.mapStart := 0; mf.mapLength := 0;
  mf.mapPtr := NIL; mf.mapHandle := NIL; mf.fileHandle := Invalid(); mf.mode := mode;
  CopyZ(fbuf, fileName); CopyZ(nbuf, mapName);

  (* page-file backing needs an explicit size *)
  IF (fbuf[0] = 0C) AND (maxSize = 0) THEN
    mf.status := ErrBadArgs; RETURN FileMapFailed
  END;

  (* an existing named mapping wins — no backing file is opened *)
  IF nbuf[0] # 0C THEN
    IF mode = MapReadOnly THEN access := FILE_MAP_READ ELSE access := FILE_MAP_ALL_ACCESS END;
    mh := OpenFileMappingW(access, VAL(BOOL, 0), ADR(nbuf));
    IF mh # NIL THEN mf.mapHandle := mh; RETURN FileMapOpened END
  END;

  (* open the backing file (exclusive: share mode 0) *)
  IF fbuf[0] # 0C THEN
    IF mode = MapReadOnly THEN access := GENERIC_READ ELSE access := AccessRW END;
    fh := CreateFileW(ADR(fbuf), access, 0, NIL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NIL);
    IF IsInvalid(fh) THEN
      mf.status := VAL(CARDINAL, GetLastError()); RETURN FileMapFailed
    END;
    mf.fileHandle := fh;
    hForMap := fh;
    IF maxSize = 0 THEN
      sz := 0; ok := GetFileSizeEx(fh, ADR(sz)); mf.maxSize := sz
    END
  ELSE
    hForMap := Invalid()                 (* page-file-backed *)
  END;

  IF mode = MapReadOnly THEN prot := PAGE_READONLY ELSE prot := PAGE_READWRITE END;
  IF nbuf[0] = 0C THEN namePtr := NIL ELSE namePtr := ADR(nbuf) END;
  mh := CreateFileMappingW(CAST(HANDLE, hForMap), NIL, prot, 0,
                           VAL(DWORD, mf.maxSize), namePtr);
  IF mh # NIL THEN mf.mapHandle := mh; RETURN FileMapCreated END;

  mf.status := VAL(CARDINAL, GetLastError());
  IF NOT IsInvalid(mf.fileHandle) THEN ok := CloseHandle(mf.fileHandle) END;
  RETURN FileMapFailed
END CreateFileMap;

PROCEDURE CloseFileMap (VAR mf: MappedFile): BOOLEAN;
  VAR view: MEMORY_MAPPED_VIEW_ADDRESS; ok: BOOL;
BEGIN
  IF mf.mapPtr # NIL THEN
    view.Value := mf.mapPtr;
    IF UnmapViewOfFile(view) = 0 THEN RETURN FALSE END;
    mf.mapPtr := NIL
  END;
  IF mf.mapHandle # NIL THEN ok := CloseHandle(mf.mapHandle); mf.mapHandle := NIL END;
  IF NOT IsInvalid(mf.fileHandle) THEN
    ok := CloseHandle(mf.fileHandle); mf.fileHandle := Invalid()
  END;
  RETURN TRUE
END CloseFileMap;

PROCEDURE MapFileView (VAR mf: MappedFile; start, length: CARDINAL): ADDRESS;
  VAR view: MEMORY_MAPPED_VIEW_ADDRESS; access: DWORD;
BEGIN
  IF mf.mode = MapReadOnly THEN access := FILE_MAP_READ ELSE access := FILE_MAP_ALL_ACCESS END;
  IF length = 0 THEN length := mf.maxSize END;
  mf.mapStart := start; mf.mapLength := length;
  view := MapViewOfFile(CAST(HANDLE, mf.mapHandle), access, 0, VAL(DWORD, start), length);
  mf.status := VAL(CARDINAL, GetLastError());
  mf.mapPtr := view.Value;
  RETURN view.Value
END MapFileView;

PROCEDURE UnMapFileView (VAR mf: MappedFile): BOOLEAN;
  VAR view: MEMORY_MAPPED_VIEW_ADDRESS;
BEGIN
  IF mf.mapPtr # NIL THEN
    view.Value := mf.mapPtr;
    IF UnmapViewOfFile(view) # 0 THEN
      mf.mapPtr := NIL; RETURN TRUE
    END;
    mf.status := VAL(CARDINAL, GetLastError());
    RETURN FALSE
  END;
  mf.status := ErrBadArgs;
  RETURN FALSE
END UnMapFileView;

PROCEDURE FlushMappedFile (VAR mf: MappedFile): BOOLEAN;
  VAR ok: BOOL;
BEGIN
  ok := FlushViewOfFile(mf.mapPtr, mf.mapLength);
  mf.status := VAL(CARDINAL, GetLastError());
  RETURN ok # 0
END FlushMappedFile;

END FileMap.
