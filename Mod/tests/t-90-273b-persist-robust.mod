MODULE T90273bPersistRobust;
(*
 * Group 90 — PaneShell S12 slice 2a hardening (post adversarial review). The
 * arrangement (de)serializer must be robust to undersized buffers and malformed
 * input:
 *  (1) SaveLayout into a too-small blob returns FALSE (truncation signalled) and
 *      still NUL-terminates (no silent success).
 *  (2) LoadLayout of a wrong-magic / foreign blob returns FALSE and mutates nothing
 *      (active is unchanged) — fail closed.
 *  (3) LoadLayout of a valid-magic but TRUNCATED bit field returns FALSE and does
 *      not half-apply (active unchanged).
 *
 * EXPECTED:
 * trunc-signaled: Y
 * bad-magic-rejected: Y
 * truncated-rejected: Y
 * active-intact: 2
 *)
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event,
  LeafPane, SetRect, Init, OpenWindow, CloseWindow, Retile;
FROM MDIContainer IMPORT Style, Create, AddDocument, Activate, ActiveDocument, SaveLayout, LoadLayout;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR ws: Workspace; win: PaneWindow; c, e0, e1, e2: Pane;
    idr: CARDINAL; ok: BOOLEAN;
    small: ARRAY [0..7] OF CHAR;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN RETURN TRUE END On;

PROCEDURE YN (b: BOOLEAN);
BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

BEGIN
  ws := Init();
  c := Create(Tabbed);
  e0 := LeafPane("e0", NewRaster(10,10));
  e1 := LeafPane("e1", NewRaster(10,10));
  e2 := LeafPane("e2", NewRaster(10,10));
  idr := AddDocument(c,"e0",e0); idr := AddDocument(c,"e1",e1); idr := AddDocument(c,"e2",e2);
  SetRect(c, 0, 0, 400, 300);
  win := OpenWindow(ws, "c", 400, 300, c, On);
  Activate(c, 2);                                    (* active = 2 *)

  (* (1) save into a buffer far too small -> FALSE *)
  ok := SaveLayout(c, small);
  WriteString("trunc-signaled: "); YN(NOT ok);

  (* (2) foreign/wrong-magic blob -> rejected, no mutation *)
  ok := LoadLayout(c, "NOPE;s=1;a=0;n=3;c=000;", c);
  WriteString("bad-magic-rejected: "); YN(NOT ok);

  (* (3) valid magic but the bit field is truncated -> rejected, no half-apply *)
  ok := LoadLayout(c, "PSL1;s=1;a=0;n=3;c=0", c);
  WriteString("truncated-rejected: "); YN(NOT ok);

  (* active must be untouched by the two rejected loads *)
  WriteString("active-intact: "); WriteCard(ActiveDocument(c), 1); WriteLn;

  CloseWindow(win)
END T90273bPersistRobust.
