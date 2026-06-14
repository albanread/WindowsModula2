MODULE JuliaGPU;
(*
 * Animated Julia set on the GPU — a client of the generic ShaderView pixel-shader
 * host. Each pixel iterates z = z^2 + c starting from its own position, with c a
 * single constant that sweeps a circle every few seconds, so the whole fractal
 * morphs continuously. The Direct3D11 / DXGI COM interfaces are the winapi-gen-
 * generated, @ordinal-checked ones.
 *
 *   build: newm2 build demos/julia_gpu.mod   then run the .exe
 *   + / -  zoom      R  reset      Esc  quit
 *)
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Quit;
FROM ShaderView IMPORT Startup, Attach, SetShader, Width, Height, RunLoop;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;
FROM RealMath IMPORT sin, cos;
FROM STextIO IMPORT WriteString, WriteLn;

CONST
  WinW = 960; WinH = 640;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  VK_ESCAPE = 1BH;

  (* Pixel shader (single-line). cbuffer matches the CB record (32 bytes). *)
  PixelShader = "cbuffer Params : register(b0) { float2 c; float zoom; float aspect; uint maxIter; uint pad0; uint pad1; uint pad2; }; struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; }; float3 palette(float t) { float3 a=float3(0.5,0.5,0.5); float3 b=float3(0.5,0.5,0.5); float3 cc=float3(1.0,1.0,1.0); float3 d=float3(0.0,0.10,0.20); return a + b*cos(6.28318*(cc*t + d)); } float4 main(VSOut i) : SV_Target { float2 p = i.uv - 0.5; p.x *= aspect; float span = 3.0 / max(zoom, 1e-6); float2 z = p*span; uint n = 0u; [loop] while (n < maxIter) { float x=z.x*z.x - z.y*z.y + c.x; float y=2.0*z.x*z.y + c.y; z=float2(x,y); if (dot(z,z) > 4.0) break; n++; } if (n >= maxIter) return float4(0.0,0.0,0.0,1.0); float mu = (float)n - log2(max(log2(dot(z,z)),1e-6)) + 4.0; float t = saturate(mu/(float)maxIter); return float4(palette(t), 1.0); }";

TYPE
  CB = RECORD cx, cy, zoom, aspect: SHORTREAL; maxIter, pad0, pad1, pad2: INTEGER32 END;

VAR
  gWin: Window;
  gZoom: SHORTREAL;
  gMaxIter: CARDINAL;
  cb: CB;

PROCEDURE Build (time: SHORTREAL): ADDRESS;
  VAR angle: REAL;
BEGIN
  angle := VAL(REAL, time) * 0.35;            (* sweep speed *)
  cb.cx := VAL(SHORTREAL, 0.7885 * cos(angle));   (* c on a radius-0.7885 circle *)
  cb.cy := VAL(SHORTREAL, 0.7885 * sin(angle));
  cb.zoom := gZoom;
  cb.aspect := VAL(SHORTREAL, VAL(REAL, Width()) / VAL(REAL, Height()));
  cb.maxIter := VAL(INTEGER32, gMaxIter);
  cb.pad0 := 0; cb.pad1 := 0; cb.pad2 := 0;
  RETURN ADR(cb)
END Build;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF wParam = VK_ESCAPE THEN Quit END;
    RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF    (ch = '+') OR (ch = '=') THEN gZoom := gZoom * VAL(SHORTREAL, 1.1)
    ELSIF (ch = '-') OR (ch = '_') THEN gZoom := gZoom / VAL(SHORTREAL, 1.1)
    ELSIF (ch = 'r') OR (ch = 'R') THEN gZoom := VAL(SHORTREAL, 1.0)
    END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  gZoom := VAL(SHORTREAL, 1.0); gMaxIter := 256;
  ok := Startup();
  gWin := CreateAppWindow("NewM2 GPU Julia animation (D3D11)", WinW, WinH, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, cw, ch) THEN WriteString("D3D11 Attach failed"); WriteLn; HALT END;
  IF NOT SetShader(PixelShader, SIZE(cb)) THEN WriteString("shader compile failed"); WriteLn; HALT END;
  RunLoop(Build)
END JuliaGPU.
