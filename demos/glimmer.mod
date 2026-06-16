MODULE Glimmer;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * Glimmer — a little firefly tending its light on a drifting night.
 *
 * Steer the firefly with the arrow keys. Soft motes of light drift down; fly
 * onto them to catch them and your glow grows brighter and bigger (and a small
 * bell rings, higher the longer your streak). Dark embers drift down too —
 * brush one and your light dims and your streak resets. There's no way to lose;
 * just tend your flame under a breathing night sky, with a warm pad underneath.
 *
 * A calm counterpoint to the Galaga demo, showing off GameViewGpu's "magical low
 * colour depth" mode: a per-scanline sky gradient, alpha-blended glowing sprites,
 * and twinkling stars — all on the GPU, all in Modula-2.
 *
 *   build: newm2 build demos/glimmer.mod   then run the .exe
 *   arrows  move      Esc  quit
 *)
IMPORT WinShell;
FROM WinShell IMPORT Window, CreateAppWindow, ClientSize, PumpMessages, Quit;
FROM GameViewGpu IMPORT Startup, Attach, LoadDefaultPalette, SetRGB, SetLineRGB,
  Cls, Pset, Circle, Text, DefineSprite, SpriteRGB, Place, MoveTo, SetScale,
  SetAlpha, SetRotation, Hit, Show, Hide, Tick, Present;
FROM Abc IMPORT Tune, ParseTune;
IMPORT MidiOut;
FROM RandomNumbers IMPORT Randomize, Rnd;
FROM NM2Math IMPORT sin;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL, DWORD;
FROM System_Threading IMPORT Sleep;
FROM WholeStr IMPORT CardToStr;

CONST
  VW = 640; VH = 480;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_KEYUP = 257;
  VK_LEFT = 25H; VK_UP = 26H; VK_RIGHT = 27H; VK_DOWN = 28H; VK_ESCAPE = 1BH;
  NMotes = 24; NEmbers = 8; NStars = 72; NFlash = 10;
  (* def ids *)
  DFly = 0; DCyan = 1; DGold = 2; DRose = 3; DEmber = 4;
  (* instance ids *)
  FlyI = 0; MoteBase = 10; EmberBase = 40;
  (* global palette indices (>=16 render the same on every scanline) *)
  CText = 15; CStarLo = 16; CStarMid = 17; CStarHi = 18; CHalo = 19; CFlash = 20;

VAR
  gWin: Window; cw, ch: CARDINAL; ok: BOOLEAN;
  gLeft, gRight, gUp, gDown: BOOLEAN;
  fx, fy, glow: REAL;
  combo, score, frame: CARDINAL;
  mAct: ARRAY [0..NMotes-1] OF BOOLEAN;
  mBaseX, mY, mPhase, mAmp, mSpeed: ARRAY [0..NMotes-1] OF REAL;
  mCol: ARRAY [0..NMotes-1] OF CARDINAL;
  eAct: ARRAY [0..NEmbers-1] OF BOOLEAN;
  eBaseX, eY, ePhase, eAmp, eSpeed: ARRAY [0..NEmbers-1] OF REAL;
  sx, sy, sTw: ARRAY [0..NStars-1] OF CARDINAL;
  fAct: ARRAY [0..NFlash-1] OF BOOLEAN;
  fX, fY, fT: ARRAY [0..NFlash-1] OF CARDINAL;
  catchT: ARRAY [0..4] OF Tune; emberT: Tune;

(* ---- sound: a bell per catch (rising with the streak) + a soft ember note ---- *)
VAR abc: ARRAY [0..255] OF CHAR; an: CARDINAL;
PROCEDURE Ln (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO abc[an] := s[i]; INC(an); INC(i) END;
  abc[an] := CHR(10); INC(an); abc[an] := 0C END Ln;

PROCEDURE Bell (tier: CARDINAL; note: ARRAY OF CHAR);
BEGIN
  an := 0; Ln("X:1"); Ln("M:4/4"); Ln("L:1/16"); Ln("Q:1/4=220");
  Ln("%%MIDI program 10"); Ln("K:C"); Ln(note);
  ok := ParseTune(abc, catchT[tier])
END Bell;

PROCEDURE BuildSounds;
BEGIN
  Bell(0, "c4 z12|"); Bell(1, "e4 z12|"); Bell(2, "g4 z12|");
  Bell(3, "c'4 z12|"); Bell(4, "e'4 z12|");
  an := 0; Ln("X:1"); Ln("M:4/4"); Ln("L:1/16"); Ln("Q:1/4=160");
  Ln("%%MIDI program 89"); Ln("K:C"); Ln("E,,4 C,,8 z4|");
  ok := ParseTune(abc, emberT)
END BuildSounds;

(* ---- sprite art: soft glowing orbs ---- *)
PROCEDURE DefineSprites;
BEGIN
  (* firefly: a warm 10x10 orb with a white-hot core *)
  ok := DefineSprite(DFly, "...1111.../.12222221./1223333221/1233444321/1234444321/1234444321/1233444321/1223333221/.12222221./...1111...");
  SpriteRGB(DFly,1, 90,70,20); SpriteRGB(DFly,2, 200,160,40);
  SpriteRGB(DFly,3, 255,225,90); SpriteRGB(DFly,4, 255,255,235);

  (* mote orb shape (8x8), three colours via three defs *)
  ok := DefineSprite(DCyan, "..2222../.233332./23344332/23444432/23444432/23344332/.233332./..2222..");
  SpriteRGB(DCyan,2, 0,120,160); SpriteRGB(DCyan,3, 0,200,220); SpriteRGB(DCyan,4, 190,255,255);
  ok := DefineSprite(DGold, "..2222../.233332./23344332/23444432/23444432/23344332/.233332./..2222..");
  SpriteRGB(DGold,2, 180,120,0); SpriteRGB(DGold,3, 240,200,40); SpriteRGB(DGold,4, 255,250,200);
  ok := DefineSprite(DRose, "..2222../.233332./23344332/23444432/23444432/23344332/.233332./..2222..");
  SpriteRGB(DRose,2, 170,40,90); SpriteRGB(DRose,3, 240,90,140); SpriteRGB(DRose,4, 255,205,225);

  (* ember: a dim dark orb *)
  ok := DefineSprite(DEmber, "..2222../.233332./23344332/23444432/23444432/23344332/.233332./..2222..");
  SpriteRGB(DEmber,2, 35,18,28); SpriteRGB(DEmber,3, 80,38,48); SpriteRGB(DEmber,4, 120,55,60)
END DefineSprites;

PROCEDURE Frnd (n: CARDINAL): REAL;
BEGIN RETURN VAL(REAL, Rnd(n)) END Frnd;

(* ---- breathing night-sky gradient on per-line index 1 ---- *)
PROCEDURE UpdateSky;
  VAR y: CARDINAL; t, br: REAL; r, g, b: CARDINAL;
BEGIN
  br := 6.0 * sin(VAL(REAL, frame) * 0.012);     (* slow breath *)
  y := 0;
  WHILE y < VH DO
    t := VAL(REAL, y) / VAL(REAL, VH);
    r := VAL(CARDINAL, 10.0 + 22.0 * t + br);
    g := VAL(CARDINAL, 10.0 + 12.0 * t + br);
    b := VAL(CARDINAL, 34.0 + 20.0 * t + br);
    SetLineRGB(y, 1, r, g, b);
    INC(y)
  END
END UpdateSky;

PROCEDURE DrawStars;
  VAR i, idx: CARDINAL; tw: REAL;
BEGIN
  i := 0;
  WHILE i < NStars DO
    tw := sin(VAL(REAL, frame) * 0.05 + VAL(REAL, sTw[i]));
    IF tw > 0.6 THEN idx := CStarHi ELSIF tw > 0.0 THEN idx := CStarMid ELSE idx := CStarLo END;
    Pset(VAL(INTEGER, sx[i]), VAL(INTEGER, sy[i]), idx);
    INC(i)
  END
END DrawStars;

PROCEDURE AddFlash (px, py: REAL);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE i < NFlash DO
    IF NOT fAct[i] THEN
      fAct[i] := TRUE; fX[i] := VAL(CARDINAL, px); fY[i] := VAL(CARDINAL, py); fT[i] := 9;
      RETURN
    END;
    INC(i)
  END
END AddFlash;

PROCEDURE DrawFlashes;
  VAR i, rad: CARDINAL;
BEGIN
  i := 0;
  WHILE i < NFlash DO
    IF fAct[i] THEN
      rad := (10 - fT[i]) * 2;
      Circle(VAL(INTEGER, fX[i]), VAL(INTEGER, fY[i]), VAL(INTEGER, rad), CFlash);
      DEC(fT[i]); IF fT[i] = 0 THEN fAct[i] := FALSE END
    END;
    INC(i)
  END
END DrawFlashes;

PROCEDURE SpawnMote;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE i < NMotes DO
    IF NOT mAct[i] THEN
      mAct[i] := TRUE; mCol[i] := Rnd(3);
      mBaseX[i] := 30.0 + Frnd(VW - 60); mY[i] := -10.0;
      mPhase[i] := Frnd(628) / 100.0; mAmp[i] := 12.0 + Frnd(46); mSpeed[i] := 0.7 + Frnd(70) / 100.0;
      Place(MoteBase + i, DCyan + mCol[i], mBaseX[i], mY[i]); Show(MoteBase + i);
      RETURN
    END;
    INC(i)
  END
END SpawnMote;

PROCEDURE SpawnEmber;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE i < NEmbers DO
    IF NOT eAct[i] THEN
      eAct[i] := TRUE;
      eBaseX[i] := 30.0 + Frnd(VW - 60); eY[i] := -10.0;
      ePhase[i] := Frnd(628) / 100.0; eAmp[i] := 8.0 + Frnd(36); eSpeed[i] := 1.1 + Frnd(80) / 100.0;
      Place(EmberBase + i, DEmber, eBaseX[i], eY[i]); Show(EmberBase + i);
      RETURN
    END;
    INC(i)
  END
END SpawnEmber;

PROCEDURE Catch (col: CARDINAL; px, py: REAL);
  VAR tier: CARDINAL;
BEGIN
  INC(combo);
  tier := combo - 1; IF tier > 4 THEN tier := 4 END;
  score := score + (col + 1) * 5 + combo * 2;
  glow := glow + 0.07; IF glow > 1.0 THEN glow := 1.0 END;
  MidiOut.PlaySfx(catchT[tier]);
  AddFlash(px, py)
END Catch;

PROCEDURE Hurt;
BEGIN
  combo := 0;
  glow := glow - 0.22; IF glow < 0.25 THEN glow := 0.25 END;
  MidiOut.PlaySfx(emberT)
END Hurt;

PROCEDURE UpdateMotes;
  VAR i: CARDINAL; dx: REAL;
BEGIN
  IF (frame MOD 34 = 0) THEN SpawnMote END;
  i := 0;
  WHILE i < NMotes DO
    IF mAct[i] THEN
      mY[i] := mY[i] + mSpeed[i];
      dx := mBaseX[i] + sin(mY[i] * 0.018 + mPhase[i]) * mAmp[i];
      MoveTo(MoteBase + i, dx, mY[i]);
      SetScale(MoteBase + i, 1.0 + sin(VAL(REAL, frame) * 0.1 + mPhase[i]) * 0.14);
      IF Hit(FlyI, MoteBase + i) THEN
        Catch(mCol[i], dx, mY[i]); mAct[i] := FALSE; Hide(MoteBase + i)
      ELSIF mY[i] > VAL(REAL, VH) + 12.0 THEN
        mAct[i] := FALSE; Hide(MoteBase + i)
      END
    END;
    INC(i)
  END
END UpdateMotes;

PROCEDURE UpdateEmbers;
  VAR i: CARDINAL; dx: REAL;
BEGIN
  IF (frame MOD 95 = 0) THEN SpawnEmber END;
  i := 0;
  WHILE i < NEmbers DO
    IF eAct[i] THEN
      eY[i] := eY[i] + eSpeed[i];
      dx := eBaseX[i] + sin(eY[i] * 0.02 + ePhase[i]) * eAmp[i];
      MoveTo(EmberBase + i, dx, eY[i]);
      SetRotation(EmberBase + i, VAL(REAL, frame) * 1.5);
      IF Hit(FlyI, EmberBase + i) THEN
        Hurt; eAct[i] := FALSE; Hide(EmberBase + i)
      ELSIF eY[i] > VAL(REAL, VH) + 12.0 THEN
        eAct[i] := FALSE; Hide(EmberBase + i)
      END
    END;
    INC(i)
  END
END UpdateEmbers;

PROCEDURE UpdateFly;
BEGIN
  IF gLeft  THEN fx := fx - 3.6 END;
  IF gRight THEN fx := fx + 3.6 END;
  IF gUp    THEN fy := fy - 3.6 END;
  IF gDown  THEN fy := fy + 3.6 END;
  IF fx < 14.0 THEN fx := 14.0 END;  IF fx > VAL(REAL, VW) - 14.0 THEN fx := VAL(REAL, VW) - 14.0 END;
  IF fy < 14.0 THEN fy := 14.0 END;  IF fy > VAL(REAL, VH) - 14.0 THEN fy := VAL(REAL, VH) - 14.0 END;
  glow := glow - 0.0007; IF glow < 0.25 THEN glow := 0.25 END;   (* gently relaxes toward dim *)
  MoveTo(FlyI, fx, fy);
  SetAlpha(FlyI, 0.55 + glow * 0.45);
  SetScale(FlyI, 1.0 + glow * 1.1)
END UpdateFly;

PROCEDURE DrawHalo;                                (* a couple of faint rings = the light pool *)
  VAR r: INTEGER;
BEGIN
  r := VAL(INTEGER, 10.0 + glow * 26.0);
  Circle(VAL(INTEGER, fx), VAL(INTEGER, fy), r, CHalo);
  Circle(VAL(INTEGER, fx), VAL(INTEGER, fy), r + 6, CHalo)
END DrawHalo;

PROCEDURE DrawHud;
  VAR s: ARRAY [0..15] OF CHAR;
BEGIN
  CardToStr(score, s);
  Text(10, 10, "glimmer", CText); Text(VW - 70, 10, s, CText)
END DrawHud;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR vr: BOOL;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN vr := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF    wParam = VK_LEFT  THEN gLeft := TRUE
    ELSIF wParam = VK_RIGHT THEN gRight := TRUE
    ELSIF wParam = VK_UP    THEN gUp := TRUE
    ELSIF wParam = VK_DOWN  THEN gDown := TRUE
    ELSIF wParam = VK_ESCAPE THEN Quit END;
    RETURN 0
  ELSIF msg = WM_KEYUP THEN
    IF    wParam = VK_LEFT  THEN gLeft := FALSE
    ELSIF wParam = VK_RIGHT THEN gRight := FALSE
    ELSIF wParam = VK_UP    THEN gUp := FALSE
    ELSIF wParam = VK_DOWN  THEN gDown := FALSE END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR i: CARDINAL;
BEGIN
  Randomize(0);
  gLeft := FALSE; gRight := FALSE; gUp := FALSE; gDown := FALSE;
  fx := VAL(REAL, VW) / 2.0; fy := VAL(REAL, VH) - 80.0; glow := 0.4;
  combo := 0; score := 0; frame := 0;
  FOR i := 0 TO NMotes-1 DO mAct[i] := FALSE END;
  FOR i := 0 TO NEmbers-1 DO eAct[i] := FALSE END;
  FOR i := 0 TO NFlash-1 DO fAct[i] := FALSE END;
  FOR i := 0 TO NStars-1 DO sx[i] := 4 + Rnd(VW-8); sy[i] := 4 + Rnd(VH-8); sTw[i] := Rnd(628) END;

  ok := Startup();
  gWin := CreateAppWindow("Glimmer", VW + 16, VH + 39, Handler);
  WinShell.Show(gWin); ClientSize(gWin, cw, ch);
  ok := Attach(gWin, VW, VH, VW, VH, cw, ch);
  LoadDefaultPalette;
  SetRGB(CText, 230,230,255);
  SetRGB(CStarLo, 110,110,150); SetRGB(CStarMid, 175,175,205); SetRGB(CStarHi, 235,235,255);
  SetRGB(CHalo, 70,58,28); SetRGB(CFlash, 255,240,180);
  DefineSprites;
  Place(FlyI, DFly, fx, fy); Show(FlyI);

  BuildSounds;
  ok := MidiOut.Startup();
  MidiOut.Drone(89, 45, 34);   (* a soft warm pad under the whole night *)

  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    Tick(0.016);
    Cls(1);                    (* fill with the per-line sky gradient *)
    DrawStars;
    DrawHalo;
    UpdateFly;
    UpdateMotes;
    UpdateEmbers;
    DrawFlashes;
    UpdateSky;
    DrawHud;
    Present;
    INC(frame);
    Sleep(VAL(DWORD, 16))
  END;
  MidiOut.Shutdown
END Glimmer.
