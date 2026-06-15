MODULE SimdParticles;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * A SIMD particle swirl — hundreds of particles pulled toward a moving attractor,
 * with the physics done four particles at a time in REAL32X4 lane vectors (the
 * first-class SIMD type; see docs/design/simd-laned-vectors.md). Positions and
 * velocities live in ARRAY OF REAL32X4, and each integration step is element-wise
 * vector arithmetic + FMA, so one instruction advances four particles. Drawn with
 * the Canvas2D Direct2D host.
 *
 * The attractor force is G*d / dist^2 — a smooth 1/dist pull that needs no square
 * root (lane SQRT isn't in the SIMD surface yet), which keeps the kernel to the
 * proven ops: + - * /, scalar broadcast, FMA, and lane read/write.
 *
 *   build: newm2 build demos/simd_particles.mod   then run the .exe
 *   drag the mouse  the attractor follows the cursor
 *   Space pause      R  reseed       Esc  quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, PumpMessages, Quit;
FROM Canvas2D IMPORT Startup, Attach, Begin, Flush, Clear, FillCircle;
FROM RandomNumbers IMPORT Randomize, Random;
FROM RealMath IMPORT sin, cos;
FROM ElapsedTime IMPORT Delay;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  WinW = 940; WinH = 640;
  NV = 160;                       (* REAL32X4 groups -> NV*4 = 640 particles *)
  G    = 1400.0;                  (* attractor strength *)
  Soft = 90.0;                    (* softening: keeps dist^2 from hitting 0 *)
  Damp = 0.965;                   (* velocity damping *)

  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  WM_MOUSEMOVE = 512; WM_LBUTTONDOWN = 513; WM_LBUTTONUP = 514;
  MK_LBUTTON = 1;
  VK_ESCAPE = 1BH;

VAR
  gWin:           Window;
  px, py, vx, vy: ARRAY [0..NV-1] OF REAL32X4;
  ax, ay:         SHORTREAL;       (* attractor position *)
  gT:             REAL;            (* orbit phase *)
  gFollow:        BOOLEAN;         (* mouse is dragging the attractor *)
  gRun:           BOOLEAN;

PROCEDURE Reseed;
  VAR i, j: CARDINAL;
BEGIN
  FOR i := 0 TO NV-1 DO
    FOR j := 0 TO 3 DO
      px[i][j] := VAL(SHORTREAL, VAL(REAL, Random(0, WinW)));
      py[i][j] := VAL(SHORTREAL, VAL(REAL, Random(0, WinH)));
      vx[i][j] := VAL(SHORTREAL, 0.0);
      vy[i][j] := VAL(SHORTREAL, 0.0)
    END
  END
END Reseed;

(* Advance every particle one step — four at a time, all element-wise. *)
PROCEDURE Step;
  VAR i: CARDINAL; dx, dy, dist2, invf: REAL32X4;
BEGIN
  FOR i := 0 TO NV-1 DO
    dx    := ax - px[i];                 (* scalar broadcast - vector *)
    dy    := ay - py[i];
    dist2 := dx*dx + dy*dy + Soft;       (* lane-wise squared distance + softening *)
    invf  := G / dist2;                  (* per-lane G / dist^2 *)
    vx[i] := (vx[i] + dx*invf) * Damp;   (* a = G*d/dist^2; v = (v + a)*damp *)
    vy[i] := (vy[i] + dy*invf) * Damp;
    px[i] := px[i] + vx[i];              (* integrate *)
    py[i] := py[i] + vy[i]
  END
END Step;

PROCEDURE SpeedColor (sx, sy: SHORTREAL): CARDINAL;
  VAR s2: REAL;
BEGIN
  s2 := VAL(REAL, sx*sx + sy*sy);
  IF    s2 > 14.0 THEN RETURN 0FFFFE0H        (* fastest: near-white *)
  ELSIF s2 >  5.0 THEN RETURN 0FFC050H        (* hot amber *)
  ELSIF s2 >  1.2 THEN RETURN 050D0FFH        (* cyan *)
  ELSE                 RETURN 02C5090H        (* slow: dim teal-blue *)
  END
END SpeedColor;

PROCEDURE Render;
  VAR i, j: CARDINAL;
BEGIN
  Begin;
  Clear(0000308H);                            (* near-black, faint blue *)
  FillCircle(VAL(REAL, ax), VAL(REAL, ay), 7.0, 0FF5050H);   (* the attractor *)
  FOR i := 0 TO NV-1 DO
    FOR j := 0 TO 3 DO
      FillCircle(VAL(REAL, px[i][j]), VAL(REAL, py[i][j]), 1.7,
                 SpeedColor(vx[i][j], vy[i][j]))
    END
  END;
  Flush
END Render;

PROCEDURE SetAttractor (lParam: CARDINAL);
BEGIN
  ax := VAL(SHORTREAL, VAL(REAL, lParam MOD 65536));
  ay := VAL(SHORTREAL, VAL(REAL, lParam DIV 65536))
END SetAttractor;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_LBUTTONDOWN THEN
    gFollow := TRUE; SetAttractor(lParam); RETURN 0
  ELSIF msg = WM_LBUTTONUP THEN
    gFollow := FALSE; RETURN 0
  ELSIF msg = WM_MOUSEMOVE THEN
    IF (wParam BAND MK_LBUTTON) # 0 THEN gFollow := TRUE; SetAttractor(lParam) END;
    RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF (ch = ' ') THEN gRun := NOT gRun
    ELSIF (ch = 'r') OR (ch = 'R') THEN Reseed END;
    RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF wParam = VK_ESCAPE THEN Quit END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  Randomize(0);
  gT := 0.0; gFollow := FALSE; gRun := TRUE;
  ax := VAL(SHORTREAL, VAL(REAL, WinW) / 2.0);
  ay := VAL(SHORTREAL, VAL(REAL, WinH) / 2.0);
  Reseed;
  ok := Startup();
  gWin := CreateAppWindow("NewM2 SIMD particles (REAL32X4)", WinW + 16, WinH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  IF NOT Attach(gWin, cw, ch) THEN HALT END;
  LOOP
    IF NOT PumpMessages() THEN EXIT END;
    IF gRun THEN
      IF NOT gFollow THEN
        gT := gT + 0.013;                       (* attractor drifts a Lissajous path *)
        ax := VAL(SHORTREAL, VAL(REAL, WinW)/2.0 + VAL(REAL, WinW)/3.0 * cos(gT));
        ay := VAL(SHORTREAL, VAL(REAL, WinH)/2.0 + VAL(REAL, WinH)/3.0 * sin(gT*1.3))
      END;
      Step
    END;
    Render;
    Delay(12)
  END
END SimdParticles.
