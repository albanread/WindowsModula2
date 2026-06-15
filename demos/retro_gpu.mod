MODULE RetroGPU;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * GameViewGpu showcase — the GPU retro mode end to end: an indexed background with
 * a per-line palette (animated raster bars), a palette-cycled rainbow strip, and a
 * sprite layer of FRAME-ANIMATED sprites (spinning coins) plus a rotating star, all
 * composited on the GPU.
 *
 *   build: newm2 build demos/retro_gpu.mod   then run the .exe
 *   Esc  quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, PumpMessages, Quit;
FROM GameViewGpu IMPORT Startup, Attach, LoadDefaultPalette, SetColour, CyclePalette,
  SetLineRGB, Cls, FillRect, Text, DefineSprite, AddFrame, SpriteRGB,
  Place, SetScale, SetFrame, SetRotation, Animate, Tick, Present;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;
FROM STextIO IMPORT WriteString, WriteLn;

CONST
  FBW = 240; FBH = 160; Scale = 4;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; VK_ESCAPE = 1BH;
  StarInst = 5;

  Coin0 = "..2222../.222222./22222222/22222222/22222222/22222222/.222222./..2222..";
  Coin1 = "...22.../..2222../..2222../..2222../..2222../..2222../..2222../...22...";
  Coin2 = "...22.../...22.../...22.../...22.../...22.../...22.../...22.../...22...";
  Star  = "...55.../..5555../.555555./55555555/55555555/.555555./..5555../...55...";

VAR
  gWin: Window;

PROCEDURE Clamp8 (v: CARDINAL): CARDINAL;
BEGIN IF v > 255 THEN RETURN 255 ELSE RETURN v END END Clamp8;

PROCEDURE SetupPalette;
  CONST N = 12;
  VAR i: CARDINAL; tab: ARRAY [0..N-1] OF CARDINAL;
BEGIN
  LoadDefaultPalette;
  SetColour(16, 02E8B3AH);                                  (* grass green *)
  tab[0]:=0FF0000H; tab[1]:=0FF7F00H; tab[2]:=0FFFF00H; tab[3]:=07FFF00H;
  tab[4]:=000FF00H; tab[5]:=000FF7FH; tab[6]:=000FFFFH; tab[7]:=0007FFFH;
  tab[8]:=00000FFH; tab[9]:=07F00FFH; tab[10]:=0FF00FFH; tab[11]:=0FF007FH;
  FOR i := 0 TO 31 DO SetColour(32+i, tab[i MOD N]) END
END SetupPalette;

(* per-scanline sky gradient (low index 1) with copper bars scrolling down *)
PROCEDURE UpdateSky (phase: CARDINAL);
  VAR y, base, bar, add: CARDINAL;
BEGIN
  FOR y := 0 TO 128 DO
    base := 24 + (y * 90) DIV 130;
    bar := (y + phase) MOD 36;
    IF bar < 4 THEN add := (4 - bar) * 30 ELSE add := 0 END;
    SetLineRGB(y, 1, Clamp8(base DIV 3 + add), Clamp8(base DIV 2 + add), Clamp8(base + add))
  END
END UpdateSky;

PROCEDURE BuildScene;
  VAR x: CARDINAL;
BEGIN
  Cls(1);                                                  (* sky: index 1 -> per-line palette *)
  FOR x := 0 TO FBW-1 DO FillRect(VAL(INTEGER,x), 44, 1, 8, 32 + (x MOD 32)) END;  (* rainbow strip *)
  FillRect(0, FBH-26, FBW, 26, 16);                        (* ground *)
  Text(8, 6, "GAMEVIEW GPU", 15)
END BuildScene;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_KEYDOWN THEN IF wParam = VK_ESCAPE THEN Quit END; RETURN 0
  ELSIF msg = WM_DESTROY THEN Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch, i, phase: CARDINAL; ok: BOOLEAN; starAngle: REAL;
BEGIN
  ok := Startup();
  gWin := CreateAppWindow("NewM2 GameView GPU", FBW*Scale + 16, FBH*Scale + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, FBW, FBH, cw, ch) THEN WriteString("Attach failed"); WriteLn; HALT END;
  SetupPalette;

  (* spinning coin: 4-frame strip (frame 3 = frame 1) *)
  ok := DefineSprite(0, Coin0);
  ok := AddFrame(0, Coin1); ok := AddFrame(0, Coin2); ok := AddFrame(0, Coin1);
  SpriteRGB(0, 2, 255, 205, 50);
  (* rotating star *)
  ok := DefineSprite(1, Star);
  SpriteRGB(1, 5, 255, 240, 90);

  FOR i := 0 TO 4 DO
    Place(i, 0, VAL(REAL, 40 + i*40), 100.0);
    SetScale(i, 2.0);
    SetFrame(i, i MOD 4);
    Animate(i, 7.0)
  END;
  Place(StarInst, 1, 120.0, 78.0);
  SetScale(StarInst, 2.5);

  phase := 0; starAngle := 0.0; UpdateSky(0); BuildScene;
  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    Tick(0.02);
    INC(phase); UpdateSky(phase);
    CyclePalette(32, 63);
    SetRotation(StarInst, starAngle); starAngle := starAngle + 3.0;
    Present
  END
END RetroGPU.
