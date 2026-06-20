MODULE T90262RasterInstance;
(*
 * Group 90 — PaneShell S2: the RGBA software surface (RasterView) is
 * instanceable. Two independent framebuffers of different sizes hold DISTINCT
 * pixel content at the same time, read back per-instance with PixelAt — fully
 * headless (CPU buffer, no window, no Present). Each instance's ~4 MiB buffer is
 * heap-allocated (the §0.4 mandate: off module globals), so the module still
 * loads under JIT even with multiple instances.
 *
 * EXPECTED:
 * a-dot: 65280
 * b-bg: 255
 * a-bg: 16711680
 * a-width: 64
 *)
FROM RasterView IMPORT Instance, Create, Use, Free, PixelAt, Clear, Pixel, Width;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR a, b: Instance;
BEGIN
  a := Create(64, 48);
  b := Create(32, 24);

  Use(a); Clear(0FF0000H); Pixel(10, 10, 000FF00H);   (* a: red bg, green dot at (10,10) *)
  Use(b); Clear(00000FFH);                             (* b: blue bg *)

  WriteString("a-dot: ");   WriteCard(PixelAt(a, 10, 10), 1); WriteLn;   (* 0x00FF00 = 65280 *)
  WriteString("b-bg: ");    WriteCard(PixelAt(b, 10, 10), 1); WriteLn;   (* 0x0000FF = 255 *)
  WriteString("a-bg: ");    WriteCard(PixelAt(a, 0, 0), 1);   WriteLn;   (* 0xFF0000 = 16711680 *)
  Use(a); WriteString("a-width: "); WriteCard(Width(), 1); WriteLn;      (* 64 *)

  Free(a); Free(b)
END T90262RasterInstance.
