MODULE T90267BPaneHosts;
(*
 * Group 90 — PaneShell S7 (P3) slice 2: the host-HWND tree is a projection of
 * the Pane tree. OpenWindow creates a top frame, then a host HWND per Pane
 * (WS_CHILD|WS_CLIPCHILDREN): the root's host is a child of the frame, and each
 * child pane's host is a child of its parent pane's host — proven via Win32
 * GetParent. Leaf backends attach to their host (RasterView = headless-safe).
 *
 * EXPECTED:
 * frame: Y
 * root-host: Y
 * leaf-host: Y
 * root-under-frame: Y
 * mid-under-root: Y
 * leaf-under-mid: Y
 * closed: Y
 *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, LeafPane, Arrange, AddChild,
  SetRect, Init, OpenWindow, CloseWindow, HostOf, FrameOf;
FROM UI_WindowsAndMessaging IMPORT GetParent;
FROM WIN32 IMPORT HWND;
FROM StrIO IMPORT WriteString, WriteLn;

VAR ws: Workspace; win: PaneWindow; root, mid, leaf1, leaf2: Pane;

PROCEDURE OnEvent (VAR e: Event): BOOLEAN;
BEGIN RETURN FALSE END OnEvent;

PROCEDURE YN (c: BOOLEAN);
BEGIN IF c THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

(* GetParent(child) = parent ? *)
PROCEDURE ParentEq (child, parent: ADDRESS): BOOLEAN;
BEGIN RETURN CAST(ADDRESS, GetParent(CAST(HWND, child))) = parent END ParentEq;

BEGIN
  ws := Init();
  (* a 3-level tree: root -> mid -> { leaf1, leaf2 } *)
  leaf1 := LeafPane("a", NewRaster(100, 100));
  leaf2 := LeafPane("b", NewRaster(100, 100));
  mid   := Arrange("mid");
  AddChild(mid, leaf1); AddChild(mid, leaf2);
  root  := Arrange("root");
  AddChild(root, mid);
  SetRect(root, 0, 0, 200, 100); SetRect(mid, 0, 0, 200, 100);
  SetRect(leaf1, 0, 0, 100, 100); SetRect(leaf2, 100, 0, 100, 100);

  win := OpenWindow(ws, "test", 200, 100, root, OnEvent);

  WriteString("frame: ");            YN(FrameOf(win) # NIL);
  WriteString("root-host: ");        YN(HostOf(root) # NIL);
  WriteString("leaf-host: ");        YN(HostOf(leaf1) # NIL);
  WriteString("root-under-frame: "); YN(ParentEq(HostOf(root), FrameOf(win)));
  WriteString("mid-under-root: ");   YN(ParentEq(HostOf(mid), HostOf(root)));
  WriteString("leaf-under-mid: ");   YN(ParentEq(HostOf(leaf1), HostOf(mid)));

  CloseWindow(win);
  WriteString("closed: ");           YN(win = NIL)
END T90267BPaneHosts.
