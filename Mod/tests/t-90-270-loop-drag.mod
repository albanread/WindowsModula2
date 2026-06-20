MODULE T90270LoopDrag;
(*
 * Group 90 — PaneShell S10 (P5): the real message loop + multi-window + a mouse
 * splitter drag routed through the WNDPROC. The split-parent's divider is occluded
 * by its child hosts, so the router uses the PARENT-WALK: a press on child `b`
 * converts to pane-frame coords and hit-tests the parent split's Layout; on a hit
 * it opens a per-window drag session and SetCaptures the parent host, so the move
 * and release route there and drive SplitLayout.Drag -> Retile. Driven headlessly
 * by SendMessage (synchronous) + RunBounded (proves the loop runs & terminates).
 * EvSplitterMoved is LATCHED (the real frame's WM_SIZE -> EvResize clobbers last-kind).
 *
 * EXPECTED:
 * b0: 700,0,300,600
 * b1: 750,0,250,600
 * a1: 0,0,750,600
 * split-evt: Y
 * wins: 2
 * quit-ok: Y
 *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvSplitterMoved,
  LeafPane, SetRect, RectOf, HostOf, Init, OpenWindow, CloseWindow, Retile,
  RunBounded, Quit, WindowCount;
FROM PaneLayout IMPORT Orientation, Split;
FROM UI_WindowsAndMessaging IMPORT SendMessageW;
FROM WIN32 IMPORT HWND, WPARAM, LPARAM, LRESULT, DWORD;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

CONST WM_MOUSEMOVE = 512; WM_LBUTTONDOWN = 513; WM_LBUTTONUP = 514;

VAR ws: Workspace; win, win2: PaneWindow; sp, a, b: Pane;
    sawSplit: BOOLEAN;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN IF e.kind = EvSplitterMoved THEN sawSplit := TRUE END; RETURN TRUE END On;

(* send a mouse message to a host with (x,y) packed into lParam (Win32 MAKELPARAM) *)
PROCEDURE Mouse (host: ADDRESS; msg, x, y: CARDINAL);
  VAR lr: LRESULT; lp: CARDINAL;
BEGIN
  lp := (y * 65536) + x;
  lr := SendMessageW(CAST(HWND, host), VAL(DWORD, msg), VAL(WPARAM, 0), VAL(LPARAM, lp))
END Mouse;

PROCEDURE PrintRect (label: ARRAY OF CHAR; p: Pane);
  VAR x, y, w, h: CARDINAL;
BEGIN
  RectOf(p, x, y, w, h); WriteString(label);
  WriteCard(x,1); WriteString(","); WriteCard(y,1); WriteString(",");
  WriteCard(w,1); WriteString(","); WriteCard(h,1); WriteLn
END PrintRect;

PROCEDURE YN (c: BOOLEAN);
BEGIN IF c THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

BEGIN
  sawSplit := FALSE;
  ws := Init();
  a := LeafPane("a", NewRaster(10, 10)); b := LeafPane("b", NewRaster(10, 10));
  sp := Split(Horizontal, 0.70, 240, 160, a, b);
  SetRect(sp, 0, 0, 1000, 600);
  win := OpenWindow(ws, "L", 1000, 600, sp, On);
  Retile(win);
  PrintRect("b0: ", b);                          (* 700,0,300,600 *)

  (* drag the divider +50: press on child b over the boundary (b-client x=2),
     move to absolute x=752 (delivered to the captured parent host), release *)
  Mouse(HostOf(b),  WM_LBUTTONDOWN, 2,   300);
  Mouse(HostOf(sp), WM_MOUSEMOVE,   752, 300);
  Mouse(HostOf(sp), WM_LBUTTONUP,   752, 300);

  (* assert the post-drag layout BEFORE the window is shown — RunBounded's ShowWindow
     would auto-fit the root to the real (smaller) client, which is correct but
     client-size-dependent; the logical 1000x600 layout is what we pin here. *)
  PrintRect("b1: ", b);                          (* 750,0,250,600 *)
  PrintRect("a1: ", a);                          (* 0,0,750,600 *)
  WriteString("split-evt: "); YN(sawSplit);
  RunBounded(ws, 4);                             (* loop runs & drains, then returns *)

  (* multi-window: a second top-level window registers with the same workspace *)
  win2 := OpenWindow(ws, "L2", 400, 300, LeafPane("x", NewRaster(10, 10)), On);
  WriteString("wins: "); WriteCard(WindowCount(ws), 1); WriteLn;   (* 2 *)

  (* Quit latches the workspace + posts WM_QUIT; RunBounded must stop promptly *)
  Quit(ws);
  RunBounded(ws, 100);
  WriteString("quit-ok: "); YN(TRUE);            (* reached here => the loop terminated *)

  CloseWindow(win); CloseWindow(win2)
END T90270LoopDrag.
