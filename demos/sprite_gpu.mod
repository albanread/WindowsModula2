MODULE SpriteGPU;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * Sprite layer de-risk — a second alpha-blended quad pass over the indexed
 * background, the way winscheme composites sprites. The background is the GPU
 * palette-LUT present (index buffer -> RGBA). On top, three instances of one
 * 16x16 indexed sprite (its OWN palette, index 0 transparent) are drawn as
 * transformed quads:
 *   left   — solid (alpha 1)         : transparent corners show the background
 *   centre — alpha pulsing           : proves SRC_ALPHA/INV_SRC_ALPHA blending
 *   right  — rotating                : proves the CPU-baked quad transform
 *
 * Proves ShaderView's new sprite pass: dynamic vertex buffer + input layout +
 * blend state + sprite VS/PS pair + BeginFrame/DrawSprites/EndFrame.
 *
 *   build: newm2 build demos/sprite_gpu.mod   then run the .exe
 *   Esc  quit
 *)
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, PumpMessages, Quit;
FROM ShaderView IMPORT Startup, Attach, SetShader, BindTexture, UploadTexture,
  InitSprites, UploadAtlas, UploadSpritePalette, BeginFrame, DrawSprites, EndFrame;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;
FROM STextIO IMPORT WriteString, WriteLn;
FROM RealMath IMPORT sin, cos;

CONST
  FBW = 256; FBH = 192; Scale = 3;
  AW = 16; AH = 16;                       (* atlas / sprite size *)
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256;
  VK_ESCAPE = 1BH;
  FmtR8UINT = 62; FmtBGRA8 = 87;

  BgShader = "struct VSOut { float4 pos:SV_Position; float2 uv:TEXCOORD0; }; Texture2D<uint> gIdx:register(t0); Texture2D<float4> gPal:register(t1); float4 main(VSOut i):SV_Target { uint w,h; gIdx.GetDimensions(w,h); int2 p=int2(i.uv*float2(w,h)); p=clamp(p,int2(0,0),int2(int(w)-1,int(h)-1)); uint c=gIdx.Load(int3(p,0)); return float4(gPal.Load(int3(int(c),0,0)).rgb,1.0); }";

TYPE
  CB = RECORD time: SHORTREAL; a, b, c: INTEGER32 END;

VAR
  gWin:   Window;
  gIdx:   ARRAY [0..FBW*FBH-1] OF BYTE;
  gPal:   ARRAY [0..255] OF CARDINAL32;
  gAtlas: ARRAY [0..AW*AH-1] OF BYTE;
  gSPal:  ARRAY [0..16*4-1] OF CARDINAL32;       (* 4 sprite slots x 16 colours *)
  gVerts: ARRAY [0..511] OF SHORTREAL;           (* 6 floats / vertex *)
  gN:     CARDINAL;                              (* floats pushed *)
  gCW, gCH: REAL;                                (* swapchain client size *)
  cb:     CB;

PROCEDURE RGB (r, g, b: CARDINAL): CARDINAL32;
BEGIN RETURN VAL(CARDINAL32, ((r BAND 0FFH)*65536) + ((g BAND 0FFH)*256) + (b BAND 0FFH)) END RGB;

PROCEDURE BuildBackground;
  VAR x, y, i: CARDINAL;
BEGIN
  FOR i := 0 TO 15 DO gPal[16+i] := RGB(8 + i*2, 20 + i*6, 40 + i*10) END;  (* sky gradient *)
  FOR y := 0 TO FBH-1 DO
    FOR x := 0 TO FBW-1 DO gIdx[y*FBW + x] := VAL(BYTE, 16 + (y * 16) DIV FBH) END
  END
END BuildBackground;

PROCEDURE BuildSprite;
  VAR x, y: INTEGER; dx, dy, d2, hx, hy: INTEGER; idx: CARDINAL;
BEGIN
  FOR y := 0 TO AH-1 DO
    FOR x := 0 TO AW-1 DO
      dx := 2*x - 15; dy := 2*y - 15;             (* centre 0, range -15..15 *)
      d2 := dx*dx + dy*dy;
      IF d2 > 225 THEN idx := 0                    (* outside -> transparent *)
      ELSIF d2 > 150 THEN idx := 3                 (* dark rim *)
      ELSE
        hx := dx + 6; hy := dy + 6;
        IF hx*hx + hy*hy < 70 THEN idx := 1        (* highlight *)
        ELSE idx := 2 END                          (* body *)
      END;
      gAtlas[y*AW + x] := VAL(BYTE, idx)
    END
  END;
  (* sprite slot 0 palette: 1=highlight, 2=body, 3=rim (0 unused/transparent) *)
  gSPal[1] := RGB(255,255,235); gSPal[2] := RGB(225,55,55); gSPal[3] := RGB(120,12,12)
END BuildSprite;

PROCEDURE Vertex (px, py, u, w, slot, alpha: REAL);
BEGIN
  gVerts[gN]   := VAL(SHORTREAL, px/gCW*2.0 - 1.0);
  gVerts[gN+1] := VAL(SHORTREAL, 1.0 - py/gCH*2.0);
  gVerts[gN+2] := VAL(SHORTREAL, u);
  gVerts[gN+3] := VAL(SHORTREAL, w);
  gVerts[gN+4] := VAL(SHORTREAL, slot);
  gVerts[gN+5] := VAL(SHORTREAL, alpha);
  gN := gN + 6
END Vertex;

(* one quad (6 verts: TL TR BR / TL BR BL), corners rotated about (cx,cy) *)
PROCEDURE EmitQuad (cx, cy, half, angle, alpha, slot: REAL);
  VAR ca, sa: REAL;
      tlx, tly, trx, trY, brx, brY, blx, blY: REAL;
BEGIN
  ca := cos(angle); sa := sin(angle);
  tlx := cx + (-half)*ca - (-half)*sa; tly := cy + (-half)*sa + (-half)*ca;
  trx := cx + ( half)*ca - (-half)*sa; trY := cy + ( half)*sa + (-half)*ca;
  brx := cx + ( half)*ca - ( half)*sa; brY := cy + ( half)*sa + ( half)*ca;
  blx := cx + (-half)*ca - ( half)*sa; blY := cy + (-half)*sa + ( half)*ca;
  Vertex(tlx,tly, 0.0,    0.0,    slot, alpha);
  Vertex(trx,trY, VAL(REAL,AW), 0.0,    slot, alpha);
  Vertex(brx,brY, VAL(REAL,AW), VAL(REAL,AH), slot, alpha);
  Vertex(tlx,tly, 0.0,    0.0,    slot, alpha);
  Vertex(brx,brY, VAL(REAL,AW), VAL(REAL,AH), slot, alpha);
  Vertex(blx,blY, 0.0,    VAL(REAL,AH), slot, alpha)
END EmitQuad;

PROCEDURE BuildSprites (t: REAL);
BEGIN
  gN := 0;
  EmitQuad(gCW*0.30, gCH*0.5, 52.0, 0.0, 1.0, 0.0);                          (* solid *)
  EmitQuad(gCW*0.50, gCH*0.5, 52.0, 0.0, 0.35 + 0.35*(0.5+0.5*sin(t*2.0)), 0.0);  (* pulsing *)
  EmitQuad(gCW*0.70, gCH*0.5, 52.0, t, 1.0, 0.0)                             (* rotating *)
END BuildSprites;

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

VAR cw, ch: CARDINAL; ok: BOOLEAN; t: REAL;
BEGIN
  BuildBackground;
  BuildSprite;
  ok := Startup();
  gWin := CreateAppWindow("NewM2 GPU Sprites (alpha layer)", FBW*Scale + 16, FBH*Scale + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  gCW := VAL(REAL, cw); gCH := VAL(REAL, ch);
  IF NOT Attach(gWin, cw, ch) THEN WriteString("Attach failed"); WriteLn; HALT END;
  IF NOT SetShader(BgShader, SIZE(cb)) THEN WriteString("bg shader failed"); WriteLn; HALT END;
  IF NOT BindTexture(0, FBW, FBH, FmtR8UINT) THEN WriteString("index tex failed"); WriteLn; HALT END;
  IF NOT BindTexture(1, 256, 1, FmtBGRA8)    THEN WriteString("palette tex failed"); WriteLn; HALT END;
  IF NOT InitSprites(AW, AH, 16, 4, 64)      THEN WriteString("InitSprites failed"); WriteLn; HALT END;
  UploadTexture(0, ADR(gIdx), FBW);
  UploadTexture(1, ADR(gPal), 1024);
  UploadAtlas(ADR(gAtlas), AW);
  UploadSpritePalette(ADR(gSPal), 16*4);
  t := 0.0;
  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    BuildSprites(t);
    BeginFrame(ADR(cb));
    DrawSprites(ADR(gVerts), gN DIV 6);
    EndFrame;
    t := t + 0.02
  END
END SpriteGPU.
