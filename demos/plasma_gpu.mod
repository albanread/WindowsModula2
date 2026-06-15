MODULE PlasmaGPU;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * Animated plasma on the GPU — a client of the generic ShaderView pixel-shader
 * host. A few summed sine waves over screen space, swept by time, give the
 * classic morphing-colour plasma. No CPU per-pixel work: the field and palette
 * live entirely in this module's HLSL pixel shader. ShaderView drives the
 * Direct3D11 / DXGI COM interfaces (the winapi-gen-generated, @ordinal-checked
 * ones).
 *
 *   build: newm2 build demos/plasma_gpu.mod   then run the .exe
 *   + / -  speed      R  reset speed      Esc  quit
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
  VK_ESCAPE = 1BH;

  (* Pixel shader (single-line). cbuffer matches the CB record (16 bytes). *)
  PixelShader = "cbuffer Params : register(b0) { float time; float aspect; uint pad0; uint pad1; }; struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; }; float4 main(VSOut i) : SV_Target { float2 uv = i.uv; uv.x *= aspect; float t = time; float v = sin(uv.x*9.0 + t) + sin(uv.y*9.0 + t*1.3) + sin((uv.x+uv.y)*9.0 + t*0.7); float2 c = uv - float2(0.5*aspect, 0.5); v += sin(length(c)*18.0 - t*2.0); v *= 0.25; float3 col = 0.5 + 0.5*cos(6.28318*(float3(0.00,0.33,0.67) + v + t*0.05)); return float4(col, 1.0); }";

TYPE
  CB = RECORD time, aspect: SHORTREAL; pad0, pad1: INTEGER32 END;

VAR
  gWin: Window;
  gSpeed: SHORTREAL;
  gClock: SHORTREAL;
  gLast:  SHORTREAL;
  cb: CB;

PROCEDURE Build (time: SHORTREAL): ADDRESS;
BEGIN
  (* advance an internal clock scaled by the user's speed, so +/- changes the
     animation rate without jumping the phase. *)
  gClock := gClock + (time - gLast) * gSpeed;
  gLast := time;
  cb.time := gClock;
  cb.aspect := VAL(SHORTREAL, VAL(REAL, Width()) / VAL(REAL, Height()));
  cb.pad0 := 0; cb.pad1 := 0;
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
    IF    (ch = '+') OR (ch = '=') THEN gSpeed := gSpeed * VAL(SHORTREAL, 1.25)
    ELSIF (ch = '-') OR (ch = '_') THEN gSpeed := gSpeed / VAL(SHORTREAL, 1.25)
    ELSIF (ch = 'r') OR (ch = 'R') THEN gSpeed := VAL(SHORTREAL, 1.0)
    END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  gSpeed := VAL(SHORTREAL, 1.0); gClock := VAL(SHORTREAL, 0.0); gLast := VAL(SHORTREAL, 0.0);
  ok := Startup();
  gWin := CreateAppWindow("NewM2 GPU Plasma (D3D11)", WinW, WinH, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, cw, ch) THEN WriteString("D3D11 Attach failed"); WriteLn; HALT END;
  IF NOT SetShader(PixelShader, SIZE(cb)) THEN WriteString("shader compile failed"); WriteLn; HALT END;
  RunLoop(Build)
END PlasmaGPU.
