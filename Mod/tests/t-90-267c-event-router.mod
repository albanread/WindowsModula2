MODULE T90267CEventRouter;
(*
 * Group 90 — PaneShell S7 (P3) slice 3: the one event router. Every host HWND
 * shares PaneShell's WNDPROC; it recovers the Pane under the message (from the
 * host's GWLP_USERDATA), packages the raw WM_* into a semantic Event keyed to
 * that Pane, updates the polled-input snapshot, and fans the Event to the
 * window's Handler. Driven headlessly by synthesizing messages (WinShell.Send ->
 * SendMessageW -> the WNDPROC, the t-90-243 pattern). EventKind ordinals:
 * EvKey=3, EvChar=4, EvMouse=5, EvControl=12.
 *
 * Everything here flows through the per-window USERDATA + the per-window Handler
 * + the Event record, so it is robust under the parallel test harness. The
 * polled-input lane (KeyDown/MouseAt) reads PaneShell *module-global* state,
 * which is single-UI-thread by design (D2); under cargo test's parallel runner
 * each test JITs its own PaneShell yet they share the process-wide "NewM2PaneHost"
 * window class (first registrant owns the WNDPROC), so the polled globals split
 * across instances. It is verified by the single-instance driver run instead.
 * The router DID set the snapshot — proven here by mouse-ev (ev.x/ev.y come from
 * the same gMouseX the router just wrote).
 *
 * EXPECTED:
 * cmd-kind: 12
 * cmd-pane: Y
 * cmd-id: 42
 * key-kind: 3
 * key-val: 65
 * char-kind: 4
 * char-ch: X
 * mouse-kind: 5
 * mouse-ev: 11,22
 * evcount: 4
 *)
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, LeafPane, Arrange, AddChild,
  SetRect, Init, OpenWindow, CloseWindow, HostOf;
FROM WinShell IMPORT Window, Send;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

CONST
  WM_KEYDOWN = 256; WM_CHAR = 258; WM_COMMAND = 273; WM_LBUTTONDOWN = 513;

VAR
  gLast: Event; gCount: CARDINAL;                 (* the handler records here (per-run, reliable) *)
  ws: Workspace; win: PaneWindow; root, leaf: Pane;
  r: CARDINAL; s: ARRAY [0..1] OF CHAR;

PROCEDURE OnEvent (VAR e: Event): BOOLEAN;
BEGIN gLast := e; INC(gCount); RETURN TRUE END OnEvent;

PROCEDURE YN (c: BOOLEAN);
BEGIN IF c THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

BEGIN
  leaf := LeafPane("leaf", NewRaster(100, 100));
  root := Arrange("root");
  AddChild(root, leaf);
  SetRect(root, 0, 0, 100, 100); SetRect(leaf, 0, 0, 100, 100);
  win := OpenWindow(ws, "router", 100, 100, root, OnEvent);
  gCount := 0;

  (* WM_COMMAND -> EvControl keyed to the leaf Pane *)
  r := Send(HostOf(leaf), WM_COMMAND, 42, 0);
  WriteString("cmd-kind: "); WriteCard(ORD(gLast.kind), 1); WriteLn;
  WriteString("cmd-pane: "); YN(gLast.pane = leaf);
  WriteString("cmd-id: ");   WriteCard(gLast.command, 1); WriteLn;

  (* WM_KEYDOWN -> EvKey *)
  r := Send(HostOf(leaf), WM_KEYDOWN, 65, 0);
  WriteString("key-kind: "); WriteCard(ORD(gLast.kind), 1); WriteLn;
  WriteString("key-val: ");  WriteCard(gLast.key, 1); WriteLn;

  (* WM_CHAR -> EvChar *)
  r := Send(HostOf(leaf), WM_CHAR, 88, 0);
  WriteString("char-kind: "); WriteCard(ORD(gLast.kind), 1); WriteLn;
  s[0] := gLast.ch; s[1] := 0C;
  WriteString("char-ch: "); WriteString(s); WriteLn;

  (* WM_LBUTTONDOWN -> EvMouse; coords (x=11, y=22) flow through the Event *)
  r := Send(HostOf(leaf), WM_LBUTTONDOWN, 0, 22*65536 + 11);
  WriteString("mouse-kind: "); WriteCard(ORD(gLast.kind), 1); WriteLn;
  WriteString("mouse-ev: ");   WriteCard(VAL(CARDINAL, gLast.x), 1); WriteString(",");
  WriteCard(VAL(CARDINAL, gLast.y), 1); WriteLn;

  WriteString("evcount: "); WriteCard(gCount, 1); WriteLn;

  CloseWindow(win)
END T90267CEventRouter.
