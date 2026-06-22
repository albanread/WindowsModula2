IMPLEMENTATION MODULE Harness;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST, ADRCARD;
FROM WIN32 IMPORT HWND, HDC, HBITMAP, HGDIOBJ, BOOL, DWORD, WORD, BYTE, GUID, PWSTR, WPARAM, LPARAM;
FROM Foundation IMPORT RECT;
FROM Graphics_Gdi IMPORT GetDC, ReleaseDC, CreateCompatibleDC, CreateCompatibleBitmap,
  SelectObject, DeleteObject, DeleteDC;
FROM UI_WindowsAndMessaging IMPORT GetClientRect, PostMessageW;
FROM Storage_Xps IMPORT PrintWindow;
FROM Graphics_GdiPlus IMPORT GpBitmap, GpImage, GdiplusStartupInput,
  GdiplusStartup, GdiplusShutdown, GdipCreateBitmapFromHBITMAP, GdipSaveImageToFile, GdipDisposeImage;

TYPE PImg = POINTER TO GpImage;      (* GpBitmap is-a GpImage; named type so CAST accepts it *)

CONST
  WM_KEYDOWN = 256; WM_KEYUP = 257; WM_CHAR = 258;
  WM_MOUSEMOVE = 512; WM_LBUTTONDOWN = 513; WM_LBUTTONUP = 514; WM_MOUSEWHEEL = 522;
  PW_RENDERFULLCONTENT = 3;          (* PW_CLIENTONLY (1) | PW_RENDERFULLCONTENT (2) *)

PROCEDURE SnapClient (hwnd: ADDRESS; path: ARRAY OF CHAR): BOOLEAN;
  VAR rc: RECT; w, h: INTEGER32; dc, memDC: HDC; bmp: HBITMAP; oldobj: HGDIOBJ;
      gp: POINTER TO GpBitmap; tok: ADRCARD; si: GdiplusStartupInput; cl: GUID;
      pwnd: HWND; ok: BOOL; ign: BOOL; st, rel: INTEGER32; prev: HGDIOBJ;
BEGIN
  pwnd := CAST(HWND, hwnd);
  ok := GetClientRect(pwnd, ADR(rc));
  w := rc.right - rc.left; h := rc.bottom - rc.top;
  IF (w <= 0) OR (h <= 0) THEN RETURN FALSE END;
  dc := GetDC(pwnd);
  memDC := CreateCompatibleDC(dc);
  bmp := CreateCompatibleBitmap(dc, w, h);
  prev := SelectObject(memDC, CAST(HGDIOBJ, bmp));
  ok := PrintWindow(pwnd, memDC, VAL(DWORD, PW_RENDERFULLCONTENT));

  si.GdiplusVersion := VAL(DWORD, 1); si.DebugEventCallback := 0;
  si.SuppressBackgroundThread := VAL(BOOL, 0); si.SuppressExternalCodecs := VAL(BOOL, 0);
  st := GdiplusStartup(ADR(tok), ADR(si), NIL);
  gp := NIL;
  st := GdipCreateBitmapFromHBITMAP(bmp, NIL, ADR(gp));
  (* PNG encoder CLSID {557CF406-1A04-11D3-9A73-0000F81EF32E} *)
  cl.Data1 := 0557CF406H; cl.Data2 := VAL(WORD, 01A04H); cl.Data3 := VAL(WORD, 011D3H);
  cl.Data4[0] := VAL(BYTE, 09AH); cl.Data4[1] := VAL(BYTE, 073H);
  cl.Data4[2] := VAL(BYTE, 0);    cl.Data4[3] := VAL(BYTE, 0);
  cl.Data4[4] := VAL(BYTE, 0F8H); cl.Data4[5] := VAL(BYTE, 01EH);
  cl.Data4[6] := VAL(BYTE, 0F3H); cl.Data4[7] := VAL(BYTE, 02EH);
  st := GdipSaveImageToFile(CAST(PImg, gp), CAST(PWSTR, ADR(path)), ADR(cl), NIL);
  GdipDisposeImage(CAST(PImg, gp));
  GdiplusShutdown(tok);

  oldobj := SelectObject(memDC, prev);
  ign := DeleteObject(CAST(HGDIOBJ, bmp));
  ign := DeleteDC(memDC);
  rel := ReleaseDC(pwnd, dc);
  RETURN st = 0
END SnapClient;

PROCEDURE SendChar (hwnd: ADDRESS; ch: CHAR);
  VAR ok: BOOL;
BEGIN
  ok := PostMessageW(CAST(HWND, hwnd), VAL(DWORD, WM_CHAR), VAL(WPARAM, ORD(ch)), VAL(LPARAM, 0))
END SendChar;

PROCEDURE SendKey (hwnd: ADDRESS; vk: CARDINAL);
  VAR ok: BOOL;
BEGIN
  ok := PostMessageW(CAST(HWND, hwnd), VAL(DWORD, WM_KEYDOWN), VAL(WPARAM, vk), VAL(LPARAM, 0));
  ok := PostMessageW(CAST(HWND, hwnd), VAL(DWORD, WM_KEYUP),   VAL(WPARAM, vk), VAL(LPARAM, 0))
END SendKey;

PROCEDURE SendKeyDown (hwnd: ADDRESS; vk: CARDINAL);
  VAR ok: BOOL;
BEGIN ok := PostMessageW(CAST(HWND, hwnd), VAL(DWORD, WM_KEYDOWN), VAL(WPARAM, vk), VAL(LPARAM, 0)) END SendKeyDown;

PROCEDURE SendKeyUp (hwnd: ADDRESS; vk: CARDINAL);
  VAR ok: BOOL;
BEGIN ok := PostMessageW(CAST(HWND, hwnd), VAL(DWORD, WM_KEYUP), VAL(WPARAM, vk), VAL(LPARAM, 0)) END SendKeyUp;

PROCEDURE SendText (hwnd: ADDRESS; s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO SendChar(hwnd, s[i]); INC(i) END
END SendText;

PROCEDURE SendClick (hwnd: ADDRESS; x, y: CARDINAL);
  VAR ok: BOOL; lp: LPARAM; h: HWND;
BEGIN
  h := CAST(HWND, hwnd); lp := VAL(LPARAM, (y * 65536) + x);
  ok := PostMessageW(h, VAL(DWORD, WM_MOUSEMOVE),   VAL(WPARAM, 0), lp);
  ok := PostMessageW(h, VAL(DWORD, WM_LBUTTONDOWN), VAL(WPARAM, 1), lp);
  ok := PostMessageW(h, VAL(DWORD, WM_LBUTTONUP),   VAL(WPARAM, 0), lp)
END SendClick;

PROCEDURE SendMove (hwnd: ADDRESS; x, y: CARDINAL);   (* WM_MOUSEMOVE only — hover, no button *)
  VAR ok: BOOL;
BEGIN
  ok := PostMessageW(CAST(HWND, hwnd), VAL(DWORD, WM_MOUSEMOVE), VAL(WPARAM, 0), VAL(LPARAM, (y * 65536) + x))
END SendMove;

PROCEDURE SendWheel (hwnd: ADDRESS; delta: INTEGER);
  VAR ok: BOOL; hw, wp: CARDINAL;
BEGIN
  IF delta < 0 THEN hw := VAL(CARDINAL, 65536 + delta) ELSE hw := VAL(CARDINAL, delta) END;
  wp := (hw BAND 0FFFFH) * 65536;                       (* HIWORD(wParam) = signed delta *)
  ok := PostMessageW(CAST(HWND, hwnd), VAL(DWORD, WM_MOUSEWHEEL), VAL(WPARAM, wp), VAL(LPARAM, 0))
END SendWheel;

PROCEDURE SendDrag (hwnd: ADDRESS; x0, y0, x1, y1: CARDINAL);
  VAR ok: BOOL; h: HWND; midx, midy: CARDINAL;
BEGIN
  h := CAST(HWND, hwnd); midx := (x0 + x1) DIV 2; midy := (y0 + y1) DIV 2;
  ok := PostMessageW(h, VAL(DWORD, WM_MOUSEMOVE),   VAL(WPARAM, 0), VAL(LPARAM, (y0*65536) + x0));
  ok := PostMessageW(h, VAL(DWORD, WM_LBUTTONDOWN), VAL(WPARAM, 1), VAL(LPARAM, (y0*65536) + x0));
  ok := PostMessageW(h, VAL(DWORD, WM_MOUSEMOVE),   VAL(WPARAM, 1), VAL(LPARAM, (midy*65536) + midx));
  ok := PostMessageW(h, VAL(DWORD, WM_MOUSEMOVE),   VAL(WPARAM, 1), VAL(LPARAM, (y1*65536) + x1));
  ok := PostMessageW(h, VAL(DWORD, WM_LBUTTONUP),   VAL(WPARAM, 0), VAL(LPARAM, (y1*65536) + x1))
END SendDrag;

END Harness.
