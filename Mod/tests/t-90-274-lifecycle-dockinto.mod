MODULE T90274LifecycleDockInto;
(*
 * Group 90 — PaneShell S12 slice 2b (closes P6's window-close + drop-apply surface):
 *  (1) EvWindowClosed: CloseWindow notifies the app's Handler before teardown.
 *  (2) Frame WM_CLOSE participates: the frame now carries GWLP_USERDATA = its root,
 *      so a title-bar X raises EvCloseRequest AND is SWALLOWED (PaneWndProc returns 0,
 *      no DefWindowProc destroy) — the app controls the close. IsWindow proves the
 *      frame survived the WM_CLOSE.
 *  (3) DockInto applies a DropAt result: NewFloat pops a doc to its own window;
 *      DockCentre re-docks it; NoDrop is a no-op (FALSE).
 *
 * EXPECTED:
 * win-closed-evt: Y
 * close-req-evt: Y
 * frame-alive: Y
 * wins0: 1
 * after-float: 2
 * float-detached: Y
 * after-dock: 1
 * redocked: Y
 * nodrop-false: Y
 *)
FROM SYSTEM IMPORT CAST;
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvWindowClosed, EvCloseRequest,
  DropZone, LeafPane, SetRect, Init, OpenWindow, CloseWindow, FrameOf, WindowCount, ParentOf;
FROM MDIContainer IMPORT Style, Create, AddDocument, DockInto;
FROM UI_WindowsAndMessaging IMPORT SendMessageW, IsWindow;
FROM WIN32 IMPORT HWND, WPARAM, LPARAM, LRESULT, DWORD, BOOL;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

CONST WM_CLOSE = 16;

VAR ws: Workspace; w, w2, win: PaneWindow; c, a0, a1: Pane;
    sawWinClosed, sawCloseReq: BOOLEAN; idr: CARDINAL; ok: BOOLEAN; lr: LRESULT;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN
  IF e.kind = EvWindowClosed THEN sawWinClosed := TRUE END;
  IF e.kind = EvCloseRequest THEN sawCloseReq  := TRUE END;
  RETURN TRUE
END On;

PROCEDURE YN (b: BOOLEAN);
BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

BEGIN
  sawWinClosed := FALSE; sawCloseReq := FALSE;
  ws := Init();

  (* (1) EvWindowClosed on CloseWindow *)
  w := OpenWindow(ws, "x", 200, 200, LeafPane("x", NewRaster(8, 8)), On);
  CloseWindow(w);
  WriteString("win-closed-evt: "); YN(sawWinClosed);

  (* (2) frame WM_CLOSE -> EvCloseRequest, swallowed (frame survives) *)
  w2 := OpenWindow(ws, "y", 200, 200, LeafPane("y", NewRaster(8, 8)), On);
  lr := SendMessageW(CAST(HWND, FrameOf(w2)), VAL(DWORD, WM_CLOSE), VAL(WPARAM, 0), VAL(LPARAM, 0));
  WriteString("close-req-evt: "); YN(sawCloseReq);
  WriteString("frame-alive: "); YN(IsWindow(CAST(HWND, FrameOf(w2))) # VAL(BOOL, 0));
  CloseWindow(w2);

  (* (3) DockInto applies a DropAt outcome *)
  c := Create(Tabbed);
  a0 := LeafPane("a0", NewRaster(10, 10)); a1 := LeafPane("a1", NewRaster(10, 10));
  idr := AddDocument(c, "a0", a0); idr := AddDocument(c, "a1", a1);
  SetRect(c, 0, 0, 400, 300);
  win := OpenWindow(ws, "c", 400, 300, c, On);
  WriteString("wins0: "); WriteCard(WindowCount(ws), 1); WriteLn;

  ok := DockInto(c, 0, NewFloat);
  WriteString("after-float: "); WriteCard(WindowCount(ws), 1); WriteLn;
  WriteString("float-detached: "); YN(ParentOf(a0) = NIL);

  ok := DockInto(c, 0, DockCentre);
  WriteString("after-dock: "); WriteCard(WindowCount(ws), 1); WriteLn;
  WriteString("redocked: "); YN(ParentOf(a0) = c);

  WriteString("nodrop-false: "); YN(NOT DockInto(c, 0, NoDrop));

  CloseWindow(win)
END T90274LifecycleDockInto.
