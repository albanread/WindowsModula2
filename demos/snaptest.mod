MODULE SnapTest;
<*GUI*>
FROM Surface IMPORT Backend, NewTextGrid, TermOf;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvCloseRequest,
  LeafPane, SetRect, Init, OpenWindow, Retile, RunBounded, FrameOf;
FROM Harness IMPORT SnapClient;
IMPORT Terminal;

VAR ws: Workspace; win: PaneWindow; pane: Pane; grid: Backend; b: BOOLEAN;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN RETURN FALSE END On;

BEGIN
  ws := Init();
  grid := NewTextGrid(80, 25, "Consolas", 15.0);
  pane := LeafPane("g", grid);
  SetRect(pane, 0, 0, 640, 400);
  win := OpenWindow(ws, "snaptest", 640, 400, pane, On);
  Retile(win);
  RunBounded(ws, 8);                       (* show + pump + auto-retile *)
  Terminal.Use(TermOf(grid));
  Terminal.SetColour(Terminal.Silver, Terminal.Navy); Terminal.Clear;
  Terminal.WriteColAt(2, 2, Terminal.Yellow, Terminal.Navy, "SNAP TEST: if you can read this, capture works");
  grid.Paint;
  RunBounded(ws, 2);
  b := SnapClient(FrameOf(win), "e:\NewModula2\snaptest.png")
END SnapTest.
