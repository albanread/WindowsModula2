MODULE Reversi;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * Reversi / Othello — a mouse-driven GUI game in pure Modula-2 on the Terminal
 * cell grid (Direct2D/DirectWrite via TermRender, window + loop via WinShell).
 * You play Black; the computer plays White with a greedy, corner-preferring AI.
 *
 * It exercises yet another mix of features: signed 8-direction ray stepping over
 * an 8x8 board (the bracket-and-flip rule), legal-move generation, a board-search
 * AI (nested loops scoring every empty square), pass detection, and mouse
 * hit-testing — distinct from the shaders' float kernels and Minesweeper's
 * recursion.
 *
 *   build: newm2 build demos/reversi.mod   then run the .exe
 *   Left-click a highlighted square to play   R: new game   Esc: quit
 *)
FROM SYSTEM IMPORT ADDRESS;
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  RunMessageLoop, Quit;
FROM TermRender IMPORT Startup, Attach, Paint;
FROM Terminal IMPORT
  Init, Clear, Fill, WriteColAt, SetStatus, Colour,
  Black, Green, Teal, Silver, Gray, Yellow, Lime, Aqua, White;
FROM WholeStr IMPORT CardToStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  N = 8;                (* board is N x N *)
  EMPTY = 0; BLACK = 1; WHITE = 2;
  OX = 2; OY = 3;       (* board origin in terminal cells *)
  Cols = OX + N + 2;    (* 12 *)
  Rows = OY + N + 2;    (* 13, status on the last row *)
  CellW = 30; CellH = 30;

  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  WM_LBUTTONDOWN = 513;
  VK_ESCAPE = 1BH;

VAR
  gWin:   Window;
  board:  ARRAY [0..N-1], [0..N-1] OF CARDINAL;
  DX, DY: ARRAY [0..7] OF INTEGER;        (* the eight directions *)
  gTurn:  CARDINAL;                       (* whose move: BLACK (human) or WHITE (AI) *)
  gOver:  BOOLEAN;

(* --- board primitives --------------------------------------------------- *)

PROCEDURE Opp (p: CARDINAL): CARDINAL;
BEGIN
  IF p = BLACK THEN RETURN WHITE ELSE RETURN BLACK END
END Opp;

PROCEDURE InBounds (x, y: INTEGER): BOOLEAN;
BEGIN
  RETURN (x >= 0) AND (x < N) AND (y >= 0) AND (y < N)
END InBounds;

PROCEDURE Cell (x, y: INTEGER): CARDINAL;         (* caller guarantees in bounds *)
BEGIN
  RETURN board[VAL(CARDINAL, x)][VAL(CARDINAL, y)]
END Cell;

(* Discs `player` would flip by moving at (x,y); 0 means the move is illegal. *)
PROCEDURE WouldFlip (x, y, player: CARDINAL): CARDINAL;
  VAR d, cnt, total, opp: CARDINAL; cx, cy: INTEGER;
BEGIN
  IF board[x][y] # EMPTY THEN RETURN 0 END;
  opp := Opp(player); total := 0;
  FOR d := 0 TO 7 DO
    cx := VAL(INTEGER, x) + DX[d]; cy := VAL(INTEGER, y) + DY[d]; cnt := 0;
    WHILE InBounds(cx, cy) AND (Cell(cx, cy) = opp) DO
      INC(cnt); cx := cx + DX[d]; cy := cy + DY[d]
    END;
    IF InBounds(cx, cy) AND (Cell(cx, cy) = player) AND (cnt > 0) THEN
      total := total + cnt
    END
  END;
  RETURN total
END WouldFlip;

PROCEDURE ApplyMove (x, y, player: CARDINAL);
  VAR d, cnt, k, opp: CARDINAL; cx, cy: INTEGER;
BEGIN
  board[x][y] := player; opp := Opp(player);
  FOR d := 0 TO 7 DO
    cx := VAL(INTEGER, x) + DX[d]; cy := VAL(INTEGER, y) + DY[d]; cnt := 0;
    WHILE InBounds(cx, cy) AND (Cell(cx, cy) = opp) DO
      INC(cnt); cx := cx + DX[d]; cy := cy + DY[d]
    END;
    IF InBounds(cx, cy) AND (Cell(cx, cy) = player) AND (cnt > 0) THEN
      cx := VAL(INTEGER, x) + DX[d]; cy := VAL(INTEGER, y) + DY[d];
      FOR k := 1 TO cnt DO
        board[VAL(CARDINAL, cx)][VAL(CARDINAL, cy)] := player;
        cx := cx + DX[d]; cy := cy + DY[d]
      END
    END
  END
END ApplyMove;

PROCEDURE HasMove (player: CARDINAL): BOOLEAN;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO N-1 DO
    FOR y := 0 TO N-1 DO
      IF WouldFlip(x, y, player) > 0 THEN RETURN TRUE END
    END
  END;
  RETURN FALSE
END HasMove;

PROCEDURE Score (player: CARDINAL): CARDINAL;
  VAR x, y, s: CARDINAL;
BEGIN
  s := 0;
  FOR x := 0 TO N-1 DO
    FOR y := 0 TO N-1 DO IF board[x][y] = player THEN INC(s) END END
  END;
  RETURN s
END Score;

(* Positional weight: corners are gold, the squares next to them are traps. *)
PROCEDURE Weight (x, y: CARDINAL): CARDINAL;
  VAR corner, edge: BOOLEAN;
BEGIN
  corner := ((x = 0) OR (x = N-1)) AND ((y = 0) OR (y = N-1));
  edge   := (x = 0) OR (x = N-1) OR (y = 0) OR (y = N-1);
  IF corner THEN RETURN 50
  ELSIF edge THEN RETURN 3
  ELSE RETURN 1 END
END Weight;

(* Greedy AI: pick the White move maximising flips plus a positional bonus. *)
PROCEDURE AIMove;
  VAR x, y, f, sc, best, bx, by: CARDINAL; found: BOOLEAN;
BEGIN
  best := 0; bx := 0; by := 0; found := FALSE;
  FOR x := 0 TO N-1 DO
    FOR y := 0 TO N-1 DO
      f := WouldFlip(x, y, WHITE);
      IF f > 0 THEN
        sc := f + Weight(x, y) * 2;
        IF (NOT found) OR (sc > best) THEN
          best := sc; bx := x; by := y; found := TRUE
        END
      END
    END
  END;
  IF found THEN ApplyMove(bx, by, WHITE) END
END AIMove;

(* --- rendering ---------------------------------------------------------- *)

PROCEDURE DrawCell (x, y: CARDINAL);
  VAR tc, tr: CARDINAL;
BEGIN
  tc := OX + x; tr := OY + y;
  IF board[x][y] = BLACK THEN
    Fill(tc, tr, 1, 1, 'O', Black, Green)
  ELSIF board[x][y] = WHITE THEN
    Fill(tc, tr, 1, 1, 'O', White, Green)
  ELSIF (NOT gOver) AND (gTurn = BLACK) AND (WouldFlip(x, y, BLACK) > 0) THEN
    Fill(tc, tr, 1, 1, '.', Yellow, Green)       (* a legal move for you *)
  ELSE
    Fill(tc, tr, 1, 1, ' ', Green, Green)
  END
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
  VAR buf: ARRAY [0..79] OF CHAR; num: ARRAY [0..15] OF CHAR;
      pos, b, w: CARDINAL;
BEGIN
  b := Score(BLACK); w := Score(WHITE); pos := 0;
  AppendStr(buf, pos, " Black "); CardToStr(b, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "  White "); CardToStr(w, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "  | ");
  IF gOver THEN
    IF b > w THEN AppendStr(buf, pos, "Black wins!")
    ELSIF w > b THEN AppendStr(buf, pos, "White wins!")
    ELSE AppendStr(buf, pos, "Draw.") END;
    AppendStr(buf, pos, "  R: new game ")
  ELSIF gTurn = BLACK THEN
    AppendStr(buf, pos, "your move (click a dot)  Esc: quit ")
  ELSE
    AppendStr(buf, pos, "White thinking... ")
  END;
  SetStatus(buf)
END ShowStatus;

PROCEDURE DrawBoard;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO N-1 DO FOR y := 0 TO N-1 DO DrawCell(x, y) END END;
  ShowStatus
END DrawBoard;

(* --- turn flow ---------------------------------------------------------- *)

(* Hand the move to the other side; if they have no move they pass; if neither
   side can move the game is over. *)
PROCEDURE AdvanceTurn;
BEGIN
  gTurn := Opp(gTurn);
  IF NOT HasMove(gTurn) THEN
    gTurn := Opp(gTurn);
    IF NOT HasMove(gTurn) THEN gOver := TRUE END
  END
END AdvanceTurn;

(* After the human's move, let White take as many consecutive turns as the rules
   give it (when Black must pass), stopping when it is Black's move or the game
   ends. *)
PROCEDURE RunAI;
BEGIN
  WHILE (NOT gOver) AND (gTurn = WHITE) DO
    AIMove; AdvanceTurn
  END
END RunAI;

PROCEDURE NewGame;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO N-1 DO FOR y := 0 TO N-1 DO board[x][y] := EMPTY END END;
  board[3][3] := WHITE; board[4][4] := WHITE;
  board[3][4] := BLACK; board[4][3] := BLACK;
  gTurn := BLACK; gOver := FALSE;
  DrawBoard
END NewGame;

PROCEDURE Click (lParam: CARDINAL);
  VAR x, y, tc, tr, gx, gy: CARDINAL;
BEGIN
  IF gOver OR (gTurn # BLACK) THEN RETURN END;
  x := lParam MOD 65536; y := lParam DIV 65536;
  tc := x DIV CellW; tr := y DIV CellH;
  IF (tc < OX) OR (tr < OY) THEN RETURN END;
  gx := tc - OX; gy := tr - OY;
  IF (gx >= N) OR (gy >= N) THEN RETURN END;
  IF WouldFlip(gx, gy, BLACK) = 0 THEN RETURN END;       (* not a legal move *)
  ApplyMove(gx, gy, BLACK);
  AdvanceTurn;
  RunAI;
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
    Click(lParam); Repaint(w); RETURN 0
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

PROCEDURE InitDirs;
BEGIN
  DX[0] := -1; DY[0] := -1;  DX[1] :=  0; DY[1] := -1;  DX[2] :=  1; DY[2] := -1;
  DX[3] := -1; DY[3] :=  0;                              DX[4] :=  1; DY[4] :=  0;
  DX[5] := -1; DY[5] :=  1;  DX[6] :=  0; DY[6] :=  1;  DX[7] :=  1; DY[7] :=  1
END InitDirs;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  InitDirs;
  ok := Startup("Consolas", VAL(SHORTREAL, 16.0));
  Init(Cols, Rows);
  Clear;
  WriteColAt(2, 0, Lime, Black, "NewM2 Reversi");
  WriteColAt(2, 1, Aqua, Black, "You are Black ('O' dark).  Click a yellow dot.");
  NewGame;
  gWin := CreateAppWindow("NewM2 Reversi", Cols*CellW + 16, Rows*CellH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  ok := Attach(gWin, cw, ch, CellW, CellH);
  Paint();
  Repaint(gWin);
  RunMessageLoop()
END Reversi.
