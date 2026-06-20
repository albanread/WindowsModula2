MODULE T90272FloatDock;
(*
 * Group 90 — PaneShell S12 slice 1 (P6 part 2): MDI float/dock re-parenting + dock
 * zones. DockLayout.DropAt classifies a drop point over a region into a DropZone
 * (25% edge bands, nearest edge wins; centre = tabbed) and yields the target rect.
 * Float pops a document subtree into its OWN top-level window via the substrate's
 * ReparentToNewWindow (mechanic destroy+rebuild: BuildHosts repoints win/host across
 * the subtree); Dock is the inverse (ReparentInto + close the empty float frame).
 * Doc ids are stable (registry index), so a floated doc keeps its id off the child
 * list. EvDocFloated/EvDocDocked are LATCHED.
 *
 * DropZone ordinals: NoDrop=0 DockLeft=1 DockRight=2 DockTop=3 DockBottom=4 DockCentre=5
 *
 * EXPECTED:
 * drop-left: 1 0,0,400,600
 * drop-right: 2 400,0,400,600
 * drop-top: 3 0,0,800,300
 * drop-bottom: 4 0,300,800,300
 * drop-centre: 5 0,0,800,600
 * drop-outside-nodrop: Y
 * wins-before: 1
 * wins-after-float: 2
 * doc0-detached: Y
 * doc0-float: 0,0,400,300
 * float-evt: Y
 * wins-after-dock: 1
 * doc0-redocked: Y
 * dock-evt: Y
 *)
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, Layout, DropZone,
  EvDocFloated, EvDocDocked, LeafPane, SetRect, RectOf, Init, OpenWindow, CloseWindow,
  Retile, WindowCount, ParentOf, LayoutOf;
FROM MDIContainer IMPORT Style, Side, Create, AddDocument, Float, Dock;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR ws: Workspace; win: PaneWindow; c, d0, d1: Pane; lay: Layout;
    zone: DropZone; zx, zy, zw, zh: CARDINAL; ok: BOOLEAN;
    sawFloat, sawDock: BOOLEAN;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN
  IF e.kind = EvDocFloated THEN sawFloat := TRUE END;
  IF e.kind = EvDocDocked  THEN sawDock  := TRUE END;
  RETURN TRUE
END On;

PROCEDURE Zone (label: ARRAY OF CHAR; px, py: INTEGER);
BEGIN
  ok := lay.DropAt(c, px, py, NIL, zone, zx, zy, zw, zh);
  WriteString(label); WriteCard(ORD(zone), 1); WriteString(" ");
  WriteCard(zx,1); WriteString(","); WriteCard(zy,1); WriteString(",");
  WriteCard(zw,1); WriteString(","); WriteCard(zh,1); WriteLn
END Zone;

PROCEDURE PrintRect (label: ARRAY OF CHAR; p: Pane);
  VAR x, y, w, h: CARDINAL;
BEGIN
  RectOf(p, x, y, w, h); WriteString(label);
  WriteCard(x,1); WriteString(","); WriteCard(y,1); WriteString(",");
  WriteCard(w,1); WriteString(","); WriteCard(h,1); WriteLn
END PrintRect;

PROCEDURE YN (b: BOOLEAN);
BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

BEGIN
  sawFloat := FALSE; sawDock := FALSE;
  ws := Init();
  c := Create(Tabbed);
  d0 := LeafPane("d0", NewRaster(10, 10)); d1 := LeafPane("d1", NewRaster(10, 10));
  ok := AddDocument(c, "D0", d0) = 0;               (* (use the result; ids 0,1) *)
  ok := AddDocument(c, "D1", d1) = 1;
  SetRect(c, 0, 0, 800, 600);
  win := OpenWindow(ws, "MDI", 800, 600, c, On);
  Retile(win);
  lay := LayoutOf(c);

  (* ---- dock zones ---- *)
  Zone("drop-left: ",   10,  300);                  (* 1  0,0,400,600 *)
  Zone("drop-right: ",  790, 300);                  (* 2  400,0,400,600 *)
  Zone("drop-top: ",    400, 10);                   (* 3  0,0,800,300 *)
  Zone("drop-bottom: ", 400, 590);                  (* 4  0,300,800,300 *)
  Zone("drop-centre: ", 400, 300);                  (* 5  0,0,800,600 *)
  ok := lay.DropAt(c, -5, 300, NIL, zone, zx, zy, zw, zh);
  WriteString("drop-outside-nodrop: "); YN(NOT ok);

  (* ---- float doc 0 into its own window ---- *)
  WriteString("wins-before: "); WriteCard(WindowCount(ws), 1); WriteLn;
  Float(c, 0);
  WriteString("wins-after-float: "); WriteCard(WindowCount(ws), 1); WriteLn;
  WriteString("doc0-detached: "); YN(ParentOf(d0) = NIL);
  PrintRect("doc0-float: ", d0);                    (* 0,0,400,300 in its new window *)
  WriteString("float-evt: "); YN(sawFloat);

  (* ---- dock it back ---- *)
  Dock(c, 0, Left);
  WriteString("wins-after-dock: "); WriteCard(WindowCount(ws), 1); WriteLn;
  WriteString("doc0-redocked: "); YN(ParentOf(d0) = c);
  WriteString("dock-evt: "); YN(sawDock);

  CloseWindow(win)
END T90272FloatDock.
