MODULE ScrollGPU;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * Smooth GPU scrolling over an OVER-ALLOCATED world. The index buffer is a 640-wide
 * world but only a 240-wide view is shown; SetScroll moves the viewport over the
 * world each frame (pure GPU sampling — no per-frame redraw), so the wide landscape
 * pans smoothly. Sprites (spinning coins) are placed in WORLD coordinates, so they
 * scroll in and out of view with the world.
 *
 *   build: newm2 build demos/scroll_gpu.mod   then run the .exe
 *   Esc  quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, PumpMessages, Quit;
FROM GameViewGpu IMPORT Startup, Attach, LoadDefaultPalette, SetColour, SetLineRGB,
  SetScroll, Cls, FillRect, Disc, DefineSprite, AddFrame, SpriteRGB,
  Place, SetScale, SetFrame, Animate, Tick, Present;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;
FROM STextIO IMPORT WriteString, WriteLn;

CONST
  WORLDW = 640; VIEWW = 240; VIEWH = 160; Scale = 4;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; VK_ESCAPE = 1BH;
  Coin0 = "..2222../.222222./22222222/22222222/22222222/22222222/.222222./..2222..";
  Coin1 = "...22.../..2222../..2222../..2222../..2222../..2222../..2222../...22...";
  Coin2 = "...22.../...22.../...22.../...22.../...22.../...22.../...22.../...22...";

VAR gWin: Window;

PROCEDURE Clamp8 (v: CARDINAL): CARDINAL; BEGIN IF v > 255 THEN RETURN 255 ELSE RETURN v END END Clamp8;

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
  SetColour(18, 04A5070H);                          (* mountains *)
  SetColour(19, 02E8B3AH);                            (* grass *)
  SetColour(20, 05A3A1AH);                             (* trunk *)
  SetColour(21, 01F6B2AH);                              (* tree canopy *)
  FOR y := 0 TO VIEWH-1 DO
    base := 30 + (y * 120) DIV VIEWH;
    SetLineRGB(y, 1, Clamp8(base DIV 4), Clamp8(base DIV 2), Clamp8(base + 50))
  END
END SetupPalette;

(* draw a wide landscape ONCE into the (640-wide) world *)
PROCEDURE BuildWorld;
  VAR x, peak: INTEGER;
BEGIN
  Cls(1);                                            (* sky: index 1 -> per-line gradient *)
  Disc(70, 36, 14, 14);                              (* sun *)
  FOR x := 0 TO WORLDW-1 DO
    peak := 86 + Tri(x, 220, 28) + Tri(x+60, 96, 12);
    FillRect(x, peak, 1, VIEWH-peak, 18)             (* mountains *)
  END;
  FillRect(0, VIEWH-24, WORLDW, 24, 19);             (* ground *)
  x := 24;
  WHILE x < WORLDW DO
    FillRect(x+3, VIEWH-38, 2, 16, 20);              (* trunk *)
    Disc(x+4, VIEWH-44, 7, 21);                       (* green canopy *)
    x := x + 90
  END
END BuildWorld;

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

VAR cw, ch, i: CARDINAL; ok: BOOLEAN; pos, dir: INTEGER;
BEGIN
  ok := Startup();
  gWin := CreateAppWindow("NewM2 GameView GPU - Scroll", VIEWW*Scale + 16, VIEWH*Scale + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, WORLDW, VIEWH, VIEWW, VIEWH, cw, ch) THEN WriteString("Attach failed"); WriteLn; HALT END;
  SetupPalette;
  BuildWorld;

  (* spinning coins at fixed WORLD positions, every 110 px across the world *)
  ok := DefineSprite(0, Coin0);
  ok := AddFrame(0, Coin1); ok := AddFrame(0, Coin2); ok := AddFrame(0, Coin1);
  SpriteRGB(0, 2, 255, 205, 50);
  FOR i := 0 TO 4 DO
    Place(i, 0, VAL(REAL, 90 + i*110), 74.0);
    SetScale(i, 2.0); SetFrame(i, i MOD 4); Animate(i, 7.0)
  END;

  pos := 0; dir := 1;
  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    Tick(0.02);
    pos := pos + dir;
    IF pos >= WORLDW - VIEWW THEN dir := -1 ELSIF pos <= 0 THEN dir := 1 END;
    SetScroll(pos, 0);
    Present
  END
END ScrollGPU.
