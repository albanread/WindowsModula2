MODULE MandelbrotGPU;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * GPU Mandelbrot zoomer — a client of the generic ShaderView pixel-shader host.
 * The escape-time iteration runs in this module's HLSL PIXEL SHADER (one
 * full-screen triangle); ShaderView drives the Direct3D11 / DXGI COM interfaces
 * (the winapi-gen-generated, @ordinal-checked ones).
 *
 *   build: newm2 build demos/mandelbrot_gpu.mod   then run the .exe
 *   arrows  pan      + / -  zoom      R  reset      Esc  quit
 *)
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Quit;
FROM ShaderView IMPORT Startup, Attach, SetShader, Width, Height, RunLoop;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;
FROM STextIO IMPORT WriteString, WriteLn;

CONST
  WinW = 960; WinH = 640;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  VK_ESCAPE = 1BH; VK_LEFT = 25H; VK_UP = 26H; VK_RIGHT = 27H; VK_DOWN = 28H;

  (* The pixel shader (single-line: M2 string literals cannot span lines). Its
     cbuffer layout matches the CB record below byte-for-byte (32 bytes). *)
  PixelShader = "cbuffer Params : register(b0) { float2 center; float2 zoomv; float time; float aspect; uint maxIter; uint pad; }; struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; }; float3 palette(float t) { float3 a=float3(0.5,0.5,0.5); float3 b=float3(0.5,0.5,0.5); float3 cc=float3(1.0,1.0,1.0); float3 d=float3(0.0,0.33,0.67); return a + b*cos(6.28318*(cc*t + d + time*0.05)); } float4 main(VSOut i) : SV_Target { float2 p = i.uv - 0.5; p.x *= aspect; float span = 3.0 / max(zoomv.x, 1e-6); float2 c = center + p*span; float2 z = float2(0.0,0.0); uint n = 0u; [loop] while (n < maxIter) { float x=z.x*z.x - z.y*z.y + c.x; float y=2.0*z.x*z.y + c.y; z=float2(x,y); if (dot(z,z) > 4.0) break; n++; } if (n >= maxIter) return float4(0.0,0.0,0.0,1.0); float mu = (float)n - log2(max(log2(dot(z,z)),1e-6)) + 4.0; float t = saturate(mu/(float)maxIter); return float4(palette(t), 1.0); }";

TYPE
  CB = RECORD cx, cy, zx, zy, time, aspect: SHORTREAL; maxIter, pad: INTEGER32 END;

VAR
  gWin: Window;
  gCx, gCy, gZoom: SHORTREAL;
  gMaxIter: CARDINAL;
  cb: CB;

(* per-frame: fill the constant buffer from the current view + time *)
PROCEDURE Build (time: SHORTREAL): ADDRESS;
BEGIN
  cb.cx := gCx; cb.cy := gCy; cb.zx := gZoom; cb.zy := VAL(SHORTREAL, 0.0);
  cb.time := time;
  cb.aspect := VAL(SHORTREAL, VAL(REAL, Width()) / VAL(REAL, Height()));
  cb.maxIter := VAL(INTEGER32, gMaxIter); cb.pad := VAL(INTEGER32, 0);
  RETURN ADR(cb)
END Build;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR; step: SHORTREAL;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    step := VAL(SHORTREAL, 0.1) / gZoom;
    IF    wParam = VK_LEFT   THEN gCx := gCx - step
    ELSIF wParam = VK_RIGHT  THEN gCx := gCx + step
    ELSIF wParam = VK_UP     THEN gCy := gCy - step
    ELSIF wParam = VK_DOWN   THEN gCy := gCy + step
    ELSIF wParam = VK_ESCAPE THEN Quit
    END;
    RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF    (ch = '+') OR (ch = '=') THEN gZoom := gZoom * VAL(SHORTREAL, 1.1)
    ELSIF (ch = '-') OR (ch = '_') THEN gZoom := gZoom / VAL(SHORTREAL, 1.1)
    ELSIF (ch = 'r') OR (ch = 'R') THEN
      gCx := VAL(SHORTREAL, -0.5); gCy := VAL(SHORTREAL, 0.0); gZoom := VAL(SHORTREAL, 1.0)
    END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  gCx := VAL(SHORTREAL, -0.5); gCy := VAL(SHORTREAL, 0.0); gZoom := VAL(SHORTREAL, 1.0); gMaxIter := 256;
  ok := Startup();
  gWin := CreateAppWindow("NewM2 GPU Mandelbrot (D3D11)", WinW, WinH, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, cw, ch) THEN WriteString("D3D11 Attach failed"); WriteLn; HALT END;
  IF NOT SetShader(PixelShader, SIZE(cb)) THEN WriteString("shader compile failed"); WriteLn; HALT END;
  RunLoop(Build)
END MandelbrotGPU.
