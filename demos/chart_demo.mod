MODULE ChartDemo;
(*
 * A business-graphics dashboard, drawn on the RasterView RGBA framebuffer with
 * the Chart library: a bar chart, a line chart, a pie chart and a legend, blitted
 * to a window with one GDI call (RasterView.Present). All the rendering is pure
 * Modula-2 over a pixel buffer — the same calls also export the exact image to a
 * .bmp file (press S).
 *
 *   build: newm2 build demos/chart_demo.mod   then run the .exe
 *   S  export the dashboard to dashboard.bmp        Esc  quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  RunMessageLoop, Quit;
FROM RasterView IMPORT Startup, Attach, Present, SaveBMP, Clear, Text;
FROM Chart IMPORT BarChart, LineChart, PieChart, LegendItem;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  W = 900; H = 560;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  VK_ESCAPE = 1BH;

VAR
  gWin:  Window;
  rev:   ARRAY [0..5] OF REAL;
  trend: ARRAY [0..11] OF REAL;
  share: ARRAY [0..3] OF REAL;
  cols:  ARRAY [0..3] OF CARDINAL;
  gMsg:  ARRAY [0..31] OF CHAR;

PROCEDURE RenderDashboard;
  VAR yy: INTEGER;
BEGIN
  Clear(0F2F4F7H);
  Text(28, 18, 3, 01A2A3AH, "NEWM2 BUSINESS DASHBOARD");
  BarChart(28, 68, 410, 230, rev, 6, "REVENUE BY QUARTER", 02E8B57H, 0404040H, 0FFFFFFH);
  LineChart(462, 68, 410, 230, trend, 12, "MONTHLY TREND", 0C8501EH, 0404040H, 0FFFFFFH);
  PieChart(170, 440, 95, share, 4, cols, "MARKET SHARE", 0FFFFFFH);
  yy := 350;
  yy := LegendItem(380, yy, cols[0], "PRODUCT A  45%");
  yy := LegendItem(380, yy, cols[1], "PRODUCT B  25%");
  yy := LegendItem(380, yy, cols[2], "PRODUCT C  18%");
  yy := LegendItem(380, yy, cols[3], "OTHER  12%");
  IF gMsg[0] # 0C THEN Text(380, yy + 14, 1, 02E8B57H, gMsg) END
END RenderDashboard;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Present(); ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF (ch = 's') OR (ch = 'S') THEN
      IF SaveBMP("dashboard.bmp") THEN gMsg := "saved dashboard.bmp" ELSE gMsg := "save FAILED" END;
      RenderDashboard; Repaint(w)
    END;
    RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF wParam = VK_ESCAPE THEN Quit END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  rev[0] := 42.0; rev[1] := 55.0; rev[2] := 38.0; rev[3] := 61.0; rev[4] := 70.0; rev[5] := 48.0;
  trend[0] := 12.0; trend[1] := 18.0; trend[2] := 15.0; trend[3] := 22.0;
  trend[4] := 30.0; trend[5] := 28.0; trend[6] := 35.0; trend[7] := 41.0;
  trend[8] := 38.0; trend[9] := 46.0; trend[10] := 52.0; trend[11] := 60.0;
  share[0] := 45.0; share[1] := 25.0; share[2] := 18.0; share[3] := 12.0;
  cols[0] := 02E8B57H; cols[1] := 01E6EC8H; cols[2] := 0E0A020H; cols[3] := 0C81E1EH;
  gMsg[0] := 0C;
  ok := Startup();
  gWin := CreateAppWindow("NewM2 Business Dashboard (RasterView + Chart)", W + 16, H + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, cw, ch) THEN HALT END;
  RenderDashboard;
  Present();
  Repaint(gWin);
  RunMessageLoop()
END ChartDemo.
