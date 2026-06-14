MODULE ReversiGUI;
(*
 * Reversi / Othello — the graphical cousin of demos/reversi.mod (which renders on
 * the text cell grid). Same game and AI, but drawn with real Direct2D shapes via
 * the Canvas2D host: a green felt board, gridlines, anti-aliased circular discs,
 * faint dots marking your legal moves, and a text score/turn line.
 *
 * You play Black; the computer plays White with a greedy, corner-preferring AI.
 * The board logic (8-direction bracket-and-flip, legal-move generation, the
 * board-search AI, pass detection) is identical to the text version — only the
 * rendering and hit-testing differ.
 *
 *   build: newm2 build demos/reversi_gui.mod   then run the .exe
 *   Left-click a highlighted square to play   R: new game   Esc: quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  RunMessageLoop, Quit;
FROM Canvas2D IMPORT Startup, Attach, Begin, Flush, Clear, FillRect, FillCircle,
  DrawText;
FROM WholeStr IMPORT CardToStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  N = 8;
  EMPTY = 0; BLACK = 1; WHITE = 2;
  Margin = 24; CellPx = 60;             (* board geometry in device pixels *)
  BoardPx = N * CellPx;                 (* 480 *)
  StatusH = 56;
  WinW = 2*Margin + BoardPx;            (* 528 = desired CLIENT width *)
  WinH = 2*Margin + BoardPx + StatusH;  (* 584 = desired CLIENT height *)
  (* CreateAppWindow sizes the OUTER window (title bar + borders), so add the
     non-client chrome to get the client area we actually draw into. *)
  ChromeW = 16; ChromeH = 39;

  (* colours, 0x00RRGGBB *)
  BgCol     = 01E2228H;
  FeltCol   = 02F8050H;
  GridCol   = 0214A33H;
  BlackDisc = 0121212H;
  WhiteDisc = 0F2F2ECH;
  DiscRing  = 0163A28H;
  HintCol   = 05BA37CH;
  TextCol   = 0FFFFFFH;

  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  WM_LBUTTONDOWN = 513;
  VK_ESCAPE = 1BH;

VAR
  gWin:   Window;
  board:  ARRAY [0..N-1], [0..N-1] OF CARDINAL;
  DX, DY: ARRAY [0..7] OF INTEGER;
  gTurn:  CARDINAL;
  gOver:  BOOLEAN;

(* --- board logic (identical to demos/reversi.mod) ----------------------- *)

PROCEDURE Opp (p: CARDINAL): CARDINAL;
BEGIN IF p = BLACK THEN RETURN WHITE ELSE RETURN BLACK END END Opp;

PROCEDURE InBounds (x, y: INTEGER): BOOLEAN;
BEGIN RETURN (x >= 0) AND (x < N) AND (y >= 0) AND (y < N) END InBounds;

PROCEDURE Cell (x, y: INTEGER): CARDINAL;
BEGIN RETURN board[VAL(CARDINAL, x)][VAL(CARDINAL, y)] END Cell;

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
    FOR y := 0 TO N-1 DO IF WouldFlip(x, y, player) > 0 THEN RETURN TRUE END END
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

PROCEDURE Weight (x, y: CARDINAL): CARDINAL;
  VAR corner, edge: BOOLEAN;
BEGIN
  corner := ((x = 0) OR (x = N-1)) AND ((y = 0) OR (y = N-1));
  edge   := (x = 0) OR (x = N-1) OR (y = 0) OR (y = N-1);
  IF corner THEN RETURN 50 ELSIF edge THEN RETURN 3 ELSE RETURN 1 END
END Weight;

PROCEDURE AIMove;
  VAR x, y, f, sc, best, bx, by: CARDINAL; found: BOOLEAN;
BEGIN
  best := 0; bx := 0; by := 0; found := FALSE;
  FOR x := 0 TO N-1 DO
    FOR y := 0 TO N-1 DO
      f := WouldFlip(x, y, WHITE);
      IF f > 0 THEN
        sc := f + Weight(x, y) * 2;
        IF (NOT found) OR (sc > best) THEN best := sc; bx := x; by := y; found := TRUE END
      END
    END
  END;
  IF found THEN ApplyMove(bx, by, WHITE) END
END AIMove;

PROCEDURE AdvanceTurn;
BEGIN
  gTurn := Opp(gTurn);
  IF NOT HasMove(gTurn) THEN
    gTurn := Opp(gTurn);
    IF NOT HasMove(gTurn) THEN gOver := TRUE END
  END
END AdvanceTurn;

PROCEDURE RunAI;
BEGIN
  WHILE (NOT gOver) AND (gTurn = WHITE) DO AIMove; AdvanceTurn END
END RunAI;

PROCEDURE NewGame;
  VAR x, y: CARDINAL;
BEGIN
  FOR x := 0 TO N-1 DO FOR y := 0 TO N-1 DO board[x][y] := EMPTY END END;
  board[3][3] := WHITE; board[4][4] := WHITE;
  board[3][4] := BLACK; board[4][3] := BLACK;
  gTurn := BLACK; gOver := FALSE
END NewGame;

(* --- rendering (Canvas2D) ----------------------------------------------- *)

PROCEDURE AppendStr (VAR dst: ARRAY OF CHAR; VAR pos: CARDINAL; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (pos < HIGH(dst)) DO
    dst[pos] := src[i]; INC(pos); INC(i)
  END;
  dst[pos] := 0C
END AppendStr;

PROCEDURE StatusText (VAR buf: ARRAY OF CHAR);
  VAR num: ARRAY [0..15] OF CHAR; pos, b, w: CARDINAL;
BEGIN
  b := Score(BLACK); w := Score(WHITE); pos := 0;
  AppendStr(buf, pos, "Black "); CardToStr(b, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "   White "); CardToStr(w, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "    ");
  IF gOver THEN
    IF b > w THEN AppendStr(buf, pos, "Black wins!")
    ELSIF w > b THEN AppendStr(buf, pos, "White wins!")
    ELSE AppendStr(buf, pos, "Draw.") END;
    AppendStr(buf, pos, "   (R: new game)")
  ELSIF gTurn = BLACK THEN
    AppendStr(buf, pos, "Your move")
  ELSE
    AppendStr(buf, pos, "White to move")
  END
END StatusText;

PROCEDURE Render;
  VAR x, y, i: CARDINAL; gxr, gyr, cxr, cyr: REAL; buf: ARRAY [0..95] OF CHAR;
BEGIN
  Begin;
  Clear(BgCol);
  FillRect(VAL(REAL, Margin), VAL(REAL, Margin),
           VAL(REAL, BoardPx), VAL(REAL, BoardPx), FeltCol);
  (* gridlines as thin rectangles *)
  FOR i := 0 TO N DO
    FillRect(VAL(REAL, Margin + i*CellPx) - 1.0, VAL(REAL, Margin),
             2.0, VAL(REAL, BoardPx), GridCol);                       (* vertical *)
    FillRect(VAL(REAL, Margin), VAL(REAL, Margin + i*CellPx) - 1.0,
             VAL(REAL, BoardPx), 2.0, GridCol);                       (* horizontal *)
  END;
  (* discs + legal-move hints *)
  FOR x := 0 TO N-1 DO
    FOR y := 0 TO N-1 DO
      cxr := VAL(REAL, Margin + x*CellPx) + VAL(REAL, CellPx) / 2.0;
      cyr := VAL(REAL, Margin + y*CellPx) + VAL(REAL, CellPx) / 2.0;
      IF board[x][y] = BLACK THEN
        FillCircle(cxr, cyr, VAL(REAL, CellPx) / 2.0 - 5.0, DiscRing);
        FillCircle(cxr, cyr, VAL(REAL, CellPx) / 2.0 - 7.0, BlackDisc)
      ELSIF board[x][y] = WHITE THEN
        FillCircle(cxr, cyr, VAL(REAL, CellPx) / 2.0 - 5.0, DiscRing);
        FillCircle(cxr, cyr, VAL(REAL, CellPx) / 2.0 - 7.0, WhiteDisc)
      ELSIF (NOT gOver) AND (gTurn = BLACK) AND (WouldFlip(x, y, BLACK) > 0) THEN
        FillCircle(cxr, cyr, 7.0, HintCol)
      END
    END
  END;
  StatusText(buf);
  DrawText(VAL(REAL, Margin), VAL(REAL, 2*Margin + BoardPx) - 6.0,
           VAL(REAL, BoardPx), VAL(REAL, StatusH), TextCol, buf);
  Flush
END Render;

(* --- input -------------------------------------------------------------- *)

PROCEDURE Click (lParam: CARDINAL);
  VAR px, py, gx, gy: CARDINAL;
BEGIN
  IF gOver OR (gTurn # BLACK) THEN RETURN END;
  px := lParam MOD 65536; py := lParam DIV 65536;
  IF (px < Margin) OR (py < Margin) THEN RETURN END;
  gx := (px - Margin) DIV CellPx; gy := (py - Margin) DIV CellPx;
  IF (gx >= N) OR (gy >= N) THEN RETURN END;
  IF WouldFlip(gx, gy, BLACK) = 0 THEN RETURN END;
  ApplyMove(gx, gy, BLACK);
  AdvanceTurn;
  RunAI
END Click;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Render; ok := ValidateRect(w, NIL); RETURN 0
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
  NewGame;
  ok := Startup();
  gWin := CreateAppWindow("NewM2 Reversi (Direct2D)", WinW + ChromeW, WinH + ChromeH, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  ok := Attach(gWin, cw, ch);
  Repaint(gWin);
  RunMessageLoop()
END ReversiGUI.
