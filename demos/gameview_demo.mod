MODULE GameViewDemo;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * GameView demo â the INDEXED-COLOUR retro game mode. A small framebuffer
 * (200x130 palette indices) is presented at 4x as chunky pixels, exactly like a
 * 90s console: 16-colour sprites authored from text rows, bit-blits with
 * transparency and horizontal flip, and a palette-cycled rainbow band that
 * shimmers without redrawing a single pixel (classic copper-bar trick).
 *
 * It exercises GameView end to end: Cls/Pset/Text indexed drawing, SpriteRows
 * authoring, Blit/BlitFlip, CyclePalette animation, and the scaled Present â all
 * driven by WinShell's non-blocking message pump.
 *
 *   build: newm2 build demos/gameview_demo.mod   then run the .exe
 *   arrows  move the ship      Esc  quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, PumpMessages, Quit;
FROM GameView IMPORT Startup, Attach, LoadDefaultPalette, SetColour, CyclePalette,
  Cls, Pset, FillRect, Text, SpriteRows, Blit, BlitFlip, Present, Width, Height;
FROM RandomNumbers IMPORT Randomize, Rnd;
FROM ElapsedTime IMPORT Delay;
FROM WholeStr IMPORT CardToStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  FBW = 200; FBH = 130; Scale = 4;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256;
  VK_ESCAPE = 1BH; VK_LEFT = 25H; VK_UP = 26H; VK_RIGHT = 27H; VK_DOWN = 28H;

  Ship  = 0;   ShipW = 11; ShipH = 8;
  Bug   = 1;   BugW  = 8;
  Orb   = 2;

  NStars = 60;
  NBugs  = 6;
  BandLo = 200; BandHi = 231;        (* palette range used by the rainbow band *)

VAR
  gWin:  Window;
  gPX, gPY: INTEGER;                 (* ship position *)
  gFrame: CARDINAL;
  sx, sy: ARRAY [0..NStars-1] OF INTEGER;
  sp:     ARRAY [0..NStars-1] OF CARDINAL;            (* twinkle phase *)
  bx, by, bvx, bvy: ARRAY [0..NBugs-1] OF INTEGER;

(* --- a tiny rainbow into the band palette range ------------------------- *)
PROCEDURE BuildRainbow;
  CONST N = 12;
  VAR i: CARDINAL; tab: ARRAY [0..N-1] OF CARDINAL;
BEGIN
  tab[0]  := 0FF0000H; tab[1]  := 0FF7F00H; tab[2]  := 0FFFF00H; tab[3]  := 07FFF00H;
  tab[4]  := 000FF00H; tab[5]  := 000FF7FH; tab[6]  := 000FFFFH; tab[7]  := 0007FFFH;
  tab[8]  := 00000FFH; tab[9]  := 07F00FFH; tab[10] := 0FF00FFH; tab[11] := 0FF007FH;
  FOR i := BandLo TO BandHi DO SetColour(i, tab[(i - BandLo) MOD N]) END
END BuildRainbow;

PROCEDURE DefineSprites;
  VAR ok: BOOLEAN;
BEGIN
  (* ship: light-cyan hull (B), white cockpit (C), pointing up *)
  ok := SpriteRows(Ship,
    ".....B....." +
    "....BBB...." +
    "....BCB...." +
    "...BBBBB..." +
    "..BBBBBBB.." +
    ".BBBBBBBBB." +
    ".B.BBBBB.B." +
    ".B.......B.");
  (* bug: a little light-green invader (A) *)
  ok := SpriteRows(Bug,
    "..A..A.." +
    "A.AAAA.A" +
    "AAAAAAAA" +
    "AA.AA.AA" +
    "AAAAAAAA" +
    "..A..A.." +
    ".A.AA.A." +
    "A.A..A.A");
  (* orb: a small yellow ball (E) *)
  ok := SpriteRows(Orb,
    "..EE.." +
    ".EEEE." +
    "EEEEEE" +
    "EEEEEE" +
    ".EEEE." +
    "..EE..")
END DefineSprites;

PROCEDURE SeedWorld;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO NStars-1 DO
    sx[i] := VAL(INTEGER, Rnd(FBW));
    sy[i] := VAL(INTEGER, 12 + Rnd(FBH-14));
    sp[i] := Rnd(8)
  END;
  FOR i := 0 TO NBugs-1 DO
    bx[i]  := VAL(INTEGER, 20 + Rnd(FBW-40));
    by[i]  := VAL(INTEGER, 20 + Rnd(60));
    IF Rnd(2) = 0 THEN bvx[i] := 1 ELSE bvx[i] := -1 END;
    IF Rnd(2) = 0 THEN bvy[i] := 1 ELSE bvy[i] := -1 END
  END;
  gPX := FBW DIV 2 - ShipW DIV 2;
  gPY := FBH - ShipH - 6
END SeedWorld;

(* --- one rendered frame ------------------------------------------------- *)
PROCEDURE DrawHud;
  VAR s: ARRAY [0..31] OF CHAR;
BEGIN
  Text(4, 3, "RETRO GAMEVIEW", 15);
  CardToStr(gFrame, s);
  Text(FBW - 60, 3, "FRAME ", 7);
  Text(FBW - 24, 3, s, 14)
END DrawHud;

PROCEDURE RenderFrame;
  VAR i: CARDINAL; c, bandY: CARDINAL;
BEGIN
  Cls(0);                                          (* black space *)

  (* shimmering rainbow band near the top: each column reads a band index, and
     cycling the band palette every frame makes the colours flow sideways *)
  bandY := 14;
  FOR i := 0 TO FBW-1 DO
    FillRect(VAL(INTEGER, i), VAL(INTEGER, bandY), 1, 4,
             BandLo + (i MOD (BandHi - BandLo + 1)))
  END;

  (* starfield (twinkles via a per-star phase) *)
  FOR i := 0 TO NStars-1 DO
    IF ((gFrame DIV 4) + sp[i]) MOD 4 = 0 THEN c := 8 ELSE c := 15 END;
    Pset(sx[i], sy[i], c)
  END;

  (* bugs, flipped to face their travel direction *)
  FOR i := 0 TO NBugs-1 DO
    BlitFlip(Bug, bx[i], by[i], bvx[i] < 0, FALSE)
  END;

  Blit(Ship, gPX, gPY);                            (* the player *)
  DrawHud;
  Present
END RenderFrame;

(* --- simulation tick ---------------------------------------------------- *)
PROCEDURE Step;
  VAR i: CARDINAL;
BEGIN
  INC(gFrame);
  CyclePalette(BandLo, BandHi);                    (* flow the rainbow *)
  FOR i := 0 TO NBugs-1 DO
    bx[i] := bx[i] + bvx[i];
    by[i] := by[i] + bvy[i];
    IF (bx[i] < 0) OR (bx[i] > VAL(INTEGER, FBW - BugW)) THEN bvx[i] := -bvx[i]; bx[i] := bx[i] + bvx[i] END;
    IF (by[i] < 20) OR (by[i] > 90) THEN bvy[i] := -bvy[i]; by[i] := by[i] + bvy[i] END
  END
END Step;

(* --- input -------------------------------------------------------------- *)
PROCEDURE OnKey (vk: CARDINAL);
BEGIN
  IF    vk = VK_LEFT  THEN gPX := gPX - 4
  ELSIF vk = VK_RIGHT THEN gPX := gPX + 4
  ELSIF vk = VK_UP    THEN gPY := gPY - 4
  ELSIF vk = VK_DOWN  THEN gPY := gPY + 4
  ELSIF vk = VK_ESCAPE THEN Quit
  END;
  IF gPX < 0 THEN gPX := 0 END;
  IF gPX > VAL(INTEGER, FBW - ShipW) THEN gPX := VAL(INTEGER, FBW - ShipW) END;
  IF gPY < 20 THEN gPY := 20 END;
  IF gPY > VAL(INTEGER, FBH - ShipH) THEN gPY := VAL(INTEGER, FBH - ShipH) END
END OnKey;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Present(); ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    OnKey(wParam); RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  Randomize(0);
  ok := Startup();
  LoadDefaultPalette;
  BuildRainbow;
  DefineSprites;
  SeedWorld;
  gFrame := 0;
  gWin := CreateAppWindow("NewM2 GameView", FBW*Scale + 16, FBH*Scale + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  ok := Attach(gWin, FBW, FBH, Scale);
  RenderFrame;
  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    Step;
    RenderFrame;
    Delay(30)
  END
END GameViewDemo.
