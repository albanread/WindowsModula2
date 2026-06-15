IMPLEMENTATION MODULE Dialogs;

FROM SYSTEM IMPORT ADDRESS, ADR, SIZE, CAST;
FROM WIN32 IMPORT DWORD, HWND, PWSTR;
FROM Foundation IMPORT COLORREF;
FROM UI_Controls_Dialogs IMPORT
  OPENFILENAME_NT4W, GetOpenFileNameW, GetSaveFileNameW,
  CHOOSECOLORW, ChooseColorW;
FROM UI_WindowsAndMessaging IMPORT MessageBoxW;
FROM MemUtils IMPORT ZeroMem;

CONST
  OFN_HIDEREADONLY    = 04H;
  OFN_OVERWRITEPROMPT = 02H;
  OFN_PATHMUSTEXIST   = 0800H;
  OFN_FILEMUSTEXIST   = 1000H;
  CC_RGBINIT = 01H; CC_FULLOPEN = 02H;
  MB_OK = 0H; MB_YESNO = 04H; MB_ICONINFORMATION = 040H; MB_ICONQUESTION = 020H;
  IDYES = 6;

VAR
  gCustom: ARRAY [0..15] OF COLORREF;          (* the colour picker's custom swatches *)

(* Turn "desc|pat|desc|pat" into the comdlg32 double-NUL filter "desc<0>pat<0>...<0><0>".
   Returns FALSE (no filter) when `filter` is empty. *)
PROCEDURE BuildFilter (filter: ARRAY OF CHAR; VAR out: ARRAY OF CHAR): BOOLEAN;
  VAR i, o: CARDINAL;
BEGIN
  IF filter[0] = 0C THEN RETURN FALSE END;
  i := 0; o := 0;
  WHILE (i <= HIGH(filter)) AND (filter[i] # 0C) AND (o + 3 < HIGH(out)) DO
    IF filter[i] = '|' THEN out[o] := 0C ELSE out[o] := filter[i] END;
    INC(i); INC(o)
  END;
  out[o] := 0C; out[o+1] := 0C;                (* double-NUL terminate *)
  RETURN TRUE
END BuildFilter;

(* Shared OPENFILENAMEW setup for Open and Save. *)
PROCEDURE FillOFN (VAR ofn: OPENFILENAME_NT4W; owner: ADDRESS;
                   VAR path, filterBuf, title: ARRAY OF CHAR; hasFilter: BOOLEAN);
BEGIN
  ZeroMem(ADR(ofn), SIZE(ofn));
  ofn.lStructSize := VAL(DWORD, SIZE(ofn));
  ofn.hwndOwner   := CAST(HWND, owner);
  IF hasFilter THEN ofn.lpstrFilter := CAST(PWSTR, ADR(filterBuf[0])) END;
  ofn.lpstrFile   := CAST(PWSTR, ADR(path[0]));
  ofn.nMaxFile    := VAL(DWORD, HIGH(path) + 1);
  IF title[0] # 0C THEN ofn.lpstrTitle := CAST(PWSTR, ADR(title[0])) END
END FillOFN;

PROCEDURE OpenFile (owner: ADDRESS; VAR path: ARRAY OF CHAR;
                    filter, title: ARRAY OF CHAR): BOOLEAN;
  VAR ofn: OPENFILENAME_NT4W; fbuf: ARRAY [0..255] OF CHAR; hasF: BOOLEAN;
BEGIN
  hasF := BuildFilter(filter, fbuf);
  FillOFN(ofn, owner, path, fbuf, title, hasF);
  ofn.Flags := VAL(DWORD, OFN_PATHMUSTEXIST + OFN_FILEMUSTEXIST + OFN_HIDEREADONLY);
  RETURN GetOpenFileNameW(ADR(ofn)) # 0
END OpenFile;

PROCEDURE SaveFile (owner: ADDRESS; VAR path: ARRAY OF CHAR;
                    filter, title, defExt: ARRAY OF CHAR): BOOLEAN;
  VAR ofn: OPENFILENAME_NT4W; fbuf: ARRAY [0..255] OF CHAR; hasF: BOOLEAN;
BEGIN
  hasF := BuildFilter(filter, fbuf);
  FillOFN(ofn, owner, path, fbuf, title, hasF);
  ofn.Flags := VAL(DWORD, OFN_OVERWRITEPROMPT + OFN_PATHMUSTEXIST + OFN_HIDEREADONLY);
  IF defExt[0] # 0C THEN ofn.lpstrDefExt := CAST(PWSTR, ADR(defExt[0])) END;
  RETURN GetSaveFileNameW(ADR(ofn)) # 0
END SaveFile;

PROCEDURE ChooseColour (owner: ADDRESS; VAR rgb: CARDINAL): BOOLEAN;
  VAR cc: CHOOSECOLORW;
BEGIN
  ZeroMem(ADR(cc), SIZE(cc));
  cc.lStructSize  := VAL(DWORD, SIZE(cc));
  cc.hwndOwner    := CAST(HWND, owner);
  cc.rgbResult.Value := VAL(DWORD, rgb);
  cc.lpCustColors := ADR(gCustom[0]);
  cc.Flags        := VAL(DWORD, CC_RGBINIT + CC_FULLOPEN);
  IF ChooseColorW(ADR(cc)) # 0 THEN
    rgb := VAL(CARDINAL, cc.rgbResult.Value); RETURN TRUE
  END;
  RETURN FALSE
END ChooseColour;

PROCEDURE Message (owner: ADDRESS; text, title: ARRAY OF CHAR);
  VAR r: INTEGER;
BEGIN
  r := MessageBoxW(CAST(HWND, owner), CAST(PWSTR, ADR(text[0])),
                   CAST(PWSTR, ADR(title[0])), VAL(DWORD, MB_OK + MB_ICONINFORMATION))
END Message;

PROCEDURE Confirm (owner: ADDRESS; text, title: ARRAY OF CHAR): BOOLEAN;
  VAR r: INTEGER;
BEGIN
  r := MessageBoxW(CAST(HWND, owner), CAST(PWSTR, ADR(text[0])),
                   CAST(PWSTR, ADR(title[0])), VAL(DWORD, MB_YESNO + MB_ICONQUESTION));
  RETURN r = IDYES
END Confirm;

VAR gi: CARDINAL;
BEGIN
  FOR gi := 0 TO 15 DO gCustom[gi].Value := VAL(DWORD, 0FFFFFFH) END
END Dialogs.
