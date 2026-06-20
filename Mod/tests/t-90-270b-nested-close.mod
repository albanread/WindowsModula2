MODULE T90270bNestedClose;
(*
 * Group 90 — PaneShell S10 hardening (post-review). Two fixes gated here:
 *  (1) ANCESTOR-WALK drag: a grandchild press over an OUTER (grandparent) split's
 *      divider must drive that outer split — BeginSplitDrag climbs ancestors and
 *      hit-tests each Layout with the same pane-frame-absolute point. Pressing
 *      grandchild B near the outer divider (x=500) walks B->s2 (miss) -> s1 (hit)
 *      and drags s1; the inner split s2's own divider is far, so it is skipped.
 *  (2) CloseWindow UNREGISTER: closing a non-last window swap-removes it from the
 *      workspace and decrements the count, so WindowCount stays honest and a later
 *      RunBounded (which ShowWindows every registered frame) cannot dereference the
 *      freed PWinRec (the use-after-free the adversarial review found).
 *
 * EXPECTED:
 * A0: 0,0,500,600
 * A1: 0,0,550,600
 * nested-evt: Y
 * wins4: 4
 * wins-after-close: 3
 * ran-ok: Y
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

VAR ws: Workspace; win, w1, w2, w3: PaneWindow; s1, s2, A, B, C: Pane;
    sawSplit: BOOLEAN;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN IF e.kind = EvSplitterMoved THEN sawSplit := TRUE END; RETURN TRUE END On;

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

  (* ---- nested split: outer divider grabbed via a grandchild (ancestor walk) ---- *)
  A := LeafPane("A", NewRaster(10, 10));
  B := LeafPane("B", NewRaster(10, 10));
  C := LeafPane("C", NewRaster(10, 10));
  s2 := Split(Horizontal, 0.50, 100, 100, B, C);          (* inner: B | C *)
  s1 := Split(Horizontal, 0.50, 100, 100, A, s2);         (* outer: A | (B|C) *)
  SetRect(s1, 0, 0, 1000, 600);
  win := OpenWindow(ws, "N", 1000, 600, s1, On);
  Retile(win);
  PrintRect("A0: ", A);                          (* 0,0,500,600 *)

  Mouse(HostOf(B),  WM_LBUTTONDOWN, 2,   300);   (* grandchild press near OUTER divider (abs 502) *)
  Mouse(HostOf(s1), WM_MOUSEMOVE,   552, 300);   (* captured on s1 -> drag +50 *)
  Mouse(HostOf(s1), WM_LBUTTONUP,   552, 300);
  PrintRect("A1: ", A);                          (* 0,0,550,600 — outer split re-weighted *)
  WriteString("nested-evt: "); YN(sawSplit);

  (* ---- close a non-last window: honest count + no use-after-free on RunBounded ---- *)
  w1 := OpenWindow(ws, "w1", 200, 200, LeafPane("x", NewRaster(8, 8)), On);
  w2 := OpenWindow(ws, "w2", 200, 200, LeafPane("y", NewRaster(8, 8)), On);
  w3 := OpenWindow(ws, "w3", 200, 200, LeafPane("z", NewRaster(8, 8)), On);
  WriteString("wins4: "); WriteCard(WindowCount(ws), 1); WriteLn;          (* win+w1+w2+w3 = 4 *)
  CloseWindow(w1);                                                          (* close the NON-last one *)
  WriteString("wins-after-close: "); WriteCard(WindowCount(ws), 1); WriteLn;  (* 3, w1 slot reclaimed *)
  RunBounded(ws, 4);                             (* ShowWorkspace iterates wins -> must not touch freed w1 *)
  WriteString("ran-ok: "); YN(TRUE);

  Quit(ws);
  CloseWindow(win); CloseWindow(w2); CloseWindow(w3)
END T90270bNestedClose.
