MODULE Life;
(*
 * Conway's Game of Life — a text-mode (Terminal cell grid) animation in pure
 * Modula-2. The board is a torus (edges wrap), the classic B3/S23 rule runs each
 * generation, and the whole thing animates itself via the non-blocking message
 * pump (WinShell.PumpMessages) paced by ElapsedTime.Delay. You can paint cells
 * with the mouse, seed random soup or a glider, and step by hand.
 *
 * It exercises a different slice of the compiler again: a double-buffered 2-D
 * boolean array, wrap-around CARDINAL neighbour arithmetic, an animation loop
 * (pump + sleep) rather than a blocking message loop, and live mouse editing.
 *
 *   build: newm2 build demos/life.mod   then run the .exe
 *   Space  run / pause       S  single step      click  toggle a cell
 *   R  random soup           C  clear            G  drop a glider (centre)
 *   + / -  faster / slower    Esc  quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  PumpMessages, Quit;
FROM TermRender IMPORT Startup, Attach, Paint;
FROM Terminal IMPORT Init, Clear, Fill, WriteColAt, SetStatus,
  Black, Lime, Aqua, Yellow, Silver, Green;
FROM RandomNumbers IMPORT Randomize, Rnd;
FROM ElapsedTime IMPORT Delay;
FROM WholeStr IMPORT CardToStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  GW = 78; GH = 42;          (* grid cells (a torus) *)
  OX = 1;  OY = 2;           (* board origin in terminal cells *)
  Cols = OX + GW + 1;        (* 80 *)
  Rows = OY + GH + 1;        (* 45, status on the last row *)
  CellW = 12; CellH = 12;

  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  WM_LBUTTONDOWN = 513;
  VK_ESCAPE = 1BH;

  MinDelay = 10; MaxDelay = 320;

VAR
  gWin:     Window;
  cur, nxt: ARRAY [0..GW-1], [0..GH-1] OF BOOLEAN;
  gRunning: BOOLEAN;
  gDelay:   CARDINAL;        (* ms between generations *)
  gGen:     CARDINAL;
  gPop:     CARDINAL;

(* --- rendering ---------------------------------------------------------- *)

PROCEDURE DrawCell (x, y: CARDINAL);
BEGIN
  IF cur[x][y] THEN Fill(OX + x, OY + y, 1, 1, ' ', Black, Lime)
  ELSE Fill(OX + x, OY + y, 1, 1, ' ', Black, Black) END
END DrawCell;

PROCEDURE AppendStr (VAR dst: ARRAY OF CHAR; VAR pos: CARDINAL; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (pos < HIGH(dst)) DO
    dst[pos] := src[i]; INC(pos); INC(i)
  END;
  dst[pos] := 0C
END AppendStr;

PROCEDURE ShowStatus;
  VAR buf: ARRAY [0..119] OF CHAR; num: ARRAY [0..15] OF CHAR; pos: CARDINAL;
BEGIN
  pos := 0;
  IF gRunning THEN AppendStr(buf, pos, " RUN ") ELSE AppendStr(buf, pos, " PAUSE ") END;
  AppendStr(buf, pos, " gen "); CardToStr(gGen, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "  pop "); CardToStr(gPop, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "  | Space run  S step  R rand  C clear  G glider  +/- speed  click paint  Esc ");
  SetStatus(buf)
END ShowStatus;

PROCEDURE DrawBoard;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO DrawCell(x, y) END END;
  ShowStatus
END DrawBoard;

(* --- simulation --------------------------------------------------------- *)

(* One B3/S23 generation on a wrap-around board, double-buffered cur -> nxt. *)
PROCEDURE Step;
  VAR x, y, ddx, ddy, nx, ny, n, pop: CARDINAL;
BEGIN
  pop := 0;
  FOR x := 0 TO GW-1 DO
    FOR y := 0 TO GH-1 DO
      n := 0;
      FOR ddx := 0 TO 2 DO
        FOR ddy := 0 TO 2 DO
          IF (ddx # 1) OR (ddy # 1) THEN                 (* skip the centre cell *)
            nx := (x + ddx + GW - 1) MOD GW;             (* wrap, no underflow *)
            ny := (y + ddy + GH - 1) MOD GH;
            IF cur[nx][ny] THEN INC(n) END
          END
        END
      END;
      IF (n = 3) OR (cur[x][y] AND (n = 2)) THEN
        nxt[x][y] := TRUE; INC(pop)
      ELSE
        nxt[x][y] := FALSE
      END
    END
  END;
  FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO cur[x][y] := nxt[x][y] END END;
  gPop := pop; INC(gGen)
END Step;

PROCEDURE ClearBoard;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO cur[x][y] := FALSE END END;
  gGen := 0; gPop := 0
END ClearBoard;

PROCEDURE Randomize2;
  VAR x, y: CARDINAL;
BEGIN
  gPop := 0;
  FOR x := 0 TO GW-1 DO
    FOR y := 0 TO GH-1 DO
      IF Rnd(100) < 28 THEN cur[x][y] := TRUE; INC(gPop)    (* ~28% soup *)
      ELSE cur[x][y] := FALSE END
    END
  END;
  gGen := 0
END Randomize2;

PROCEDURE SetCell (x, y: CARDINAL; on: BOOLEAN);
BEGIN
  IF (x < GW) AND (y < GH) THEN cur[x][y] := on END
END SetCell;

PROCEDURE Glider (ox, oy: CARDINAL);
BEGIN
  (* a glider that travels down-right *)
  SetCell(ox+1, oy+0, TRUE);
  SetCell(ox+2, oy+1, TRUE);
  SetCell(ox+0, oy+2, TRUE);
  SetCell(ox+1, oy+2, TRUE);
  SetCell(ox+2, oy+2, TRUE)
END Glider;

PROCEDURE CountPop;
  VAR x, y, p: CARDINAL;
BEGIN
  p := 0;
  FOR x := 0 TO GW-1 DO FOR y := 0 TO GH-1 DO IF cur[x][y] THEN INC(p) END END END;
  gPop := p
END CountPop;

(* --- input -------------------------------------------------------------- *)

PROCEDURE Click (lParam: CARDINAL);
  VAR px, py, tc, tr, gx, gy: CARDINAL;
BEGIN
  px := lParam MOD 65536; py := lParam DIV 65536;
  tc := px DIV CellW; tr := py DIV CellH;
  IF (tc < OX) OR (tr < OY) THEN RETURN END;
  gx := tc - OX; gy := tr - OY;
  IF (gx >= GW) OR (gy >= GH) THEN RETURN END;
  cur[gx][gy] := NOT cur[gx][gy];
  CountPop
END Click;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Paint(); ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_LBUTTONDOWN THEN
    Click(lParam); DrawBoard; Repaint(w); RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF    ch = ' '                  THEN gRunning := NOT gRunning; ShowStatus; Repaint(w)
    ELSIF (ch = 's') OR (ch = 'S')  THEN Step; DrawBoard; Repaint(w)
    ELSIF (ch = 'r') OR (ch = 'R')  THEN Randomize2; DrawBoard; Repaint(w)
    ELSIF (ch = 'c') OR (ch = 'C')  THEN ClearBoard; DrawBoard; Repaint(w)
    ELSIF (ch = 'g') OR (ch = 'G')  THEN Glider(GW DIV 2, GH DIV 2); CountPop; DrawBoard; Repaint(w)
    ELSIF (ch = '+') OR (ch = '=')  THEN
      IF gDelay > MinDelay THEN gDelay := gDelay - gDelay DIV 3;
        IF gDelay < MinDelay THEN gDelay := MinDelay END END;
      ShowStatus; Repaint(w)
    ELSIF (ch = '-') OR (ch = '_')  THEN
      gDelay := gDelay + gDelay DIV 2 + 1;
      IF gDelay > MaxDelay THEN gDelay := MaxDelay END;
      ShowStatus; Repaint(w)
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
  Randomize(0);                                   (* auto-seed the PRNG *)
  gRunning := FALSE; gDelay := 80; gGen := 0; gPop := 0;
  ok := Startup("Consolas", VAL(SHORTREAL, 14.0));
  Init(Cols, Rows);
  Clear;
  WriteColAt(1, 0, Lime, Black, "NewM2 Life");
  WriteColAt(1, 1, Aqua, Black, "Conway's Game of Life - Space to run");
  ClearBoard;
  Randomize2;
  DrawBoard;
  gWin := CreateAppWindow("NewM2 Life", Cols*CellW + 16, Rows*CellH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  ok := Attach(gWin, cw, ch, CellW, CellH);
  Paint();
  Repaint(gWin);
  (* animation loop: pump messages, advance a generation each tick when running *)
  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    IF gRunning THEN Step; DrawBoard; Paint() END;
    Delay(gDelay)
  END
END Life.
