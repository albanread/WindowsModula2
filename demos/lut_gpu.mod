MODULE LutGPU;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * GPU indexed-colour present — the retro mode the way winscheme does it, with the
 * full PER-LINE palette model. A framebuffer of 1-byte palette INDICES is uploaded
 * as an R8_UINT texture; the pixel shader resolves index->RGBA on the GPU with the
 * 16+240 split:
 *     index 0..15   -> that SCANLINE's own 16-colour palette (a 16 x H LUT)
 *     index 16..255 -> the global 240-colour palette (a 256 x 1 LUT)
 * so a single low index can be a smooth vertical gradient + moving copper bars
 * (re-uploading a 12 KB line LUT per frame), while the global range animates by
 * palette cycling (a 1 KB re-upload) — all with zero per-pixel CPU work. The GPU
 * also upscales the 256x192 image to the window for free.
 *
 * Validates the textured-present path in ShaderView (BindTexture/UploadTexture) and
 * the per-line palette split — the GameView GPU foundation.
 *
 *   build: newm2 build demos/lut_gpu.mod   then run the .exe
 *   Esc  quit
 *)
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Quit;
FROM ShaderView IMPORT Startup, Attach, SetShader, BindTexture, UploadTexture, RunLoop;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;
FROM STextIO IMPORT WriteString, WriteLn;

CONST
  FBW = 256; FBH = 192; Scale = 3;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256;
  VK_ESCAPE = 1BH;

  FmtR8UINT = 62;        (* DXGI_FORMAT_R8_UINT        — the index buffer *)
  FmtBGRA8  = 87;        (* DXGI_FORMAT_B8G8R8A8_UNORM — palette LUTs (0x00RRGGBB -> .rgb) *)

  (* Lookup pixel shader: index 0..15 -> line palette row p.y, else -> global palette. *)
  LutShader = "struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; }; Texture2D<uint> gIdx : register(t0); Texture2D<float4> gPal : register(t1); Texture2D<float4> gLine : register(t2); float4 main(VSOut i) : SV_Target { uint w,h; gIdx.GetDimensions(w,h); int2 p = int2(i.uv * float2(w,h)); p = clamp(p, int2(0,0), int2(int(w)-1,int(h)-1)); uint c = gIdx.Load(int3(p,0)); float4 col; if (c < 16u) col = gLine.Load(int3(int(c), p.y, 0)); else col = gPal.Load(int3(int(c), 0, 0)); return float4(col.rgb, 1.0); }";

TYPE
  CB = RECORD time: SHORTREAL; flags, pad0, pad1: INTEGER32 END;

VAR
  gWin:  Window;
  gIdx:  ARRAY [0..FBW*FBH-1] OF BYTE;       (* the indexed framebuffer *)
  gPal:  ARRAY [0..255] OF CARDINAL32;       (* global palette, 0x00RRGGBB *)
  gLine: ARRAY [0..16*FBH-1] OF CARDINAL32;  (* per-scanline low-16 palette (16 x FBH) *)
  gPhase: CARDINAL;
  cb:    CB;

PROCEDURE RGB (r, g, b: CARDINAL): CARDINAL32;
BEGIN
  RETURN VAL(CARDINAL32, ((r BAND 0FFH) * 65536) + ((g BAND 0FFH) * 256) + (b BAND 0FFH))
END RGB;

PROCEDURE Clamp8 (v: CARDINAL): CARDINAL;
BEGIN IF v > 255 THEN RETURN 255 ELSE RETURN v END END Clamp8;

PROCEDURE Plot (x, y, idx: CARDINAL);
BEGIN
  IF (x < FBW) AND (y < FBH) THEN gIdx[y*FBW + x] := VAL(BYTE, idx BAND 0FFH) END
END Plot;

PROCEDURE FillBlock (x0, y0, w, h, idx: CARDINAL);
  VAR x, y: CARDINAL;
BEGIN
  FOR y := y0 TO y0+h-1 DO FOR x := x0 TO x0+w-1 DO Plot(x, y, idx) END END
END FillBlock;

PROCEDURE BuildPalette;
  CONST N = 12;
  VAR i: CARDINAL; tab: ARRAY [0..N-1] OF CARDINAL32;
BEGIN
  FOR i := 0 TO 255 DO gPal[i] := RGB(0,0,0) END;
  (* classic 16 (used to seed every line-palette row so swatches/text are solid) *)
  gPal[1]:=RGB(0,0,0AAH);   gPal[2]:=RGB(0,0AAH,0);   gPal[3]:=RGB(0,0AAH,0AAH);
  gPal[4]:=RGB(0AAH,0,0);   gPal[5]:=RGB(0AAH,0,0AAH);gPal[6]:=RGB(0AAH,55H,0);
  gPal[7]:=RGB(0AAH,0AAH,0AAH); gPal[8]:=RGB(55H,55H,55H);
  gPal[9]:=RGB(55H,55H,0FFH);gPal[10]:=RGB(55H,0FFH,55H);gPal[11]:=RGB(55H,0FFH,0FFH);
  gPal[12]:=RGB(0FFH,55H,55H);gPal[13]:=RGB(0FFH,55H,0FFH);gPal[14]:=RGB(0FFH,0FFH,55H);
  gPal[15]:=RGB(0FFH,0FFH,0FFH);
  (* 32..63 = a 32-entry rainbow (cycled by palette rotation) *)
  tab[0]:=RGB(0FFH,0,0);    tab[1]:=RGB(0FFH,7FH,0);  tab[2]:=RGB(0FFH,0FFH,0);
  tab[3]:=RGB(7FH,0FFH,0);  tab[4]:=RGB(0,0FFH,0);    tab[5]:=RGB(0,0FFH,7FH);
  tab[6]:=RGB(0,0FFH,0FFH); tab[7]:=RGB(0,7FH,0FFH);  tab[8]:=RGB(0,0,0FFH);
  tab[9]:=RGB(7FH,0,0FFH);  tab[10]:=RGB(0FFH,0,0FFH);tab[11]:=RGB(0FFH,0,7FH);
  FOR i := 0 TO 31 DO gPal[32+i] := tab[i MOD N] END
END BuildPalette;

(* every scanline's low 16 default to the classic palette (so a low index drawn
   anywhere is a solid colour) — except index 1, which UpdateLine animates. *)
PROCEDURE SeedLinePalette;
  VAR y, idx: CARDINAL;
BEGIN
  FOR y := 0 TO FBH-1 DO
    FOR idx := 0 TO 15 DO gLine[y*16 + idx] := gPal[idx] END
  END
END SeedLinePalette;

(* line index 1 becomes a smooth blue gradient with copper bars scrolling down *)
PROCEDURE UpdateLine (phase: CARDINAL);
  VAR y, base, bar, add, r, g, b: CARDINAL;
BEGIN
  FOR y := 0 TO FBH-1 DO
    base := 30 + (y * 100) DIV FBH;
    bar  := (y + phase) MOD 40;
    IF bar < 5 THEN add := (5 - bar) * 32 ELSE add := 0 END;
    r := Clamp8(base DIV 3 + add); g := Clamp8(base DIV 2 + add); b := Clamp8(base + add);
    gLine[y*16 + 1] := RGB(r, g, b)
  END
END UpdateLine;

PROCEDURE BuildIndex;
  VAR x, y, idx, i: CARDINAL;
BEGIN
  FOR y := 0 TO FBH-1 DO
    FOR x := 0 TO FBW-1 DO
      idx := 1;                                     (* sky: low index -> per-line gradient *)
      IF (y >= FBH DIV 2 - 16) AND (y < FBH DIV 2 + 16) THEN
        idx := 32 + (x MOD 32)                      (* rainbow band: global, cycled *)
      END;
      gIdx[y*FBW + x] := VAL(BYTE, idx BAND 0FFH)
    END
  END;
  (* six solid swatches across the top (low indices 2..7 -> constant per-line colours) *)
  FOR i := 0 TO 5 DO FillBlock(8 + i*40, 8, 32, 22, 2 + i) END;
  (* white frame (index 15, constant per line) *)
  FOR x := 0 TO FBW-1 DO Plot(x, 0, 15); Plot(x, FBH-1, 15) END;
  FOR y := 0 TO FBH-1 DO Plot(0, y, 15); Plot(FBW-1, y, 15) END
END BuildIndex;

(* per frame: cycle the global rainbow + scroll the per-line gradient, re-upload both LUTs *)
PROCEDURE Build (time: SHORTREAL): ADDRESS;
  VAR i: CARDINAL; tmp: CARDINAL32;
BEGIN
  tmp := gPal[32];
  FOR i := 32 TO 62 DO gPal[i] := gPal[i+1] END;
  gPal[63] := tmp;
  UploadTexture(1, ADR(gPal), 1024);                (* global LUT: 256 * 4 *)
  INC(gPhase);
  UpdateLine(gPhase);
  UploadTexture(2, ADR(gLine), 64);                 (* line LUT row pitch: 16 * 4 *)
  cb.time := time;
  RETURN ADR(cb)
END Build;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF wParam = VK_ESCAPE THEN Quit END; RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  gPhase := 0;
  BuildPalette;
  SeedLinePalette;
  UpdateLine(0);
  BuildIndex;
  ok := Startup();
  gWin := CreateAppWindow("NewM2 GPU Indexed (LUT + per-line palette)", FBW*Scale + 16, FBH*Scale + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, cw, ch) THEN WriteString("D3D11 Attach failed"); WriteLn; HALT END;
  IF NOT SetShader(LutShader, SIZE(cb)) THEN WriteString("shader compile failed"); WriteLn; HALT END;
  IF NOT BindTexture(0, FBW, FBH, FmtR8UINT) THEN WriteString("index texture failed"); WriteLn; HALT END;
  IF NOT BindTexture(1, 256, 1, FmtBGRA8)    THEN WriteString("global palette failed"); WriteLn; HALT END;
  IF NOT BindTexture(2, 16, FBH, FmtBGRA8)   THEN WriteString("line palette failed"); WriteLn; HALT END;
  UploadTexture(0, ADR(gIdx), FBW);                 (* index buffer (static) *)
  UploadTexture(1, ADR(gPal), 1024);
  UploadTexture(2, ADR(gLine), 64);
  RunLoop(Build)
END LutGPU.
