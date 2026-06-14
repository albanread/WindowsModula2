MODULE Minesweeper;
(*
 * Minesweeper — a mouse-driven GUI game in pure Modula-2, rendered on the
 * Terminal cell grid (Direct2D/DirectWrite via TermRender, window + message
 * loop via WinShell). It exercises a different part of the compiler than the
 * shader demos: 2-D arrays and records, recursion (the flood-fill reveal of
 * empty regions), CARDINAL-safe neighbour arithmetic, mouse hit-testing
 * (decoding WM_LBUTTONDOWN / WM_RBUTTONDOWN coordinates), and the lagged-
 * Fibonacci RandomNumbers generator for mine placement.
 *
 *   build: newm2 build demos/minesweeper.mod   then run the .exe
 *   Left-click  reveal      Right-click  flag/unflag
 *   R  new game             Esc  quit
 *
 * First click is always safe: the mines are laid down on the first reveal,
 * avoiding the clicked cell and its eight neighbours.
 *)
FROM SYSTEM IMPORT ADDRESS;
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  RunMessageLoop, Quit;
FROM TermRender IMPORT Startup, Attach, Paint;
FROM Terminal IMPORT
  Init, Clear, Fill, WriteColAt, SetStatus, Colour,
  Black, Maroon, Green, Navy, Teal, Silver, Gray, Red, Lime, Yellow, Blue,
  Aqua, White;
FROM RandomNumbers IMPORT Randomize, Random;
FROM WholeStr IMPORT CardToStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  GRID = 16;            (* board is GRID x GRID *)
  MINES = 40;
  OX = 2; OY = 3;       (* board origin in terminal cells (col, row) *)
  Cols = OX + GRID + 2; (* 20 *)
  Rows = OY + GRID + 2; (* 21, status bar on the last row *)
  CellW = 26; CellH = 26;

  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  WM_LBUTTONDOWN = 513; WM_RBUTTONDOWN = 516;
  VK_ESCAPE = 1BH;

VAR
  gWin:       Window;
  mine, revealed, flagged: ARRAY [0..GRID-1], [0..GRID-1] OF BOOLEAN;
  count:      ARRAY [0..GRID-1], [0..GRID-1] OF CARDINAL;
  gFirst:     BOOLEAN;     (* mines not yet placed *)
  gOver:      BOOLEAN;
  gWon:       BOOLEAN;
  gRevealed:  CARDINAL;    (* non-mine cells uncovered so far *)
  gFlags:     CARDINAL;

(* --- helpers ------------------------------------------------------------ *)

PROCEDURE NumColour (n: CARDINAL): Colour;
BEGIN
  CASE n OF
    1: RETURN Blue
  | 2: RETURN Green
  | 3: RETURN Red
  | 4: RETURN Navy
  | 5: RETURN Maroon
  | 6: RETURN Teal
  | 7: RETURN Black
  | 8: RETURN Gray
  ELSE RETURN Black
  END
END NumColour;

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
  VAR buf: ARRAY [0..79] OF CHAR; num: ARRAY [0..15] OF CHAR; pos: CARDINAL;
BEGIN
  pos := 0;
  IF gWon THEN
    AppendStr(buf, pos, " You WIN! ")
  ELSIF gOver THEN
    AppendStr(buf, pos, " BOOM - game over. ")
  ELSE
    AppendStr(buf, pos, " Mines left: ");
    IF gFlags <= MINES THEN CardToStr(MINES - gFlags, num) ELSE CardToStr(0, num) END;
    AppendStr(buf, pos, num);
    AppendStr(buf, pos, "  ")
  END;
  AppendStr(buf, pos, " | L: reveal  R: flag  Key R: new  Esc: quit ");
  SetStatus(buf)
END ShowStatus;

(* --- rendering ---------------------------------------------------------- *)

PROCEDURE DrawCell (gx, gy: CARDINAL);
  VAR tc, tr, n: CARDINAL;
BEGIN
  tc := OX + gx; tr := OY + gy;
  IF revealed[gx][gy] THEN
    IF mine[gx][gy] THEN
      Fill(tc, tr, 1, 1, '*', White, Red)
    ELSE
      n := count[gx][gy];
      IF n = 0 THEN Fill(tc, tr, 1, 1, ' ', Silver, Silver)
      ELSE Fill(tc, tr, 1, 1, CHR(ORD('0') + n), NumColour(n), Silver) END
    END
  ELSIF flagged[gx][gy] THEN
    Fill(tc, tr, 1, 1, 'F', Maroon, Gray)
  ELSE
    Fill(tc, tr, 1, 1, ' ', Gray, Gray)
  END
END DrawCell;

PROCEDURE DrawBoard;
  VAR gx, gy: CARDINAL;
BEGIN
  FOR gx := 0 TO GRID-1 DO
    FOR gy := 0 TO GRID-1 DO DrawCell(gx, gy) END
  END;
  ShowStatus
END DrawBoard;

(* --- game logic --------------------------------------------------------- *)

(* TRUE when CARDINALs a and b differ by at most 1 (no underflow). *)
PROCEDURE Near (a, b: CARDINAL): BOOLEAN;
BEGIN
  IF a >= b THEN RETURN (a - b) <= 1 ELSE RETURN (b - a) <= 1 END
END Near;

PROCEDURE PlaceMines (ax, ay: CARDINAL);
  VAR placed, mx, my: CARDINAL;
BEGIN
  placed := 0;
  WHILE placed < MINES DO
    mx := Random(0, GRID-1); my := Random(0, GRID-1);
    IF (NOT mine[mx][my]) AND NOT (Near(mx, ax) AND Near(my, ay)) THEN
      mine[mx][my] := TRUE; INC(placed)
    END
  END
END PlaceMines;

PROCEDURE ComputeCounts;
  VAR gx, gy, ddx, ddy, nx, ny, c: CARDINAL;
BEGIN
  FOR gx := 0 TO GRID-1 DO
    FOR gy := 0 TO GRID-1 DO
      c := 0;
      FOR ddx := 0 TO 2 DO
        FOR ddy := 0 TO 2 DO
          IF (ddx # 1) OR (ddy # 1) THEN          (* skip the centre cell *)
            IF (gx + ddx >= 1) AND (gy + ddy >= 1) THEN
              nx := gx + ddx - 1; ny := gy + ddy - 1;
              IF (nx < GRID) AND (ny < GRID) AND mine[nx][ny] THEN INC(c) END
            END
          END
        END
      END;
      count[gx][gy] := c
    END
  END
END ComputeCounts;

(* Reveal a cell; flood-fill outward through cells with no adjacent mines. *)
PROCEDURE RevealAt (gx, gy: CARDINAL);
  VAR ddx, ddy, nx, ny: CARDINAL;
BEGIN
  IF revealed[gx][gy] OR flagged[gx][gy] THEN RETURN END;
  revealed[gx][gy] := TRUE;
  IF mine[gx][gy] THEN gOver := TRUE; gWon := FALSE; RETURN END;
  INC(gRevealed);
  IF count[gx][gy] = 0 THEN
    FOR ddx := 0 TO 2 DO
      FOR ddy := 0 TO 2 DO
        IF (ddx # 1) OR (ddy # 1) THEN
          IF (gx + ddx >= 1) AND (gy + ddy >= 1) THEN
            nx := gx + ddx - 1; ny := gy + ddy - 1;
            IF (nx < GRID) AND (ny < GRID) THEN RevealAt(nx, ny) END
          END
        END
      END
    END
  END
END RevealAt;

PROCEDURE RevealAllMines;
  VAR gx, gy: CARDINAL;
BEGIN
  FOR gx := 0 TO GRID-1 DO
    FOR gy := 0 TO GRID-1 DO
      IF mine[gx][gy] THEN revealed[gx][gy] := TRUE END
    END
  END
END RevealAllMines;

PROCEDURE NewGame;
  VAR gx, gy: CARDINAL;
BEGIN
  FOR gx := 0 TO GRID-1 DO
    FOR gy := 0 TO GRID-1 DO
      mine[gx][gy] := FALSE; revealed[gx][gy] := FALSE;
      flagged[gx][gy] := FALSE; count[gx][gy] := 0
    END
  END;
  gFirst := TRUE; gOver := FALSE; gWon := FALSE; gRevealed := 0; gFlags := 0;
  DrawBoard
END NewGame;

PROCEDURE LeftClick (gx, gy: CARDINAL);
BEGIN
  IF gOver OR flagged[gx][gy] OR revealed[gx][gy] THEN RETURN END;
  IF gFirst THEN
    PlaceMines(gx, gy); ComputeCounts; gFirst := FALSE
  END;
  RevealAt(gx, gy);
  IF gOver THEN
    RevealAllMines
  ELSIF gRevealed = GRID*GRID - MINES THEN
    gWon := TRUE; gOver := TRUE
  END
END LeftClick;

PROCEDURE RightClick (gx, gy: CARDINAL);
BEGIN
  IF gOver OR revealed[gx][gy] THEN RETURN END;
  IF flagged[gx][gy] THEN
    flagged[gx][gy] := FALSE; DEC(gFlags)
  ELSE
    flagged[gx][gy] := TRUE; INC(gFlags)
  END
END RightClick;

(* Decode a mouse message's client coordinates to a board cell, dispatch. *)
PROCEDURE Click (lParam: CARDINAL; right: BOOLEAN);
  VAR x, y, tc, tr, gx, gy: CARDINAL;
BEGIN
  x := lParam MOD 65536; y := lParam DIV 65536;
  tc := x DIV CellW; tr := y DIV CellH;
  IF (tc < OX) OR (tr < OY) THEN RETURN END;
  gx := tc - OX; gy := tr - OY;
  IF (gx >= GRID) OR (gy >= GRID) THEN RETURN END;
  IF right THEN RightClick(gx, gy) ELSE LeftClick(gx, gy) END;
  DrawBoard
END Click;

(* --- window handler ----------------------------------------------------- *)

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Paint(); ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_LBUTTONDOWN THEN
    Click(lParam, FALSE); Repaint(w); RETURN 0
  ELSIF msg = WM_RBUTTONDOWN THEN
    Click(lParam, TRUE); Repaint(w); RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF (ch = 'r') OR (ch = 'R') THEN NewGame; Repaint(w) END;
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
  Randomize(0);                              (* auto-seed from the system clock *)
  ok := Startup("Consolas", VAL(SHORTREAL, 16.0));
  Init(Cols, Rows);
  Clear;
  WriteColAt(2, 0, Lime, Black, "NewM2 Minesweeper");
  WriteColAt(2, 1, Aqua, Black, "Left: reveal   Right: flag   R: new game");
  NewGame;
  gWin := CreateAppWindow("NewM2 Minesweeper", Cols*CellW + 16, Rows*CellH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  ok := Attach(gWin, cw, ch, CellW, CellH);
  Paint();
  Repaint(gWin);
  RunMessageLoop()
END Minesweeper.
