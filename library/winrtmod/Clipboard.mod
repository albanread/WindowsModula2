IMPLEMENTATION MODULE Clipboard;

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM WIN32 IMPORT DWORD, BOOL, HGLOBAL, HANDLE;
FROM System_DataExchange IMPORT OpenClipboard, CloseClipboard, EmptyClipboard,
  SetClipboardData, GetClipboardData, IsClipboardFormatAvailable;
FROM System_Memory IMPORT GlobalAlloc, GlobalLock, GlobalUnlock;

CONST
  CF_UNICODETEXT = 13;
  GMEM_MOVEABLE  = 2;

TYPE
  WPtr = POINTER TO ARRAY [0..16777215] OF CHAR;     (* a run of wide chars *)

PROCEDURE SLen (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END; RETURN i END SLen;

PROCEDURE HasText (): BOOLEAN;
BEGIN RETURN IsClipboardFormatAvailable(VAL(DWORD, CF_UNICODETEXT)) # 0 END HasText;

PROCEDURE SetText (s: ARRAY OF CHAR): BOOLEAN;
  VAR h: HGLOBAL; p: ADDRESS; wp: WPtr; n, i: CARDINAL; ok: BOOL;
BEGIN
  IF OpenClipboard(NIL) = 0 THEN RETURN FALSE END;
  ok := EmptyClipboard();
  n := SLen(s);
  h := GlobalAlloc(VAL(DWORD, GMEM_MOVEABLE), (n + 1) * 2);    (* wide bytes *)
  IF h = NIL THEN ok := CloseClipboard(); RETURN FALSE END;
  p := GlobalLock(h);
  IF p = NIL THEN ok := CloseClipboard(); RETURN FALSE END;
  wp := CAST(WPtr, p);
  i := 0;
  WHILE i < n DO wp^[i] := s[i]; INC(i) END;
  wp^[n] := 0C;
  ok := GlobalUnlock(h);
  IF SetClipboardData(VAL(DWORD, CF_UNICODETEXT), h) = NIL THEN
    ok := CloseClipboard(); RETURN FALSE
  END;                                                (* the system now owns h *)
  ok := CloseClipboard();
  RETURN TRUE
END SetText;

PROCEDURE GetText (VAR s: ARRAY OF CHAR): BOOLEAN;
  VAR h: HANDLE; p: ADDRESS; wp: WPtr; i, max: CARDINAL; ok: BOOL;
BEGIN
  s[0] := 0C;
  IF IsClipboardFormatAvailable(VAL(DWORD, CF_UNICODETEXT)) = 0 THEN RETURN FALSE END;
  IF OpenClipboard(NIL) = 0 THEN RETURN FALSE END;
  h := GetClipboardData(VAL(DWORD, CF_UNICODETEXT));
  IF h = NIL THEN ok := CloseClipboard(); RETURN FALSE END;
  p := GlobalLock(h);
  IF p = NIL THEN ok := CloseClipboard(); RETURN FALSE END;
  wp := CAST(WPtr, p);
  max := HIGH(s);
  i := 0;
  WHILE (i < max) AND (wp^[i] # 0C) DO s[i] := wp^[i]; INC(i) END;
  s[i] := 0C;
  ok := GlobalUnlock(h);
  ok := CloseClipboard();
  RETURN TRUE
END GetText;

END Clipboard.
