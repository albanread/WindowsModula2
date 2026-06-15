MODULE ParallaxGPU;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * Parallax scrolling via blit — pre-render background layers into off-screen
 * indexed buffers (wider than the screen), then each frame Blit a window of each
 * layer into the display buffer at a different scroll rate. Far layer scrolls
 * slowest, near layer fastest -> depth. Uses GameViewGpu's multi-buffer + Blit /
 * BlitTrans, the per-line palette (the sky gradient survives the blit), palette
 * cycling, and a frame-animated sprite.
 *
 *   build: newm2 build demos/parallax_gpu.mod   then run the .exe
 *   Esc  quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, PumpMessages, Quit;
FROM GameViewGpu IMPORT Startup, Attach, LoadDefaultPalette, SetColour, SetLineRGB,
  SelectBuffer, DisplayBuffer, Blit, BlitTrans, Cls, FillRect, Disc, Pset,
  DefineSprite, AddFrame, SpriteRGB, Place, SetScale, Animate, MoveTo, Tick, Present;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;
FROM STextIO IMPORT WriteString, WriteLn;

CONST
  VIEWW = 240; VIEWH = 160; WORLDW = 480; Scale = 4;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; VK_ESCAPE = 1BH;
  BirdA = "1......1/.1....1./..1111../...11...";
  BirdB = "......../..1111../.111111./1.1..1.1";

VAR gWin: Window;

PROCEDURE Clamp8 (v: CARDINAL): CARDINAL; BEGIN IF v > 255 THEN RETURN 255 ELSE RETURN v END END Clamp8;

(* smooth triangle wave 0..amp, for rolling hills *)
PROCEDURE Tri (x, period, amp: INTEGER): INTEGER;
  VAR t: INTEGER;
BEGIN
  t := x MOD period; IF t < 0 THEN t := t + period END;
  IF t > period DIV 2 THEN t := period - t END;
  RETURN (t * amp * 2) DIV period
END Tri;

PROCEDURE SetupPalette;
  VAR y, base: CARDINAL;
BEGIN
  LoadDefaultPalette;
  SetColour(17, 0203A6BH);                       (* far hills *)
  SetColour(18, 0264D2EH);                        (* mid hills *)
  SetColour(19, 02E8B3AH);                         (* near grass *)
  SetColour(20, 05A3A1AH);                          (* tree trunk *)
  (* per-line sky gradient on index 1 *)
  FOR y := 0 TO VIEWH-1 DO
    base := 30 + (y * 120) DIV VIEWH;
    SetLineRGB(y, 1, Clamp8(base DIV 4), Clamp8(base DIV 2), Clamp8(base + 40))
  END
END SetupPalette;

PROCEDURE BuildLayers;
  VAR x, hill: INTEGER;
BEGIN
  (* far layer (buffer 1): sky (index 1 -> per-line gradient) + rolling far hills *)
  SelectBuffer(1); Cls(1);
  Disc(80, 36, 12, 14); Disc(360, 30, 12, 14);     (* two suns/moons *)
  FOR x := 0 TO WORLDW-1 DO
    hill := 92 + Tri(x, 190, 16) + Tri(x, 66, 6);
    FillRect(x, hill, 1, VIEWH-hill, 17)
  END;

  (* mid layer (buffer 2): transparent above, rolling mid hills *)
  SelectBuffer(2); Cls(0);
  FOR x := 0 TO WORLDW-1 DO
    hill := 114 + Tri(x+40, 130, 14) + Tri(x, 58, 6);
    FillRect(x, hill, 1, VIEWH-hill, 18)
  END;

  (* near layer (buffer 3): ground band + trees, transparent above *)
  SelectBuffer(3); Cls(0);
  FillRect(0, VIEWH-26, WORLDW, 26, 19);
  x := 16;
  WHILE x < WORLDW DO
    FillRect(x+3, VIEWH-40, 2, 16, 20);             (* trunk *)
    Disc(x+4, VIEWH-44, 7, 18);                      (* canopy *)
    x := x + 70
  END;
  SelectBuffer(0)
END BuildLayers;

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

VAR cw, ch: CARDINAL; ok: BOOLEAN; pos, dir, birdX: INTEGER;
BEGIN
  ok := Startup();
  gWin := CreateAppWindow("NewM2 GameView GPU - Parallax", VIEWW*Scale + 16, VIEWH*Scale + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, WORLDW, VIEWH, VIEWW, VIEWH, cw, ch) THEN WriteString("Attach failed"); WriteLn; HALT END;
  SetupPalette;
  BuildLayers;
  ok := DefineSprite(0, BirdA); ok := AddFrame(0, BirdB);
  SpriteRGB(0, 1, 30, 30, 40);
  Place(0, 0, 120.0, 44.0); SetScale(0, 2.0); Animate(0, 6.0);

  pos := 0; dir := 1; birdX := 0;
  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    Tick(0.02);
    pos := pos + dir;
    IF pos >= VIEWW THEN dir := -1 ELSIF pos <= 0 THEN dir := 1 END;
    (* compose the parallax into the display buffer *)
    SelectBuffer(0);
    Blit(1, pos DIV 4, 0, VIEWW, VIEWH, 0, 0, 0);          (* far, slowest, opaque base *)
    BlitTrans(2, pos DIV 2, 0, VIEWW, VIEWH, 0, 0, 0);     (* mid *)
    BlitTrans(3, pos, 0, VIEWW, VIEWH, 0, 0, 0);           (* near, fastest *)
    birdX := (birdX + 1) MOD (VIEWW + 40);
    MoveTo(0, VAL(REAL, birdX - 20), 40.0);
    Present
  END
END ParallaxGPU.
