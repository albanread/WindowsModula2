MODULE T90269SplitterTabs;
(*
 * Group 90 — PaneShell S9 (P4 part 2/2, closes P4): a draggable splitter divider
 * and fixed author tabs, both as Layout strategies. The divider is exercised at
 * the method level (synthesize a hit + a drag delta into SplitLayout.HitTest /
 * Drag, the t-90-269 deliverable) — the real mouse-on-gutter routing is the
 * manual 13a demo. TabLayout shows the active tab's child below a 24px strip;
 * SelectTab switches it.
 *
 * EvSplitterMoved / EvTabChanged are raised synchronously (PaneShell.RaiseEvent,
 * a direct call to this window's Handler). The frame is a real HWND, so the
 * subsequent Retile fires WM_SIZE -> EvResize through the router; we therefore
 * LATCH the two semantic events (sawSplit / sawTab) rather than read last-kind.
 *
 * EXPECTED:
 * a0: 0,0,700,600
 * hit: Y
 * miss: Y
 * a1: 0,0,750,600
 * split-evt: Y
 * t0-active: 0,24,200,76
 * t1-hidden: 0,0,0,0
 * active0: 0
 * t1-active: 0,24,200,76
 * active1: 1
 * tab-evt: Y
 *)
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvSplitterMoved, EvTabChanged,
  Layout, LeafPane, SetRect, RectOf, OpenWindow, CloseWindow, Retile, LayoutOf;
FROM PaneLayout IMPORT Orientation, Split, NewTabs, AddTab, SelectTab, ActiveTab;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR ws: Workspace; win, win2: PaneWindow; sp, a, b, tabs, t0, t1: Pane;
    lay: Layout; handle, missHandle: CARDINAL;
    sawSplit, sawTab: BOOLEAN;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN
  IF e.kind = EvSplitterMoved THEN sawSplit := TRUE END;
  IF e.kind = EvTabChanged    THEN sawTab   := TRUE END;
  RETURN TRUE
END On;

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
  sawSplit := FALSE; sawTab := FALSE;
  (* ---- splitter drag ---- *)
  a := LeafPane("a", NewRaster(10, 10)); b := LeafPane("b", NewRaster(10, 10));
  sp := Split(Horizontal, 0.70, 240, 160, a, b);
  SetRect(sp, 0, 0, 1000, 600);
  win := OpenWindow(ws, "S", 1000, 600, sp, On);
  Retile(win);
  PrintRect("a0: ", a);                          (* 0,0,700,600 *)

  lay := LayoutOf(sp);
  handle     := lay.HitTest(sp, 702, 300);       (* on the divider -> 0 *)
  missHandle := lay.HitTest(sp, 100, 300);       (* away -> MAX *)
  WriteString("hit: ");  YN(handle = 0);
  WriteString("miss: "); YN(missHandle # 0);

  lay.Drag(sp, handle, 50, 0);                    (* drag right +50 -> weight 0.75, raises EvSplitterMoved *)
  Retile(win);
  PrintRect("a1: ", a);                          (* 0,0,750,600 *)
  WriteString("split-evt: "); YN(sawSplit);

  (* ---- fixed tabs ---- *)
  t0 := LeafPane("t0", NewRaster(10, 10)); t1 := LeafPane("t1", NewRaster(10, 10));
  tabs := NewTabs(); AddTab(tabs, "One", t0); AddTab(tabs, "Two", t1);
  SetRect(tabs, 0, 0, 200, 100);
  win2 := OpenWindow(ws, "T", 200, 100, tabs, On);
  Retile(win2);
  PrintRect("t0-active: ", t0);                  (* 0,24,200,76 *)
  PrintRect("t1-hidden: ", t1);                  (* 0,0,0,0 *)
  WriteString("active0: "); WriteCard(ActiveTab(tabs), 1); WriteLn;

  SelectTab(tabs, 1); Retile(win2);              (* switch -> raises EvTabChanged *)
  PrintRect("t1-active: ", t1);                  (* 0,24,200,76 *)
  WriteString("active1: "); WriteCard(ActiveTab(tabs), 1); WriteLn;
  WriteString("tab-evt: "); YN(sawTab);

  CloseWindow(win); CloseWindow(win2)
END T90269SplitterTabs.
