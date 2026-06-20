MODULE PaneShellTextGrid;
(* Proof that a GPU-accelerated Terminal pane (Surface.NewTextGrid = Terminal +
   TermRender Direct2D) renders inside a PaneShell window — via the new paint pump
   (WM_PAINT -> Backend.Paint) and Surface.TermOf (render into the leaf's Terminal).
   This is the FastM2 look (navy bg, syntax colours) on the Pane stack.
   Build:  newm2-driver build demos/paneshell_textgrid.mod --library library
             --out demos/paneshell_textgrid.exe *)
<*GUI*>
FROM Surface IMPORT Backend, NewTextGrid, TermOf;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvCloseRequest, EvResize,
  LeafPane, SetRect, Init, OpenWindow, Retile, Run, Quit;
IMPORT Terminal;

VAR ws: Workspace; win: PaneWindow; pane: Pane; grid: Backend;

PROCEDURE Render;
  VAR t: Terminal.Instance;
BEGIN
  t := TermOf(grid);
  IF t = NIL THEN RETURN END;
  Terminal.Use(t);
  Terminal.SetColour(Terminal.Silver, Terminal.Navy);
  Terminal.Clear;
  Terminal.WriteColAt(1, 0, Terminal.White,  Terminal.Navy, "MODULE Hello;");
  Terminal.WriteColAt(1, 1, Terminal.White,  Terminal.Navy, "FROM STextIO IMPORT WriteString, WriteLn;");
  Terminal.WriteColAt(1, 2, Terminal.White,  Terminal.Navy, "BEGIN");
  Terminal.WriteColAt(3, 3, Terminal.Silver, Terminal.Navy, "WriteString(");
  Terminal.WriteColAt(15,3, Terminal.Yellow, Terminal.Navy, '"hello from a GPU TextGrid pane"');
  Terminal.WriteColAt(47,3, Terminal.Silver, Terminal.Navy, "); WriteLn");
  Terminal.WriteColAt(1, 4, Terminal.White,  Terminal.Navy, "END Hello.");
  Terminal.WriteColAt(1, 6, Terminal.Gray,   Terminal.Navy, "(* navy bg, syntax colours = the FastM2 look, on PaneShell *)");
  Terminal.SetStatus("PaneShell TextGrid proof  -  resize me, close with X");
  grid.Paint
END Render;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN
  IF e.kind = EvCloseRequest THEN Quit(ws)
  ELSIF e.kind = EvResize THEN Render
  END;
  RETURN FALSE
END On;

BEGIN
  ws := Init();
  grid := NewTextGrid(100, 36, "Consolas", 15.0);
  pane := LeafPane("grid", grid);
  SetRect(pane, 0, 0, 900, 560);
  win := OpenWindow(ws, "PaneShell - GPU TextGrid pane", 900, 560, pane, On);
  Retile(win);
  Render;
  Run(ws)
END PaneShellTextGrid.
