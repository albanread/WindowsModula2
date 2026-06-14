IMPLEMENTATION MODULE WinShell;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST, SIZE;
FROM UI_WindowsAndMessaging IMPORT
  WNDCLASSEXW, MSG, RegisterClassExW, CreateWindowExW, DefWindowProcW,
  SendMessageW, DestroyWindow, ShowWindow, GetMessageW, PeekMessageW,
  TranslateMessage, DispatchMessageW, PostQuitMessage, GetClientRect,
  WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, SW_SHOW, PM_REMOVE, WM_QUIT;
FROM Graphics_Gdi IMPORT InvalidateRect;
FROM Foundation IMPORT RECT;
FROM System_LibraryLoader IMPORT GetModuleHandleW;
FROM WIN32 IMPORT HWND, HINSTANCE, WPARAM, LPARAM, LRESULT, DWORD, BOOL, WORD;
FROM MemUtils IMPORT ZeroMem;

CONST MsgParentBits = 2;     (* HWND_MESSAGE = -3 = MAX(CARDINAL) - 2 *)

VAR
  gHandler:    MsgProc;
  gRegistered: BOOLEAN;

(* The native window procedure (an M2 proc used as a C-ABI WNDPROC). It hands
   the message to the M2 handler; anything the handler leaves unhandled goes to
   DefWindowProcW. *)
PROCEDURE WndProc (hWnd: HWND; msg: DWORD; wParam: WPARAM; lParam: LPARAM): LRESULT;
  VAR handled: BOOLEAN; res: CARDINAL;
BEGIN
  IF gHandler # NIL THEN
    handled := FALSE;
    res := gHandler(hWnd, VAL(CARDINAL, msg),
                    CAST(CARDINAL, wParam), CAST(CARDINAL, lParam), handled);
    IF handled THEN RETURN CAST(LRESULT, res) END
  END;
  RETURN DefWindowProcW(hWnd, msg, wParam, lParam)
END WndProc;

PROCEDURE EnsureClass (VAR className: ARRAY OF CHAR): HINSTANCE;
  VAR wc: WNDCLASSEXW; hInst: HINSTANCE; atom: WORD;
BEGIN
  hInst := GetModuleHandleW(NIL);
  className := "NewM2WinShellMsg";
  IF NOT gRegistered THEN
    ZeroMem(ADR(wc), SIZE(wc));
    wc.cbSize := VAL(DWORD, SIZE(wc));
    wc.lpfnWndProc := CAST(ADDRESS, WndProc);    (* M2 proc as a native WNDPROC *)
    wc.hInstance := hInst;
    wc.lpszClassName := ADR(className);
    atom := RegisterClassExW(ADR(wc));
    gRegistered := TRUE
  END;
  RETURN hInst
END EnsureClass;

PROCEDURE CreateMessageWindow (handler: MsgProc): Window;
  VAR hInst: HINSTANCE; parent: HWND; className: ARRAY [0..31] OF CHAR;
BEGIN
  gHandler := handler;
  hInst := EnsureClass(className);
  parent := CAST(HWND, MAX(CARDINAL) - MsgParentBits);   (* HWND_MESSAGE *)
  RETURN CreateWindowExW(0, ADR(className), NIL, 0, 0, 0, 0, 0,
                         parent, NIL, hInst, NIL)
END CreateMessageWindow;

PROCEDURE CreateAppWindow (title: ARRAY OF CHAR; w, h: CARDINAL; handler: MsgProc): Window;
  VAR hInst: HINSTANCE; className: ARRAY [0..31] OF CHAR;
      titleBuf: ARRAY [0..127] OF CHAR; i: CARDINAL;
BEGIN
  gHandler := handler;
  hInst := EnsureClass(className);
  i := 0;
  WHILE (i <= HIGH(title)) AND (i < 127) AND (title[i] # 0C) DO titleBuf[i] := title[i]; INC(i) END;
  titleBuf[i] := 0C;
  RETURN CreateWindowExW(0, ADR(className), ADR(titleBuf), WS_OVERLAPPEDWINDOW,
                         CW_USEDEFAULT, CW_USEDEFAULT, VAL(INTEGER32, w), VAL(INTEGER32, h),
                         NIL, NIL, hInst, NIL)
END CreateAppWindow;

PROCEDURE Show (w: Window);
  VAR ok: BOOL;
BEGIN ok := ShowWindow(w, VAL(INTEGER32, SW_SHOW)) END Show;

PROCEDURE ClientSize (w: Window; VAR cw, ch: CARDINAL);
  VAR rc: RECT; ok: BOOL;
BEGIN
  ok := GetClientRect(w, ADR(rc));
  cw := VAL(CARDINAL, rc.right - rc.left);
  ch := VAL(CARDINAL, rc.bottom - rc.top)
END ClientSize;

PROCEDURE Repaint (w: Window);
  VAR ok: BOOL;
BEGIN ok := InvalidateRect(w, NIL, VAL(BOOL, 0)) END Repaint;

PROCEDURE RunMessageLoop;
  VAR msg: MSG; r, tr: BOOL; lr: LRESULT;
BEGIN
  LOOP
    r := GetMessageW(ADR(msg), NIL, VAL(DWORD, 0), VAL(DWORD, 0));
    IF r = 0 THEN EXIT END;                  (* WM_QUIT *)
    tr := TranslateMessage(ADR(msg));
    lr := DispatchMessageW(ADR(msg))
  END
END RunMessageLoop;

PROCEDURE PumpMessages (): BOOLEAN;
  VAR msg: MSG; r, tr: BOOL; lr: LRESULT;
BEGIN
  LOOP
    r := PeekMessageW(ADR(msg), NIL, VAL(DWORD, 0), VAL(DWORD, 0), VAL(DWORD, PM_REMOVE));
    IF r = 0 THEN RETURN TRUE END;                          (* queue drained this frame *)
    IF msg.message = VAL(DWORD, WM_QUIT) THEN RETURN FALSE END;
    tr := TranslateMessage(ADR(msg));
    lr := DispatchMessageW(ADR(msg))
  END
END PumpMessages;

PROCEDURE Quit;
BEGIN PostQuitMessage(VAL(INTEGER32, 0)) END Quit;

PROCEDURE Send (w: Window; msg, wParam, lParam: CARDINAL): CARDINAL;
BEGIN
  RETURN CAST(CARDINAL,
              SendMessageW(w, VAL(DWORD, msg),
                           CAST(WPARAM, wParam), CAST(LPARAM, lParam)))
END Send;

PROCEDURE Destroy (VAR w: Window);
  VAR ok: BOOL;
BEGIN
  IF w # NIL THEN ok := DestroyWindow(w); w := NIL END
END Destroy;

BEGIN
  gRegistered := FALSE      (* gHandler is NIL by zero-init until a window is made *)
END WinShell.
