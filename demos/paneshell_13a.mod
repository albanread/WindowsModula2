MODULE PaneShell13a;
(* PaneShell worked example 13a (sprint S10): a real, runnable AOT window proving
   the full reactive stack end to end — a 70/30 horizontal Split of two native
   controls (a multiline editor on the left, a list on the right) with a DRAGGABLE
   divider. Grab the vertical seam between the panes and drag: the substrate's
   parent-walk routes the mouse to the split's Layout, re-weights, and Retile moves
   both host windows (and, via Backend.Resize, the controls inside them). Close the
   window to quit. Build:  newm2-driver build demos/paneshell_13a.mod  *)
<*GUI*>

FROM Surface IMPORT Backend, NewEdit, NewList, SetText, AddRow;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvCloseRequest,
  LeafPane, SetRect, Init, OpenWindow, Retile, Run, Quit;
FROM PaneLayout IMPORT Orientation, Split;

VAR ws: Workspace; win: PaneWindow; root, left, right: Pane; edit, list: Backend;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN
  IF e.kind = EvCloseRequest THEN Quit(ws) END;
  RETURN FALSE
END On;

BEGIN
  ws := Init();

  edit := NewEdit(TRUE);                              (* multiline editor — the left pane *)
  SetText(edit, "PaneShell 13a — drag the vertical divider to resize 70/30.");

  list := NewList();                                  (* a list control — the right pane *)
  AddRow(list, "Reactive Split (PaneLayout)");
  AddRow(list, "Draggable divider (S9 HitTest/Drag)");
  AddRow(list, "Live message loop (S10 Run)");
  AddRow(list, "Parent-walk mouse routing");
  AddRow(list, "Close this window to quit.");

  left  := LeafPane("editor", edit);
  right := LeafPane("panel",  list);
  root  := Split(Horizontal, 0.70, 220, 180, left, right);
  SetRect(root, 0, 0, 900, 560);

  win := OpenWindow(ws, "PaneShell 13a — draggable split", 900, 560, root, On);
  Retile(win);
  Run(ws)                                             (* block on the real loop until close *)
END PaneShell13a.
