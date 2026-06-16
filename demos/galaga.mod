MODULE Galaga;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * Galaxians / Galaga — a Modula-2 port of the FasterBASIC "16_galaxigans.bas" demo
 * (albanread/FasterBASIC-public), onto the native M2 game stack: GameViewGpu for the
 * GPU sprite layer (the BASIC SPRITE/ANIMATE/ROT/SCALE commands map to Place/Animate/
 * SetRotation/SetScale) and Abc/MidiOut for the ABC music cues.
 *
 * A formation of 60 aliens weaves overhead; they peel off and dive in sinusoidal
 * swoops, dropping bombs, then loop back to their slots. Move with the arrow keys,
 * fire with Space. Clear the formation to win; lose all 3 ships and it's game over.
 *
 *   build: newm2 build demos/galaga.mod   then run the .exe
 *   left / right  move      Space  fire      Esc  quit
 *)
IMPORT WinShell;
FROM WinShell IMPORT Window, CreateAppWindow, ClientSize, PumpMessages, Quit;
FROM GameViewGpu IMPORT Startup, Attach, LoadDefaultPalette, Cls, Text,
  DefineSprite, AddFrame, SpriteRGB, Place, MoveTo, SpriteX, SpriteY, Hit,
  SetScale, SetRotation, SetAlpha, Animate, Show, Hide, Tick, Present;
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
  VK_LEFT = 25H; VK_RIGHT = 27H; VK_SPACE = 20H; VK_ESCAPE = 1BH;
  NEnemies = 60; NBullets = 3; NBombs = 10; NExpl = 5; NStars = 24;
  (* sprite instance ids *)
  PlayerI = 0; EBase = 1; BulBase = 61; ExpBase = 64; BombBase = 70; SaucerI = 100; StarBase = 110;
  (* sprite def ids *)
  DPlayer=0; DBee=1; DBoss=2; DBullet=3; DBomb=4; DStar=5; DExpl=6; DBfly=7; DMoth=8; DSaucer=11;

  StIntro = 0; StPlay = 1; StOver = 2; StWin = 3;

VAR
  gWin: Window;
  gLeft, gRight, gFire, gFireEdge: BOOLEAN;
  px: REAL;
  alive: ARRAY [0..NEnemies] OF BOOLEAN;
  diveT, retT: ARRAY [0..NEnemies] OF REAL;
  bAct: ARRAY [0..NBullets] OF BOOLEAN;
  bx, by: ARRAY [0..NBullets] OF REAL;
  bombAct: ARRAY [0..NBombs] OF BOOLEAN;
  bombx, bomby: ARRAY [0..NBombs] OF REAL;
  expT: ARRAY [0..NExpl] OF REAL;       (* >0 = active life remaining *)
  starY: ARRAY [0..NStars] OF REAL;
  fx, fdir: REAL;
  score, lives, frame, state, stateTimer: CARDINAL;
  pAlive: BOOLEAN; pRespawn, fireCd, saucerActive: CARDINAL;
  saucerX, saucerDx: REAL; saucerTimer: CARDINAL;
  mIntro, mBoom, mWin, mOver: Tune;
  cw, ch: CARDINAL; ok: BOOLEAN;

(* ---- ABC music cues (compacted from the BASIC) ------------------------- *)
VAR abc: ARRAY [0..511] OF CHAR; an: CARDINAL;
PROCEDURE Ln (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO abc[an] := s[i]; INC(an); INC(i) END;
  abc[an] := CHR(10); INC(an); abc[an] := 0C END Ln;

PROCEDURE BuildMusic;
BEGIN
  an := 0; Ln("X:1"); Ln("M:4/4"); Ln("L:1/16"); Ln("Q:1/4=84");
  Ln("%%MIDI program 52"); Ln("K:Am"); Ln("z8 A,4 E4|A4 c4 e4 d4|c8 B8|A16|");
  ok := ParseTune(abc, mIntro);
  an := 0; Ln("X:1"); Ln("M:4/4"); Ln("L:1/16"); Ln("Q:1/4=200");
  Ln("%%MIDI percussion"); Ln("K:C"); Ln("V:1"); Ln("[B,,C,E]4 z12|");
  ok := ParseTune(abc, mBoom);
  an := 0; Ln("X:1"); Ln("M:4/4"); Ln("L:1/16"); Ln("Q:1/4=234");
  Ln("%%MIDI program 9"); Ln("K:C"); Ln("c2e2g2c'2 e'2c'2b2a2|g2e2c2G2 c4 z4|");
  ok := ParseTune(abc, mWin);
  an := 0; Ln("X:1"); Ln("M:4/4"); Ln("L:1/16"); Ln("Q:1/4=210");
  Ln("%%MIDI program 80"); Ln("K:Cm"); Ln("G,8 _B,8|c8 _e8|_e4d4c4_B4|G,16|");
  ok := ParseTune(abc, mOver)
END BuildMusic;

PROCEDURE PlayCue (VAR t: Tune);
BEGIN MidiOut.Play(t) END PlayCue;

(* ---- sprite art -------------------------------------------------------- *)
PROCEDURE DefineSprites;
BEGIN
  (* player ship (the BASIC's 16x16 art) *)
  ok := DefineSprite(DPlayer, "0000000110000000/0000001111000000/0000001111000000/0000011111100000/0000011441100000/0000011331100000/0000011331100000/0000211111120000/0002211111122000/0022221111222200/0222221111222220/2222221111222222/2222221111222222/2220022552200222/0200002552000020/0000000660000000");
  SpriteRGB(DPlayer,1,255,255,255); SpriteRGB(DPlayer,2,220,20,20); SpriteRGB(DPlayer,3,20,60,220);
  SpriteRGB(DPlayer,4,0,255,255); SpriteRGB(DPlayer,5,100,100,100); SpriteRGB(DPlayer,6,255,200,0);

  (* bee (yellow body, black outline, red wings) *)
  ok := DefineSprite(DBee, "..1..1../.122221./31222213/31222213/.122221./.1.22.1./..3..3../........");
  SpriteRGB(DBee,1,0,0,0); SpriteRGB(DBee,2,255,230,0); SpriteRGB(DBee,3,220,60,60);

  (* boss (green hull, purple wing-ends) *)
  ok := DefineSprite(DBoss, "...22.../..2222../3222 2223/32222223/.322223./.3.22.3./..3..3../........");
  SpriteRGB(DBoss,2,60,220,60); SpriteRGB(DBoss,3,180,60,180);

  (* player bullet (the BASIC's 4x8) *)
  ok := DefineSprite(DBullet, "0110/0220/0220/0220/0330/0330/0440/0440");
  SpriteRGB(DBullet,1,255,255,255); SpriteRGB(DBullet,2,255,255,0); SpriteRGB(DBullet,3,255,128,0); SpriteRGB(DBullet,4,255,0,0);

  (* enemy bomb (orange/red fireball) *)
  ok := DefineSprite(DBomb, ".11./1221/1221/.11.");
  SpriteRGB(DBomb,1,255,120,0); SpriteRGB(DBomb,2,255,60,60);

  (* star *)
  ok := DefineSprite(DStar, "11/11"); SpriteRGB(DStar,1,200,200,255);

  (* explosion burst (one frame; the game scales+fades it) *)
  ok := DefineSprite(DExpl, "...11.../..1221../.123321./11233211/11233211/.123321./..1221../...11...");
  SpriteRGB(DExpl,1,200,50,50); SpriteRGB(DExpl,2,255,120,0); SpriteRGB(DExpl,3,255,255,80);

  (* butterfly (magenta wings, white body) *)
  ok := DefineSprite(DBfly, "2......2/.2....2./.2.33.2./.233332./.233332./.2.33.2./.2....2./2......2");
  SpriteRGB(DBfly,2,220,60,220); SpriteRGB(DBfly,3,255,255,255);

  (* moth (grey body, green wings, 2 frames: wings up / down) *)
  ok := DefineSprite(DMoth, ".3....3./.33..33./.333333./.322223./.322223./..3333../...22.../........");
  ok := AddFrame(DMoth, "........./..3333../.333333./.322223./.322223./.333333./.33..33./.3....3.");
  SpriteRGB(DMoth,2,180,180,180); SpriteRGB(DMoth,3,100,255,100);

  (* bonus saucer (blue hull + canopy) *)
  ok := DefineSprite(DSaucer, "....222222....../...33333333..../..3333333333.../.333555533333../..4.4.4.4.4.4..");
  SpriteRGB(DSaucer,2,200,200,255); SpriteRGB(DSaucer,3,120,150,255); SpriteRGB(DSaucer,4,255,120,60); SpriteRGB(DSaucer,5,255,255,255)
END DefineSprites;

(* enemy row -> sprite def + animation fps *)
PROCEDURE RowDef (row: CARDINAL): CARDINAL;
BEGIN
  CASE row OF 0: RETURN DBoss | 1: RETURN DBfly | 2: RETURN DBee | 3: RETURN DMoth | 4: RETURN DBee ELSE RETURN DBfly END
END RowDef;

PROCEDURE SlotX (i: CARDINAL): REAL;        (* i in 1..60; 6 rows x 10 cols *)
  VAR col: CARDINAL;
BEGIN col := (i-1) MOD 10; RETURN VAL(REAL, 70 + col*52) + fx END SlotX;
PROCEDURE SlotY (i: CARDINAL): REAL;
  VAR row: CARDINAL;
BEGIN row := (i-1) DIV 10; RETURN VAL(REAL, 90 + row*34) END SlotY;

(* ---- explosions -------------------------------------------------------- *)
PROCEDURE Boom (x, y: REAL);
  VAR k: CARDINAL;
BEGIN
  FOR k := 0 TO NExpl-1 DO
    IF expT[k] <= 0.0 THEN
      expT[k] := 1.0; Place(ExpBase+k, DExpl, x, y); SetScale(ExpBase+k, 0.7); SetAlpha(ExpBase+k, 1.0);
      RETURN
    END
  END
END Boom;

PROCEDURE UpdateExpl;
  VAR k: CARDINAL;
BEGIN
  FOR k := 0 TO NExpl-1 DO
    IF expT[k] > 0.0 THEN
      expT[k] := expT[k] - 0.07;
      SetScale(ExpBase+k, 0.7 + (1.0-expT[k])*2.2);
      SetAlpha(ExpBase+k, expT[k]);
      IF expT[k] <= 0.0 THEN Hide(ExpBase+k) END
    END
  END
END UpdateExpl;

(* ---- setup ------------------------------------------------------------- *)
PROCEDURE PlaceFormation;
  VAR i, row: CARDINAL;
BEGIN
  FOR i := 1 TO NEnemies DO
    row := (i-1) DIV 10;
    alive[i] := TRUE; diveT[i] := 0.0; retT[i] := 0.0;
    Place(i, RowDef(row), SlotX(i), SlotY(i));
    SetScale(i, 2.6); Animate(i, 4.0)
  END
END PlaceFormation;

PROCEDURE ResetGame;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO NBullets-1 DO bAct[i] := FALSE; Hide(BulBase+i) END;
  FOR i := 0 TO NBombs-1 DO bombAct[i] := FALSE; Hide(BombBase+i) END;
  FOR i := 0 TO NExpl-1 DO expT[i] := 0.0; Hide(ExpBase+i) END;
  px := 308.0; pAlive := TRUE; pRespawn := 0; fireCd := 0;
  score := 0; lives := 3; frame := 0;
  fx := 0.0; fdir := 1.0;
  saucerActive := 0; saucerTimer := 240;
  Place(PlayerI, DPlayer, px, 440.0); SetScale(PlayerI, 1.7); Show(PlayerI);
  PlaceFormation;
  Hide(SaucerI)
END ResetGame;

(* ---- update: player ---------------------------------------------------- *)
PROCEDURE UpdatePlayer;
  VAR i: CARDINAL; ang: REAL;
BEGIN
  IF NOT pAlive THEN
    INC(pRespawn);
    IF (pRespawn > 90) AND (lives > 0) THEN
      pAlive := TRUE; pRespawn := 0; px := 308.0;
      Place(PlayerI, DPlayer, px, 440.0); SetScale(PlayerI, 1.7); Show(PlayerI)
    END;
    RETURN
  END;
  ang := 0.0;
  IF gLeft  THEN px := px - 4.0; ang := -12.0 END;
  IF gRight THEN px := px + 4.0; ang := 12.0 END;
  IF px < 12.0 THEN px := 12.0 END;
  IF px > 628.0 THEN px := 628.0 END;
  MoveTo(PlayerI, px, 440.0); SetRotation(PlayerI, ang);
  IF fireCd > 0 THEN DEC(fireCd) END;
  IF gFireEdge AND (fireCd = 0) THEN
    gFireEdge := FALSE;
    FOR i := 0 TO NBullets-1 DO
      IF NOT bAct[i] THEN
        bAct[i] := TRUE; bx[i] := px; by[i] := 424.0;
        Place(BulBase+i, DBullet, bx[i], by[i]); SetScale(BulBase+i, 1.6); Show(BulBase+i);
        fireCd := 14; PlayCue(mBoom);
        RETURN
      END
    END
  END;
  gFireEdge := FALSE
END UpdatePlayer;

(* ---- update: enemies (formation + dive/return) ------------------------- *)
PROCEDURE UpdateEnemies;
  VAR i, k: CARDINAL; ex, ey, t: REAL; placed: BOOLEAN;
BEGIN
  fx := fx + 0.6 * fdir;
  IF fx > 60.0 THEN fdir := -1.0 ELSIF fx < -60.0 THEN fdir := 1.0 END;

  (* launch a diver from a random alive enemy every ~40 frames *)
  IF frame MOD 40 = 0 THEN
    k := 1 + Rnd(NEnemies);
    IF (k <= NEnemies) AND alive[k] AND (diveT[k] = 0.0) AND (retT[k] = 0.0) THEN diveT[k] := 0.001 END
  END;
  (* a random alive enemy drops a bomb every ~30 frames *)
  IF (frame MOD 30 = 0) AND pAlive THEN
    k := 1 + Rnd(NEnemies);
    IF (k <= NEnemies) AND alive[k] THEN
      placed := FALSE; i := 0;
      WHILE (i < NBombs) AND (NOT placed) DO
        IF NOT bombAct[i] THEN
          bombAct[i] := TRUE; bombx[i] := SpriteX(k); bomby[i] := SpriteY(k)+10.0;
          Place(BombBase+i, DBomb, bombx[i], bomby[i]); SetScale(BombBase+i, 2.2); Show(BombBase+i); placed := TRUE
        END;
        INC(i)
      END
    END
  END;

  FOR i := 1 TO NEnemies DO
    IF alive[i] THEN
      ex := SlotX(i); ey := SlotY(i);
      IF diveT[i] > 0.0 THEN                       (* swooping down *)
        diveT[i] := diveT[i] + 0.005; t := diveT[i];
        ex := ex + sin(t*2.5)*180.0; ey := ey + t*460.0;
        SetRotation(i, 180.0 + sin(t*2.5)*25.0);
        IF ey > 520.0 THEN                         (* off bottom -> return from top *)
          diveT[i] := 0.0; retT[i] := 0.001; SetRotation(i, 180.0)
        END
      ELSIF retT[i] > 0.0 THEN                      (* fly back to formation slot *)
        retT[i] := retT[i] + 0.006; t := retT[i];
        IF t >= 1.0 THEN retT[i] := 0.0; SetRotation(i, 0.0)
        ELSE
          ex := ex + sin(t*3.14159)*70.0; ey := -30.0 + t*(ey + 30.0);
          SetRotation(i, 180.0*(1.0-t))
        END
      END;
      MoveTo(i, ex, ey);
      (* diving enemy rams the player *)
      IF pAlive AND (diveT[i] > 0.0) AND Hit(i, PlayerI) THEN
        alive[i] := FALSE; Hide(i); Boom(ex, ey); KillPlayer
      END
    END
  END
END UpdateEnemies;

PROCEDURE KillPlayer;
BEGIN
  pAlive := FALSE; pRespawn := 0; Hide(PlayerI);
  Boom(px, 440.0); PlayCue(mOver);
  IF lives > 0 THEN DEC(lives) END
END KillPlayer;

(* ---- update: bullets + bombs + saucer ---------------------------------- *)
PROCEDURE UpdateBullets;
  VAR i, j: CARDINAL;
BEGIN
  FOR i := 0 TO NBullets-1 DO
    IF bAct[i] THEN
      by[i] := by[i] - 7.0; MoveTo(BulBase+i, bx[i], by[i]);
      IF by[i] < -10.0 THEN bAct[i] := FALSE; Hide(BulBase+i) END;
      IF bAct[i] THEN
        FOR j := 1 TO NEnemies DO
          IF alive[j] AND bAct[i] AND Hit(BulBase+i, j) THEN
            alive[j] := FALSE; bAct[i] := FALSE; INC(score, 10);
            Hide(j); Hide(BulBase+i); Boom(SpriteX(j), SpriteY(j))
          END
        END
      END;
      IF bAct[i] AND (saucerActive = 1) AND Hit(BulBase+i, SaucerI) THEN
        bAct[i] := FALSE; Hide(BulBase+i); saucerActive := 0; Hide(SaucerI);
        saucerTimer := 320; INC(score, 100); Boom(saucerX, 40.0); Boom(saucerX+18.0, 44.0)
      END
    END
  END
END UpdateBullets;

PROCEDURE UpdateBombs;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO NBombs-1 DO
    IF bombAct[i] THEN
      bomby[i] := bomby[i] + 4.5; MoveTo(BombBase+i, bombx[i], bomby[i]);
      IF bomby[i] > 490.0 THEN bombAct[i] := FALSE; Hide(BombBase+i) END;
      IF bombAct[i] AND pAlive AND Hit(BombBase+i, PlayerI) THEN
        bombAct[i] := FALSE; Hide(BombBase+i); KillPlayer
      END
    END
  END
END UpdateBombs;

PROCEDURE UpdateSaucer;
BEGIN
  IF saucerActive = 0 THEN
    IF saucerTimer > 0 THEN DEC(saucerTimer) END;
    IF saucerTimer = 0 THEN
      saucerActive := 1;
      IF Rnd(2) = 0 THEN saucerX := -40.0; saucerDx := 2.6 ELSE saucerX := 680.0; saucerDx := -2.6 END;
      Place(SaucerI, DSaucer, saucerX, 40.0); SetScale(SaucerI, 2.2); Show(SaucerI)
    END;
    RETURN
  END;
  saucerX := saucerX + saucerDx; MoveTo(SaucerI, saucerX, 40.0);
  IF (saucerX < -80.0) OR (saucerX > 720.0) THEN
    saucerActive := 0; saucerTimer := 300 + Rnd(360); Hide(SaucerI)
  END
END UpdateSaucer;

PROCEDURE UpdateStars;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO NStars-1 DO
    starY[i] := starY[i] + 1.5; IF starY[i] > VAL(REAL,VH) THEN starY[i] := -4.0 END;
    MoveTo(StarBase+i, SpriteX(StarBase+i), starY[i])
  END
END UpdateStars;

PROCEDURE AllDead (): BOOLEAN;
  VAR i: CARDINAL;
BEGIN FOR i := 1 TO NEnemies DO IF alive[i] THEN RETURN FALSE END END; RETURN TRUE END AllDead;

(* ---- HUD --------------------------------------------------------------- *)
PROCEDURE DrawHud;
  VAR s: ARRAY [0..15] OF CHAR; i: CARDINAL;
BEGIN
  Cls(0);
  Text(8, 8, "SCORE", 15); CardToStr(score, s); Text(56, 8, s, 14);
  Text(560, 8, "SHIPS", 15); CardToStr(lives, s); Text(610, 8, s, 12)
END DrawHud;

(* ---- input ------------------------------------------------------------- *)
PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR vr: BOOL;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN vr := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF    wParam = VK_LEFT  THEN gLeft := TRUE
    ELSIF wParam = VK_RIGHT THEN gRight := TRUE
    ELSIF wParam = VK_SPACE THEN IF NOT gFire THEN gFireEdge := TRUE END; gFire := TRUE
    ELSIF wParam = VK_ESCAPE THEN Quit END;
    RETURN 0
  ELSIF msg = WM_KEYUP THEN
    IF    wParam = VK_LEFT  THEN gLeft := FALSE
    ELSIF wParam = VK_RIGHT THEN gRight := FALSE
    ELSIF wParam = VK_SPACE THEN gFire := FALSE END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR i: CARDINAL;
BEGIN
  Randomize(0);
  gLeft := FALSE; gRight := FALSE; gFire := FALSE; gFireEdge := FALSE;
  ok := Startup();
  gWin := CreateAppWindow("NewM2 Galaga", VW + 16, VH + 39, Handler);
  WinShell.Show(gWin); ClientSize(gWin, cw, ch);
  ok := Attach(gWin, VW, VH, VW, VH, cw, ch);
  LoadDefaultPalette;
  DefineSprites;
  BuildMusic;
  ok := MidiOut.Startup();
  (* stars *)
  FOR i := 0 TO NStars-1 DO
    starY[i] := VAL(REAL, Rnd(VH));
    Place(StarBase+i, DStar, VAL(REAL, 4 + Rnd(VW-8)), starY[i]); Show(StarBase+i)
  END;
  ResetGame;
  state := StIntro; stateTimer := 0;
  PlayCue(mIntro);

  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    Tick(0.016);
    DrawHud;
    UpdateStars;
    IF state = StIntro THEN
      Text(250, 220, "PLAYER ONE READY", 9 + (stateTimer DIV 10) MOD 6);
      INC(stateTimer);
      IF (stateTimer > 150) OR gFire THEN state := StPlay; frame := 0 END
    ELSIF state = StPlay THEN
      UpdatePlayer; UpdateEnemies; UpdateBombs; UpdateSaucer; UpdateBullets; UpdateExpl;
      INC(frame);
      IF (lives = 0) AND (NOT pAlive) THEN state := StOver; stateTimer := 0; PlayCue(mOver)
      ELSIF AllDead() THEN state := StWin; stateTimer := 0; PlayCue(mWin) END
    ELSIF state = StOver THEN
      UpdateExpl;
      Text(270, 220, "GAME OVER", 9 + (stateTimer DIV 8) MOD 6);
      INC(stateTimer); IF stateTimer > 300 THEN ResetGame; state := StIntro; stateTimer := 0; PlayCue(mIntro) END
    ELSE   (* StWin *)
      UpdateExpl;
      Text(258, 220, "YOU WIN", 9 + (stateTimer DIV 6) MOD 6);
      INC(stateTimer); IF stateTimer > 200 THEN ResetGame; state := StIntro; stateTimer := 0; PlayCue(mIntro) END
    END;
    Present;
    Sleep(VAL(DWORD, 16))
  END;
  MidiOut.Shutdown
END Galaga.
