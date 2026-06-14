MODULE Mandelbrot;
(*
 * GUI Mandelbrot zoomer, in pure Modula-2 — a real program that exercises the
 * compiler (LONGREAL inner loop, the COM-backed Direct2D render path, a Win32
 * message loop) end to end.
 *
 * The escape-time set is drawn into the Terminal cell grid: each cell is one
 * "pixel" whose 24-bit BACKGROUND colour encodes how fast that point escaped.
 * The grid is painted with Direct2D/DirectWrite (TermRender) onto a real window
 * (WinShell) — no GDI.
 *
 * Run it:   newm2 run demos/mandelbrot.mod
 * or build: newm2 build demos/mandelbrot.mod   then run the .exe
 *
 *   arrows     pan the view
 *   + / =      zoom in        - / _      zoom out
 *   [ / ]      fewer / more iterations (sharper detail when deep)
 *   R          reset to the classic view
 *   Esc        quit (or close the window)
 *)
FROM SYSTEM IMPORT ADDRESS;
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  PumpMessages, Quit;
FROM TermRender IMPORT Startup, Attach, Paint;
FROM Terminal IMPORT Init, Fill, SetStatus;
FROM ElapsedTime IMPORT Delay;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  GCols = 160; GRows = 100;        (* the cell grid = the pixel canvas *)
  CellW = 6;   CellH = 6;          (* square cells -> correct aspect ratio *)
  HalfCols = GCols DIV 2;
  HalfRows = (GRows - 1) DIV 2;    (* bottom row is the status bar *)
  IterMin = 50; IterMax = 2000;

  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  VK_ESCAPE = 1BH; VK_LEFT = 25H; VK_UP = 26H; VK_RIGHT = 27H; VK_DOWN = 28H;

VAR
  gWin:      Window;
  cenX, cenY, span: LONGREAL;      (* view centre + horizontal span (complex units) *)
  maxIter:   CARDINAL;
  zoomLevel: CARDINAL;             (* net zoom-in count, for the status line *)
  gAuto:     BOOLEAN;              (* automatic "dive" animation running *)

(* ---- a smooth cyclic palette: a triangle wave per channel, phase-shifted ---- *)
PROCEDURE Band (iter, phase: CARDINAL): CARDINAL;
  VAR n: CARDINAL;
BEGIN
  n := (iter * 9 + phase) MOD 512;
  IF n >= 256 THEN n := 511 - n END;
  RETURN n
END Band;

PROCEDURE Colour (iter: CARDINAL): CARDINAL;
BEGIN
  IF iter >= maxIter THEN RETURN 0 END;                  (* interior: black *)
  RETURN Band(iter, 0) * 65536 + Band(iter, 160) * 256 + Band(iter, 320)
END Colour;

(* ---- compute the whole canvas into the cell grid ---- *)
PROCEDURE Render;
  VAR col, row, iter: CARDINAL;
      step, x0, y0, x, y, x2, y2: LONGREAL;
BEGIN
  step := span / VAL(LONGREAL, GCols);
  row := 0;
  WHILE row < GRows - 1 DO
    y0 := cenY + VAL(LONGREAL, VAL(INTEGER, row) - VAL(INTEGER, HalfRows)) * step;
    col := 0;
    WHILE col < GCols DO
      x0 := cenX + VAL(LONGREAL, VAL(INTEGER, col) - VAL(INTEGER, HalfCols)) * step;
      x := 0.0; y := 0.0; x2 := 0.0; y2 := 0.0; iter := 0;
      WHILE (x2 + y2 <= 4.0) AND (iter < maxIter) DO
        y  := 2.0 * x * y + y0;
        x  := x2 - y2 + x0;
        x2 := x * x;
        y2 := y * y;
        INC(iter)
      END;
      Fill(col, row, 1, 1, ' ', 0, Colour(iter));
      INC(col)
    END;
    INC(row)
  END
END Render;

(* ---- tiny string builders for the status line ---- *)
PROCEDURE StrApp (VAR dst: ARRAY OF CHAR; VAR pos: CARDINAL; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (pos < HIGH(dst)) DO
    dst[pos] := src[i]; INC(pos); INC(i)
  END;
  dst[pos] := 0C
END StrApp;

PROCEDURE CardApp (VAR dst: ARRAY OF CHAR; VAR pos: CARDINAL; v: CARDINAL);
  VAR digs: ARRAY [0..15] OF CHAR; n, i: CARDINAL;
BEGIN
  IF v = 0 THEN
    IF pos < HIGH(dst) THEN dst[pos] := '0'; INC(pos) END;
    dst[pos] := 0C; RETURN
  END;
  n := 0;
  WHILE v > 0 DO digs[n] := CHR(ORD('0') + (v MOD 10)); INC(n); v := v DIV 10 END;
  i := n;
  WHILE (i > 0) AND (pos < HIGH(dst)) DO DEC(i); dst[pos] := digs[i]; INC(pos) END;
  dst[pos] := 0C
END CardApp;

PROCEDURE UpdateStatus;
  VAR s: ARRAY [0..159] OF CHAR; pos: CARDINAL;
BEGIN
  pos := 0;
  IF gAuto THEN StrApp(s, pos, " [DIVE] ") ELSE StrApp(s, pos, " ") END;
  StrApp(s, pos, "Mandelbrot  A auto-dive  arrows pan  +/- zoom  [ ] iter  R reset  Esc quit   zoom=");
  CardApp(s, pos, zoomLevel);
  StrApp(s, pos, "  iter=");
  CardApp(s, pos, maxIter);
  StrApp(s, pos, " ");
  SetStatus(s)
END UpdateStatus;

PROCEDURE Reset;
BEGIN
  cenX := -0.5; cenY := 0.0; span := 3.0; maxIter := 100; zoomLevel := 0
END Reset;

PROCEDURE Redraw;
BEGIN
  Render; UpdateStatus; Repaint(gWin)
END Redraw;

PROCEDURE ZoomIn;
BEGIN
  span := span * 0.7; INC(zoomLevel);
  IF maxIter < IterMax THEN INC(maxIter, 12) END        (* keep detail as we dive *)
END ZoomIn;

PROCEDURE ZoomOut;
BEGIN
  span := span / 0.7;
  IF zoomLevel > 0 THEN DEC(zoomLevel) END;
  IF maxIter > IterMin + 12 THEN DEC(maxIter, 12) END
END ZoomOut;

(* One frame of the automatic dive: ease the view centre toward a famous spiral
   point while shrinking the span, deepening the iteration cap as we descend.
   When the span hits LONGREAL's precision floor, loop back to the full view so
   the dive runs forever. *)
PROCEDURE AutoStep;
BEGIN
  cenX := cenX + (-0.743643887037151 - cenX) * 0.04;
  cenY := cenY + ( 0.131825904205330 - cenY) * 0.04;
  span := span * 0.97;
  INC(zoomLevel);
  IF maxIter < IterMax THEN INC(maxIter, 3) END;
  IF span < 3.0E-13 THEN
    cenX := -0.5; cenY := 0.0; span := 3.0; maxIter := 100; zoomLevel := 0
  END
END AutoStep;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Paint();
    ok := ValidateRect(w, NIL);
    RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF    wParam = VK_LEFT   THEN cenX := cenX - span * 0.10; Redraw
    ELSIF wParam = VK_RIGHT  THEN cenX := cenX + span * 0.10; Redraw
    ELSIF wParam = VK_UP     THEN cenY := cenY - span * 0.10; Redraw
    ELSIF wParam = VK_DOWN   THEN cenY := cenY + span * 0.10; Redraw
    ELSIF wParam = VK_ESCAPE THEN Quit
    END;
    RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF    (ch = '+') OR (ch = '=') THEN ZoomIn;  Redraw
    ELSIF (ch = '-') OR (ch = '_') THEN ZoomOut; Redraw
    ELSIF (ch = '[')               THEN IF maxIter > IterMin THEN DEC(maxIter, 25); Redraw END
    ELSIF (ch = ']')               THEN IF maxIter < IterMax THEN INC(maxIter, 25); Redraw END
    ELSIF (ch = 'r') OR (ch = 'R') THEN Reset; Redraw
    ELSIF (ch = 'a') OR (ch = 'A') OR (ch = ' ') THEN gAuto := NOT gAuto; UpdateStatus; Repaint(w)
    END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  Reset;
  gAuto := FALSE;
  ok := Startup("Consolas", VAL(SHORTREAL, 6.0));
  Init(GCols, GRows);
  Render;
  UpdateStatus;
  gWin := CreateAppWindow("NewM2 Mandelbrot", GCols * CellW + 16, GRows * CellH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  ok := Attach(gWin, cw, ch, CellW, CellH);
  Paint();
  Repaint(gWin);
  (* pump messages; when the dive is on, advance + repaint one frame per tick.
     Manual key/paint changes render synchronously in the handler (Redraw). *)
  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    IF gAuto THEN AutoStep; Render; UpdateStatus; Paint() END;
    Delay(16)
  END
END Mandelbrot.
