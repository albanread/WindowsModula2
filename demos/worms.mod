MODULE Worms;
(*
 * Worms — a multi-worm "snake" on a large Terminal cell grid. You are the GREEN
 * worm (arrow keys). The RED and BLUE worms are the computer.
 *
 * THREE worker COROUTINES cooperate with the main loop, each resumed once per
 * tick (TRANSFER in, decide, TRANSFER back):
 *   - a treat DISPENSER coroutine deposits treats (`*`) onto empty cells;
 *   - the RED and BLUE worm coroutines each size up the board and steer toward
 *     the nearest treat while dodging walls and bodies.
 * Worms grow by eating treats; running into a wall, another worm, or yourself is
 * fatal. It is a deliberate workout for cooperative multitasking — ISO COROUTINES
 * (NEWCOROUTINE / TRANSFER / CURRENT) — alongside 2-D arrays, records and the
 * Terminal/TermRender/WinShell stack.
 *
 *   build: newm2 build demos/worms.mod   then run the .exe
 *   arrows  steer the green worm     Space  pause     R  restart     Esc  quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  PumpMessages, Quit;
FROM TermRender IMPORT Startup, Attach, Paint;
FROM Terminal IMPORT Init, Clear, Fill, WriteColAt, SetStatus, Colour,
  Black, White, Silver, Gray, Lime, Red, Blue, Yellow, Aqua;
FROM RandomNumbers IMPORT Randomize, Random;
FROM ElapsedTime IMPORT Delay;
FROM COROUTINES IMPORT NEWCOROUTINE, TRANSFER, CURRENT, COROUTINE;
FROM SYSTEM IMPORT ADR, SIZE;
FROM WholeStr IMPORT CardToStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  GW = 70; GH = 38;                 (* board cells, incl. a 1-cell wall border *)
  CellW = 14; CellH = 14;
  Rows = GH + 1;                    (* last terminal row = status bar *)
  NW = 3;                           (* worms: 0 = player(green), 1 = red, 2 = blue *)
  MaxLen = 400;
  TargetFood = 6;
  GrowPerFood = 3;
  RespawnTicks = 18;

  EMPTY = 0; WALL = -1; FOOD = -2;  (* gCell values; worm body = id+1 (1..3) *)

  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  VK_ESCAPE = 1BH; VK_LEFT = 25H; VK_UP = 26H; VK_RIGHT = 27H; VK_DOWN = 28H;

TYPE
  Worm = RECORD
    bx, by:  ARRAY [0..MaxLen-1] OF INTEGER;   (* body cells, head at index 0 *)
    len:     CARDINAL;
    dir:     CARDINAL;                         (* 0=up 1=right 2=down 3=left *)
    alive:   BOOLEAN;
    grow:    CARDINAL;                         (* pending growth segments *)
    score:   CARDINAL;
    respawn: CARDINAL;                         (* ticks until AI respawn *)
  END;

VAR
  gWin:    Window;
  gCell:   ARRAY [0..GW-1], [0..GH-1] OF INTEGER;
  worm:    ARRAY [0..NW-1] OF Worm;
  DX, DY:  ARRAY [0..3] OF INTEGER;
  gFood:   CARDINAL;
  gOver:   BOOLEAN;
  gPaused: BOOLEAN;
  main, coRed, coBlue, coDisp: COROUTINE;
  wsRed, wsBlue, wsDisp: ARRAY [0..16383] OF CHAR;

PROCEDURE IAbs (a: INTEGER): INTEGER;
BEGIN IF a < 0 THEN RETURN -a ELSE RETURN a END END IAbs;

PROCEDURE WormColour (id: CARDINAL): Colour;
BEGIN
  IF id = 0 THEN RETURN Lime ELSIF id = 1 THEN RETURN Red ELSE RETURN Blue END
END WormColour;

(* ---- grid / spawning --------------------------------------------------- *)

PROCEDURE SpawnFood;
  VAR x, y, tries: CARDINAL;
BEGIN
  tries := 0;
  REPEAT
    x := Random(1, GW-2); y := Random(1, GH-2); INC(tries)
  UNTIL (gCell[x][y] = EMPTY) OR (tries > 400);
  IF gCell[x][y] = EMPTY THEN gCell[x][y] := FOOD; INC(gFood) END
END SpawnFood;

PROCEDURE EnsureFood;
BEGIN
  WHILE gFood < TargetFood DO SpawnFood END
END EnsureFood;

(* Place worm `k` with a length-3 body at a random clear spot. Leaves it dead
   (to retry next tick) if no room is found. *)
PROCEDURE Spawn (k: CARDINAL);
  VAR hx, hy, x1, y1, x2, y2: INTEGER; d, tries: CARDINAL; placed: BOOLEAN;
BEGIN
  placed := FALSE; tries := 0;
  WHILE (NOT placed) AND (tries < 300) DO
    INC(tries);
    hx := VAL(INTEGER, Random(3, GW-4)); hy := VAL(INTEGER, Random(3, GH-4));
    d  := Random(0, 3);
    x1 := hx - DX[d]; y1 := hy - DY[d];
    x2 := hx - 2*DX[d]; y2 := hy - 2*DY[d];
    IF (gCell[hx][hy] = EMPTY) AND (gCell[x1][y1] = EMPTY) AND (gCell[x2][y2] = EMPTY) THEN
      worm[k].bx[0] := hx; worm[k].by[0] := hy;
      worm[k].bx[1] := x1; worm[k].by[1] := y1;
      worm[k].bx[2] := x2; worm[k].by[2] := y2;
      gCell[hx][hy] := VAL(INTEGER, k+1);
      gCell[x1][y1] := VAL(INTEGER, k+1);
      gCell[x2][y2] := VAL(INTEGER, k+1);
      worm[k].len := 3; worm[k].dir := d; worm[k].alive := TRUE;
      worm[k].grow := 0; worm[k].respawn := 0;
      placed := TRUE
    END
  END;
  IF NOT placed THEN worm[k].alive := FALSE; worm[k].respawn := RespawnTicks END
END Spawn;

PROCEDURE Kill (k: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO worm[k].len-1 DO
    gCell[worm[k].bx[i]][worm[k].by[i]] := EMPTY
  END;
  worm[k].alive := FALSE;
  IF k = 0 THEN gOver := TRUE ELSE worm[k].respawn := RespawnTicks END
END Kill;

PROCEDURE ResetGame;
  VAR x, y, k: CARDINAL;
BEGIN
  FOR x := 0 TO GW-1 DO
    FOR y := 0 TO GH-1 DO
      IF (x = 0) OR (x = GW-1) OR (y = 0) OR (y = GH-1) THEN gCell[x][y] := WALL
      ELSE gCell[x][y] := EMPTY END
    END
  END;
  gFood := 0; gOver := FALSE; gPaused := FALSE;
  FOR k := 0 TO NW-1 DO worm[k].score := 0; worm[k].alive := FALSE; worm[k].respawn := 0 END;
  FOR k := 0 TO NW-1 DO Spawn(k) END;
  EnsureFood
END ResetGame;

(* ---- movement / collision ---------------------------------------------- *)

(* TRUE if heading `nd` would put the head straight back onto the neck (body[1]).
   A worm physically cannot reverse into itself; this is checked from the body
   GEOMETRY, not the pending dir, so it is immune to two direction changes landing
   in a single tick (the classic snake "double-tap reversal" death). *)
PROCEDURE WouldReverse (k, nd: CARDINAL): BOOLEAN;
BEGIN
  IF worm[k].len < 2 THEN RETURN FALSE END;
  RETURN (worm[k].bx[0] + DX[nd] = worm[k].bx[1])
     AND (worm[k].by[0] + DY[nd] = worm[k].by[1])
END WouldReverse;

(* TRUE if worm k may move its head onto (x,y): not a wall, not a body — except
   its own tail when it is not currently growing (that cell will be vacated). *)
PROCEDURE Safe (k: CARDINAL; x, y: INTEGER): BOOLEAN;
BEGIN
  IF gCell[x][y] = WALL THEN RETURN FALSE END;
  IF gCell[x][y] >= 1 THEN
    IF (x = worm[k].bx[worm[k].len-1]) AND (y = worm[k].by[worm[k].len-1])
       AND (worm[k].grow = 0) THEN RETURN TRUE END;
    RETURN FALSE
  END;
  RETURN TRUE
END Safe;

PROCEDURE MoveWorm (k: CARDINAL);
  VAR hx, hy, tx, ty: INTEGER; i: CARDINAL; ate, growing, ownTail: BOOLEAN;
BEGIN
  IF NOT worm[k].alive THEN RETURN END;
  hx := worm[k].bx[0] + DX[worm[k].dir];
  hy := worm[k].by[0] + DY[worm[k].dir];
  growing := worm[k].grow > 0;
  ownTail := (hx = worm[k].bx[worm[k].len-1]) AND (hy = worm[k].by[worm[k].len-1]);
  IF gCell[hx][hy] = WALL THEN Kill(k); RETURN END;
  IF (gCell[hx][hy] >= 1) AND NOT (ownTail AND NOT growing) THEN Kill(k); RETURN END;
  ate := gCell[hx][hy] = FOOD;
  IF (growing OR ate) AND (worm[k].len < MaxLen) THEN
    FOR i := worm[k].len TO 1 BY -1 DO
      worm[k].bx[i] := worm[k].bx[i-1]; worm[k].by[i] := worm[k].by[i-1]
    END;
    INC(worm[k].len)
  ELSE
    tx := worm[k].bx[worm[k].len-1]; ty := worm[k].by[worm[k].len-1];
    gCell[tx][ty] := EMPTY;
    FOR i := worm[k].len-1 TO 1 BY -1 DO
      worm[k].bx[i] := worm[k].bx[i-1]; worm[k].by[i] := worm[k].by[i-1]
    END
  END;
  worm[k].bx[0] := hx; worm[k].by[0] := hy;
  gCell[hx][hy] := VAL(INTEGER, k+1);
  IF worm[k].grow > 0 THEN DEC(worm[k].grow) END;
  IF ate THEN                          (* the dispenser coroutine replenishes treats *)
    DEC(gFood); INC(worm[k].score); INC(worm[k].grow, GrowPerFood)
  END
END MoveWorm;

PROCEDURE StepAll;
  VAR k: CARDINAL;
BEGIN
  FOR k := 0 TO NW-1 DO
    IF worm[k].alive THEN
      MoveWorm(k)
    ELSIF (k > 0) AND (worm[k].respawn > 0) THEN
      DEC(worm[k].respawn);
      IF worm[k].respawn = 0 THEN Spawn(k) END
    END
  END
END StepAll;

(* ---- AI (runs inside each worm's coroutine) ---------------------------- *)

PROCEDURE NearestFood (hx, hy: INTEGER; VAR fx, fy: INTEGER): BOOLEAN;
  VAR x, y: CARDINAL; best, d: INTEGER; found: BOOLEAN;
BEGIN
  found := FALSE; best := 0;
  FOR x := 1 TO GW-2 DO
    FOR y := 1 TO GH-2 DO
      IF gCell[x][y] = FOOD THEN
        d := IAbs(VAL(INTEGER, x) - hx) + IAbs(VAL(INTEGER, y) - hy);
        IF (NOT found) OR (d < best) THEN best := d; fx := VAL(INTEGER, x); fy := VAL(INTEGER, y); found := TRUE END
      END
    END
  END;
  RETURN found
END NearestFood;

PROCEDURE DecideAI (k: CARDINAL);
  VAR hx, hy, fx, fy, nhx, nhy, nd, bestd: INTEGER; dir, bestdir: CARDINAL;
      haveFood, chosen: BOOLEAN;
BEGIN
  IF NOT worm[k].alive THEN RETURN END;
  hx := worm[k].bx[0]; hy := worm[k].by[0];
  haveFood := NearestFood(hx, hy, fx, fy);
  chosen := FALSE; bestd := 0; bestdir := worm[k].dir;
  FOR dir := 0 TO 3 DO
    IF NOT WouldReverse(k, dir) THEN
      nhx := hx + DX[dir]; nhy := hy + DY[dir];
      IF Safe(k, nhx, nhy) THEN
        IF haveFood THEN nd := IAbs(nhx - fx) + IAbs(nhy - fy) ELSE nd := 0 END;
        IF (NOT chosen) OR (nd < bestd) THEN bestd := nd; bestdir := dir; chosen := TRUE END
      END
    END
  END;
  IF chosen THEN worm[k].dir := bestdir END
END DecideAI;

PROCEDURE AIRed;
BEGIN LOOP DecideAI(1); TRANSFER(coRed, main) END END AIRed;

PROCEDURE AIBlue;
BEGIN LOOP DecideAI(2); TRANSFER(coBlue, main) END END AIBlue;

(* The treat dispenser: its own coroutine, deposits one treat per tick whenever
   the board has fewer than TargetFood, so the worms always have something to
   seek. The worms (above) avoid contact; this one only ever feeds them. *)
PROCEDURE Dispenser;
BEGIN
  LOOP
    IF gFood < TargetFood THEN SpawnFood END;
    TRANSFER(coDisp, main)
  END
END Dispenser;

(* ---- rendering --------------------------------------------------------- *)

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
  AppendStr(buf, pos, " Green "); CardToStr(worm[0].score, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "  Red "); CardToStr(worm[1].score, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "  Blue "); CardToStr(worm[2].score, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "   ");
  IF gOver THEN AppendStr(buf, pos, "YOU DIED - R to restart")
  ELSIF gPaused THEN AppendStr(buf, pos, "paused")
  ELSE AppendStr(buf, pos, "arrows steer") END;
  AppendStr(buf, pos, "  | Space pause  R restart  Esc quit ");
  SetStatus(buf)
END ShowStatus;

PROCEDURE Render;
  VAR x, y, k: CARDINAL; v: INTEGER;
BEGIN
  FOR x := 0 TO GW-1 DO
    FOR y := 0 TO GH-1 DO
      v := gCell[x][y];
      IF v = WALL THEN Fill(x, y, 1, 1, ' ', Gray, Gray)
      ELSIF v = FOOD THEN Fill(x, y, 1, 1, '*', Yellow, Black)
      ELSIF v >= 1 THEN Fill(x, y, 1, 1, ' ', Black, WormColour(VAL(CARDINAL, v) - 1))
      ELSE Fill(x, y, 1, 1, ' ', Black, Black) END
    END
  END;
  FOR k := 0 TO NW-1 DO                 (* heads drawn distinct, over the bodies *)
    IF worm[k].alive THEN
      Fill(VAL(CARDINAL, worm[k].bx[0]), VAL(CARDINAL, worm[k].by[0]), 1, 1, 'O',
           White, WormColour(k))
    END
  END;
  ShowStatus
END Render;

(* ---- input + main loop ------------------------------------------------- *)

PROCEDURE Turn (nd: CARDINAL);
BEGIN
  IF worm[0].alive AND NOT WouldReverse(0, nd) THEN worm[0].dir := nd END
END Turn;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Paint(); ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF    wParam = VK_UP    THEN Turn(0)
    ELSIF wParam = VK_RIGHT THEN Turn(1)
    ELSIF wParam = VK_DOWN  THEN Turn(2)
    ELSIF wParam = VK_LEFT  THEN Turn(3)
    ELSIF wParam = VK_ESCAPE THEN Quit
    END;
    RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF (ch = ' ') THEN gPaused := NOT gPaused
    ELSIF (ch = 'r') OR (ch = 'R') THEN ResetGame END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, chh: CARDINAL; ok: BOOLEAN;
BEGIN
  Randomize(0);
  DX[0] := 0; DY[0] := -1;  DX[1] := 1; DY[1] := 0;
  DX[2] := 0; DY[2] := 1;   DX[3] := -1; DY[3] := 0;
  ok := Startup("Consolas", VAL(SHORTREAL, 12.0));
  Init(GW, Rows);
  Clear;
  ResetGame;
  main := CURRENT();
  NEWCOROUTINE(AIRed,     ADR(wsRed),  SIZE(wsRed),  coRed);
  NEWCOROUTINE(AIBlue,    ADR(wsBlue), SIZE(wsBlue), coBlue);
  NEWCOROUTINE(Dispenser, ADR(wsDisp), SIZE(wsDisp), coDisp);
  gWin := CreateAppWindow("NewM2 Worms (coroutine AI)", GW*CellW + 16, Rows*CellH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, chh);
  ok := Attach(gWin, cw, chh, CellW, CellH);
  Render; Paint(); Repaint(gWin);
  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    IF (NOT gPaused) AND (NOT gOver) THEN
      TRANSFER(main, coDisp);         (* dispenser coroutine deposits a treat *)
      TRANSFER(main, coRed);          (* red worm's coroutine decides its move *)
      TRANSFER(main, coBlue);         (* blue worm's coroutine decides its move *)
      StepAll;
      Render; Paint()
    END;
    Delay(110)
  END
END Worms.
