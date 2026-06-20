MODULE T90267PaneTree;
(*
 * Group 90 — PaneShell S7 (P3) slice 1: the universal Pane as a heap tree node.
 * Fully headless — the Pane TREE (leaves under an arrangement), the named-pane
 * registry (PaneByName / BackendOf), per-pane rects (SetRect / RectOf), and the
 * DumpTree introspection probe. No host HWNDs / window / solver yet (next slice).
 *
 * EXPECTED:
 * found-console: Y
 * found-missing: Y
 * leaf-backend: Y
 * arrange-backend: Y
 * a-rect: 0,0,70,50
 * dump: root:A(0,0,100,50)[canvas:L(0,0,70,50) console:L(70,0,30,50)]
 *)
FROM Surface IMPORT Backend, NewCanvas, NewRaster;
FROM PaneShell IMPORT Pane, LeafPane, Arrange, AddChild, PaneByName, BackendOf,
  RectOf, SetRect, DumpTree;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR root, a, b: Pane; x, y, w, h: CARDINAL; s: ARRAY [0..255] OF CHAR;

PROCEDURE YN (cond: BOOLEAN);
BEGIN IF cond THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

BEGIN
  a := LeafPane("canvas",  NewCanvas());
  b := LeafPane("console", NewRaster(40, 25));
  root := Arrange("root");
  AddChild(root, a);
  AddChild(root, b);
  SetRect(root, 0, 0, 100, 50);
  SetRect(a,    0, 0,  70, 50);
  SetRect(b,   70, 0,  30, 50);

  WriteString("found-console: ");   YN(PaneByName(root, "console") = b);
  WriteString("found-missing: ");    YN(PaneByName(root, "nope") = NIL);
  WriteString("leaf-backend: ");     YN(BackendOf(a) # NIL);
  WriteString("arrange-backend: ");  YN(BackendOf(root) = NIL);    (* arrangement has no backend *)

  RectOf(a, x, y, w, h);
  WriteString("a-rect: ");
  WriteCard(x, 1); WriteString(","); WriteCard(y, 1); WriteString(",");
  WriteCard(w, 1); WriteString(","); WriteCard(h, 1); WriteLn;

  DumpTree(root, s);
  WriteString("dump: "); WriteString(s); WriteLn
END T90267PaneTree.
