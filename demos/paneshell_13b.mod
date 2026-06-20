MODULE PaneShell13b;
(* PaneShell worked example 13b (sprint S12): the whole stack, mutually nested on
   ONE Pane currency — reactive chrome (a sidebar split) wrapping an MDIContainer of
   documents, one of which is itself a reactive split (editor over output). All three
   facades compose; native controls are leaves; the window closes cleanly via the X
   (EvCloseRequest -> Quit, since the frame now controls its own close). Keys while a
   pane has focus:  F = float the active document,  T = tile,  C = cascade.
   Build:  newm2-driver build demos/paneshell_13b.mod  *)
<*GUI*>

FROM Surface IMPORT Backend, NewEdit, NewList, SetText, AddRow;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvCloseRequest, EvKey,
  LeafPane, SetRect, Init, OpenWindow, Retile, Run, Quit;
FROM PaneLayout IMPORT Orientation, Split;
IMPORT MDIContainer;

VAR ws: Workspace; win: PaneWindow; root, tree, docs, doc1, ed, outp, doc2: Pane;
    treeB, edB, outB, listB: Backend; idr: CARDINAL;

PROCEDURE OnEvent (VAR e: Event): BOOLEAN;
BEGIN
  IF e.kind = EvCloseRequest THEN Quit(ws)
  ELSIF e.kind = EvKey THEN
    IF    e.key = ORD('F') THEN MDIContainer.Float(docs, MDIContainer.ActiveDocument(docs)); Retile(win)
    ELSIF e.key = ORD('T') THEN MDIContainer.Tile(docs)
    ELSIF e.key = ORD('C') THEN MDIContainer.Cascade(docs)
    END
  END;
  RETURN FALSE
END OnEvent;

BEGIN
  ws := Init();

  (* a document that is itself a reactive split: editor over output (container ⊃ reactive) *)
  edB := NewEdit(TRUE); SetText(edB, "MODULE Hello;  (* edit me — this pane is the top of a vertical split *)");
  outB := NewEdit(TRUE); SetText(outB, "> build output streams into this lower pane");
  ed   := LeafPane("src", edB);
  outp := LeafPane("out", outB);
  doc1 := Split(Vertical, 0.70, 120, 60, ed, outp);

  doc2 := LeafPane("readme", NewList());
  listB := NIL;                                       (* (doc2's backend is created inside the leaf) *)

  (* the MDI document area (container ⊃ reactive + a plain leaf) *)
  docs := MDIContainer.Create(MDIContainer.Tabbed);
  idr := MDIContainer.AddDocument(docs, "hello.mod", doc1);
  idr := MDIContainer.AddDocument(docs, "README",    doc2);

  (* reactive chrome wrapping the MDI area (reactive ⊃ container); the sidebar is a control *)
  treeB := NewList();
  AddRow(treeB, "hello.mod"); AddRow(treeB, "README"); AddRow(treeB, "src/"); AddRow(treeB, "F=float T=tile C=cascade");
  tree := LeafPane("files", treeB);
  root := Split(Horizontal, 0.22, 160, 360, tree, docs);
  SetRect(root, 0, 0, 1100, 720);

  win := OpenWindow(ws, "PaneShell 13b — chrome (sidebar) over MDI over a split doc", 1100, 720, root, OnEvent);
  Retile(win);
  Run(ws)
END PaneShell13b.
