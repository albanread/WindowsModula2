MODULE T90272bFloatHardening;
(*
 * Group 90 — PaneShell S12 slice 1 hardening (post adversarial review). Four fixes:
 *  (1) Realize: a document added AT RUNTIME (after OpenWindow) gets a host and so
 *      displays + can float (previously it was a hostless child that never showed).
 *  (2) Float the ACTIVE doc: `active` advances to another docked doc so a Tabbed
 *      container does not render blank (previously activePane went NIL).
 *  (3) Float fail-safe: floating a doc whose container is not windowed is REFUSED
 *      before the irreversible Detach, so the doc is never orphaned.
 *  (4) CloseDocument on a FLOATED doc closes its window (no leak / no no-op).
 *
 * EXPECTED:
 * d2-hosted: Y
 * d2-realized: 0,300,400,300
 * active-after-float: 1
 * a1-visible: 0,24,400,276
 * refused-safe: Y
 * wins-before-close: 3
 * wins-after-close: 2
 * close-evt: Y
 *)
FROM SYSTEM IMPORT ADDRESS;
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvDocClosed,
  LeafPane, SetRect, RectOf, HostOf, ParentOf, Init, OpenWindow, CloseWindow,
  Retile, WindowCount;
FROM MDIContainer IMPORT Style, Create, AddDocument, CloseDocument, Activate, ActiveDocument, Float;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR ws: Workspace; win, wint: PaneWindow;
    c, ct, cn, d0, d1, d2, a0, a1, dn: Pane; idr: CARDINAL; sawClosed: BOOLEAN;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN IF e.kind = EvDocClosed THEN sawClosed := TRUE END; RETURN TRUE END On;

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
  sawClosed := FALSE;
  ws := Init();

  (* (1) runtime AddDocument is realized (hosted) and tiles into the grid *)
  c := Create(Tiled);
  d0 := Doc("d0"); d1 := Doc("d1");
  idr := AddDocument(c, "d0", d0); idr := AddDocument(c, "d1", d1);
  SetRect(c, 0, 0, 800, 600);
  win := OpenWindow(ws, "c", 800, 600, c, On);
  Retile(win);
  d2 := Doc("d2"); idr := AddDocument(c, "d2", d2);    (* added AFTER the window exists *)
  Retile(win);
  WriteString("d2-hosted: "); YN(HostOf(d2) # NIL);
  PrintRect("d2-realized: ", d2);                       (* 0,300,400,300 (3-doc 2x2 grid) *)

  (* (2) floating the active doc advances `active` and keeps the Tabbed area visible *)
  ct := Create(Tabbed);
  a0 := Doc("a0"); a1 := Doc("a1");
  idr := AddDocument(ct, "a0", a0); idr := AddDocument(ct, "a1", a1);
  SetRect(ct, 0, 0, 400, 300);
  wint := OpenWindow(ws, "ct", 400, 300, ct, On);
  Activate(ct, 0); Retile(wint);
  Float(ct, 0);                                         (* float the ACTIVE doc *)
  WriteString("active-after-float: "); WriteCard(ActiveDocument(ct), 1); WriteLn;   (* 1 *)
  Retile(wint);
  PrintRect("a1-visible: ", a1);                        (* 0,24,400,276 — not blank *)

  (* (3) floating a doc whose container is not windowed is refused (no orphan) *)
  cn := Create(Tabbed);
  dn := Doc("dn"); idr := AddDocument(cn, "dn", dn);
  Float(cn, 0);
  WriteString("refused-safe: "); YN(ParentOf(dn) = cn);

  (* (4) CloseDocument on the floated doc closes its window (no leak) *)
  WriteString("wins-before-close: "); WriteCard(WindowCount(ws), 1); WriteLn;   (* win + ct + float = 3 *)
  CloseDocument(ct, 0);
  WriteString("wins-after-close: "); WriteCard(WindowCount(ws), 1); WriteLn;    (* 2 *)
  WriteString("close-evt: "); YN(sawClosed);

  CloseWindow(win); CloseWindow(wint)
END T90272bFloatHardening.
