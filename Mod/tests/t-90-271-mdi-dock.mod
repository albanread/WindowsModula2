MODULE T90271MdiDock;
(*
 * Group 90 — PaneShell S11 (P6 part 1): MDIContainer = DockLayout, an MDI document
 * area implemented as just ANOTHER PaneShell.Layout over the same Pane tree. Three
 * arrangements: Tiled (a near-square grid), Tabbed (active doc below a 24px strip,
 * others 0-rect), Cascaded (offset stack). Documents are ordinary Panes added via
 * AddDocument (id = stable child index). Activate switches the active doc + raises
 * EvDocActivated (LATCHED — the real frame's WM_SIZE->EvResize would clobber a
 * last-kind read). CloseDocument hides a doc; the arrangement redistributes.
 *
 * EXPECTED:
 * ids: 0,1,2,3
 * d0: 0,0,400,300
 * d1: 400,0,400,300
 * d2: 0,300,400,300
 * d3: 400,300,400,300
 * e1-active: 0,24,400,276
 * e0-hidden: 0,0,0,0
 * active: 1
 * doc-evt: Y
 * f0: 0,0,740,540
 * f1: 30,30,740,540
 * f2: 60,60,740,540
 * f1-closed: 0,0,0,0
 * f0-recascade: 0,0,770,570
 *)
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvDocActivated,
  LeafPane, SetRect, RectOf, Init, OpenWindow, CloseWindow, Retile;
FROM MDIContainer IMPORT Style, Create, AddDocument, CloseDocument, Activate, ActiveDocument;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR ws: Workspace; win, win2, win3: PaneWindow;
    c, c2, c3, d0, d1, d2, d3, e0, e1, e2, f0, f1, f2: Pane;
    i0, i1, i2, i3: CARDINAL; sawAct: BOOLEAN;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN IF e.kind = EvDocActivated THEN sawAct := TRUE END; RETURN TRUE END On;

PROCEDURE PrintRect (label: ARRAY OF CHAR; p: Pane);
  VAR x, y, w, h: CARDINAL;
BEGIN
  RectOf(p, x, y, w, h); WriteString(label);
  WriteCard(x,1); WriteString(","); WriteCard(y,1); WriteString(",");
  WriteCard(w,1); WriteString(","); WriteCard(h,1); WriteLn
END PrintRect;

PROCEDURE YN (c: BOOLEAN);
BEGIN IF c THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

PROCEDURE Doc (id: ARRAY OF CHAR): Pane;
BEGIN RETURN LeafPane(id, NewRaster(10, 10)) END Doc;

BEGIN
  sawAct := FALSE;
  ws := Init();

  (* ---- Tiled: 4 docs in a 2x2 grid ---- *)
  c := Create(Tiled);
  d0 := Doc("d0"); d1 := Doc("d1"); d2 := Doc("d2"); d3 := Doc("d3");
  i0 := AddDocument(c, "D0", d0); i1 := AddDocument(c, "D1", d1);
  i2 := AddDocument(c, "D2", d2); i3 := AddDocument(c, "D3", d3);
  SetRect(c, 0, 0, 800, 600);
  win := OpenWindow(ws, "MDI", 800, 600, c, On);
  Retile(win);
  WriteString("ids: ");
  WriteCard(i0,1); WriteString(","); WriteCard(i1,1); WriteString(",");
  WriteCard(i2,1); WriteString(","); WriteCard(i3,1); WriteLn;
  PrintRect("d0: ", d0); PrintRect("d1: ", d1);
  PrintRect("d2: ", d2); PrintRect("d3: ", d3);
  CloseWindow(win);

  (* ---- Tabbed: 3 docs, activate #1 after the window exists (so the event fans) ---- *)
  c2 := Create(Tabbed);
  e0 := Doc("e0"); e1 := Doc("e1"); e2 := Doc("e2");
  i0 := AddDocument(c2, "E0", e0); i1 := AddDocument(c2, "E1", e1); i2 := AddDocument(c2, "E2", e2);
  SetRect(c2, 0, 0, 400, 300);
  win2 := OpenWindow(ws, "MDI2", 400, 300, c2, On);
  Activate(c2, 1); Retile(win2);
  PrintRect("e1-active: ", e1);                  (* 0,24,400,276 *)
  PrintRect("e0-hidden: ", e0);                  (* 0,0,0,0 *)
  WriteString("active: "); WriteCard(ActiveDocument(c2), 1); WriteLn;
  WriteString("doc-evt: "); YN(sawAct);
  CloseWindow(win2);

  (* ---- Cascaded: 3 docs, then close the middle one ---- *)
  c3 := Create(Cascaded);
  f0 := Doc("f0"); f1 := Doc("f1"); f2 := Doc("f2");
  i0 := AddDocument(c3, "F0", f0); i1 := AddDocument(c3, "F1", f1); i2 := AddDocument(c3, "F2", f2);
  SetRect(c3, 0, 0, 800, 600);
  win3 := OpenWindow(ws, "MDI3", 800, 600, c3, On);
  Retile(win3);
  PrintRect("f0: ", f0); PrintRect("f1: ", f1); PrintRect("f2: ", f2);
  CloseDocument(c3, 1); Retile(win3);            (* hide f1 -> 2 visible re-cascade *)
  PrintRect("f1-closed: ", f1);                  (* 0,0,0,0 *)
  PrintRect("f0-recascade: ", f0);               (* 0,0,770,570 *)
  CloseWindow(win3)
END T90271MdiDock.
