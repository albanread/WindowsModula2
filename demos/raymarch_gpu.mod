MODULE RaymarchGPU;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * Raymarched 3-D scene on the GPU — a client of the generic ShaderView pixel-
 * shader host. Each pixel sphere-traces a signed-distance field (a rotating
 * torus) and shades the hit with diffuse + specular lighting. All the 3-D — the
 * camera ray, the march loop, the surface normal, the lighting — lives in this
 * module's HLSL PIXEL SHADER; ShaderView only drives the Direct3D11 / DXGI COM
 * interfaces (the winapi-gen-generated, @ordinal-checked ones).
 *
 *   build: newm2 build demos/raymarch_gpu.mod   then run the .exe
 *   + / -  spin speed      R  reset      Esc  quit
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
  PixelShader = "cbuffer Params : register(b0) { float time; float aspect; uint pad0; uint pad1; }; struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; }; float2 rot(float2 p, float a){ float c=cos(a),s=sin(a); return float2(c*p.x - s*p.y, s*p.x + c*p.y); } float sdTorus(float3 p, float2 t){ float2 q=float2(length(p.xz)-t.x, p.y); return length(q)-t.y; } float mapF(float3 p, float time){ p.yz=rot(p.yz, time*0.7); p.xz=rot(p.xz, time*0.4); return sdTorus(p, float2(1.0,0.4)); } float3 nrm(float3 p, float time){ float2 e=float2(0.001,0.0); return normalize(float3( mapF(p+e.xyy,time)-mapF(p-e.xyy,time), mapF(p+e.yxy,time)-mapF(p-e.yxy,time), mapF(p+e.yyx,time)-mapF(p-e.yyx,time))); } float4 main(VSOut i):SV_Target{ float2 uv=(i.uv-0.5)*float2(aspect,1.0)*2.0; float3 ro=float3(0.0,0.0,-4.0); float3 rd=normalize(float3(uv,1.6)); float t=0.0; bool hit=false; [loop] for(int k=0;k<96;k++){ float3 p=ro+rd*t; float d=mapF(p,time); if(d<0.001){ hit=true; break; } t+=d; if(t>20.0) break; } float3 col=float3(0.02,0.02,0.05); if(hit){ float3 p=ro+rd*t; float3 n=nrm(p,time); float3 ld=normalize(float3(0.6,0.7,-0.5)); float diff=max(dot(n,ld),0.0); float3 base=0.5+0.5*cos(6.28318*(float3(0.0,0.33,0.67)+t*0.12+time*0.05)); col=base*(0.2+diff); float spec=pow(max(dot(reflect(-ld,n),-rd),0.0),32.0); col+=spec*0.6; } col=pow(col, float3(0.4545,0.4545,0.4545)); return float4(col,1.0); }";

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
  gWin := CreateAppWindow("NewM2 GPU Raymarch (D3D11)", WinW, WinH, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, cw, ch) THEN WriteString("D3D11 Attach failed"); WriteLn; HALT END;
  IF NOT SetShader(PixelShader, SIZE(cb)) THEN WriteString("shader compile failed"); WriteLn; HALT END;
  RunLoop(Build)
END RaymarchGPU.
