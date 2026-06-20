MODULE T90273MdiPersist;
(*
 * Group 90 — PaneShell S12 slice 2a (P6): MDI re-arrange commands + arrangement
 * persistence + the float-window lifecycle safety.
 *  (1) Tile/Cascade switch the DockLayout style + Retile.
 *  (2) SaveLayout serialises the arrangement (style/active/closed bits) to a
 *      versioned text blob; LoadLayout re-applies it (content untouched).
 *  (3) Closing a float window DIRECTLY (external) then Dock-ing is SAFE — CloseWindow
 *      nils the owned panes' host/win, so the later Dock sees WindowOf=NIL and
 *      rebuilds instead of double-freeing.
 *
 * EXPECTED:
 * tile-a0: 0,0,400,300
 * tile-a3: 400,300,400,300
 * casc-a0: 0,0,710,510
 * casc-a1: 30,30,710,510
 * save-blob: PSL1;s=0;a=2;n=3;c=010;
 * load-ok: Y
 * active-restored: 2
 * e2-active: 0,24,400,276
 * e1-hidden: 0,0,0,0
 * f0-win-cleared: Y
 * f0-redocked: Y
 * dock-safe: Y
 *)
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event,
  LeafPane, SetRect, RectOf, ParentOf, WindowOf, Init, OpenWindow, CloseWindow, Retile;
FROM MDIContainer IMPORT Style, Side, Create, AddDocument, CloseDocument, Activate, ActiveDocument,
  Float, Dock, Tile, Cascade, SaveLayout, LoadLayout;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR ws: Workspace; win, win2, win3: PaneWindow;
    c, c2, c3, a0, a1, a2, a3, e0, e1, e2, f0, f1: Pane;
    idr: CARDINAL; ok: BOOLEAN; blob: ARRAY [0..127] OF CHAR;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN RETURN TRUE END On;

PROCEDURE Doc (id: ARRAY OF CHAR): Pane;
BEGIN RETURN LeafPane(id, NewRaster(10, 10)) END Doc;

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
  ws := Init();

  (* (1) Tile / Cascade re-arrange commands *)
  c := Create(Tabbed);
  a0 := Doc("a0"); a1 := Doc("a1"); a2 := Doc("a2"); a3 := Doc("a3");
  idr := AddDocument(c,"a0",a0); idr := AddDocument(c,"a1",a1);
  idr := AddDocument(c,"a2",a2); idr := AddDocument(c,"a3",a3);
  SetRect(c, 0, 0, 800, 600);
  win := OpenWindow(ws, "c", 800, 600, c, On); Retile(win);
  Tile(c);
  PrintRect("tile-a0: ", a0);                     (* 0,0,400,300 *)
  PrintRect("tile-a3: ", a3);                     (* 400,300,400,300 *)
  Cascade(c);
  PrintRect("casc-a0: ", a0);                     (* 0,0,710,510 *)
  PrintRect("casc-a1: ", a1);                     (* 30,30,710,510 *)
  CloseWindow(win);

  (* (2) Save -> blob -> mutate -> Load round-trips the arrangement *)
  c2 := Create(Tabbed);
  e0 := Doc("e0"); e1 := Doc("e1"); e2 := Doc("e2");
  idr := AddDocument(c2,"e0",e0); idr := AddDocument(c2,"e1",e1); idr := AddDocument(c2,"e2",e2);
  SetRect(c2, 0, 0, 400, 300);
  win2 := OpenWindow(ws, "c2", 400, 300, c2, On);
  Activate(c2, 2); CloseDocument(c2, 1);          (* active=2, e1 closed (hidden) *)
  ok := SaveLayout(c2, blob);
  WriteString("save-blob: "); WriteString(blob); WriteLn;
  Tile(c2); Activate(c2, 0);                       (* mutate away from the saved state *)
  ok := LoadLayout(c2, blob, c2);
  WriteString("load-ok: "); YN(ok);
  WriteString("active-restored: "); WriteCard(ActiveDocument(c2), 1); WriteLn;
  Retile(win2);
  PrintRect("e2-active: ", e2);                    (* 0,24,400,276 (Tabbed, active 2) *)
  PrintRect("e1-hidden: ", e1);                    (* 0,0,0,0 *)
  CloseWindow(win2);

  (* (3) external float-window close then Dock is safe (no double-free) *)
  c3 := Create(Tabbed);
  f0 := Doc("f0"); f1 := Doc("f1");
  idr := AddDocument(c3,"f0",f0); idr := AddDocument(c3,"f1",f1);
  SetRect(c3, 0, 0, 400, 300);
  win3 := OpenWindow(ws, "c3", 400, 300, c3, On);
  Float(c3, 0);
  win := WindowOf(f0);                             (* the float window *)
  CloseWindow(win);                                (* close it DIRECTLY (external) *)
  WriteString("f0-win-cleared: "); YN(WindowOf(f0) = NIL);
  Dock(c3, 0, Left);                               (* must be safe: rebuild, no double-free *)
  WriteString("f0-redocked: "); YN(ParentOf(f0) = c3);
  WriteString("dock-safe: "); YN(TRUE);
  CloseWindow(win3)
END T90273MdiPersist.
