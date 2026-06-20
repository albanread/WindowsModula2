MODULE T90267ELayout;
(*
 * Group 90 — PaneShell S7 (P3) slice 4b: the Layout ABSTRACT CLASS (D7). An
 * arrangement Pane carries a Layout; Retile delegates child placement to it via
 * Arrange — the substrate never knows the algorithm. Proven with an APP-DEFINED
 * Layout (HalfSplit: split the host width 50/50 between two children), and the
 * non-Layout guard (a Pane with no Layout is left untouched by Retile). Rects are
 * per-pane heap state, so robust under the parallel harness.
 *
 * EXPECTED:
 * a-rect: 0,0,50,40
 * b-rect: 50,0,50,40
 * c-rect: 7,7,7,7
 *)
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, DropZone, Layout, NoDrop,
  LeafPane, Arrange, AddChild, SetRect, RectOf, ChildCount, Child, SetLayout,
  Init, OpenWindow, CloseWindow, Retile;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

(* an APP-DEFINED Layout strategy (the D7 extension seam): split host width 50/50 *)
CLASS HalfSplit;
  INHERIT Layout;
  OVERRIDE PROCEDURE Arrange (host: Pane; x, y, w, h: CARDINAL);
  BEGIN
    IF ChildCount(host) >= 2 THEN
      SetRect(Child(host, 0), x, y, w DIV 2, h);
      SetRect(Child(host, 1), x + (w DIV 2), y, w - (w DIV 2), h)
    END
  END Arrange;
  OVERRIDE PROCEDURE HitTest (host: Pane; px, py: INTEGER): CARDINAL; BEGIN RETURN 0 END HitTest;
  OVERRIDE PROCEDURE Drag (host: Pane; handle: CARDINAL; dx, dy: INTEGER); BEGIN END Drag;
  OVERRIDE PROCEDURE DropAt (host: Pane; px, py: INTEGER; moved: Pane;
                             VAR zone: DropZone; VAR x, y, w, h: CARDINAL): BOOLEAN;
  BEGIN zone := NoDrop; RETURN FALSE END DropAt;
  OVERRIDE PROCEDURE Save (host: Pane; VAR blob: ARRAY OF CHAR): BOOLEAN; BEGIN RETURN FALSE END Save;
  OVERRIDE PROCEDURE Load (host: Pane; blob: ARRAY OF CHAR): BOOLEAN; BEGIN RETURN FALSE END Load;
END HalfSplit;

VAR ws: Workspace; win, win2: PaneWindow; root, a, b, root2, c, d: Pane; hs: HalfSplit;

PROCEDURE On (VAR e: Event): BOOLEAN; BEGIN RETURN FALSE END On;

PROCEDURE PrintRect (label: ARRAY OF CHAR; p: Pane);
  VAR x, y, w, h: CARDINAL;
BEGIN
  RectOf(p, x, y, w, h);
  WriteString(label);
  WriteCard(x, 1); WriteString(","); WriteCard(y, 1); WriteString(",");
  WriteCard(w, 1); WriteString(","); WriteCard(h, 1); WriteLn
END PrintRect;

BEGIN
  (* layout-bearing arrangement: HalfSplit assigns child rects on Retile *)
  a := LeafPane("a", NewRaster(10, 10)); b := LeafPane("b", NewRaster(10, 10));
  root := Arrange("root"); AddChild(root, a); AddChild(root, b);
  SetRect(root, 0, 0, 100, 40);
  NEW(hs); SetLayout(root, hs);
  win := OpenWindow(ws, "L", 100, 40, root, On);
  Retile(win);
  PrintRect("a-rect: ", a);
  PrintRect("b-rect: ", b);

  (* non-Layout arrangement: Retile leaves children untouched (the guard) *)
  c := LeafPane("c", NewRaster(10, 10)); d := LeafPane("d", NewRaster(10, 10));
  root2 := Arrange("root2"); AddChild(root2, c); AddChild(root2, d);
  SetRect(root2, 0, 0, 100, 40); SetRect(c, 7, 7, 7, 7); SetRect(d, 9, 9, 9, 9);
  win2 := OpenWindow(ws, "L2", 100, 40, root2, On);
  Retile(win2);
  PrintRect("c-rect: ", c);

  CloseWindow(win); CloseWindow(win2)
END T90267ELayout.
