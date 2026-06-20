MODULE T90265SurfaceBackend;
(*
 * Group 90 — PaneShell S5 (P2 part 1/2): the Surface.Backend ABSTRACT CLASS is
 * the one polymorphic handle (CLASS-as-vtable) the substrate drives. Each
 * concrete adapter wraps an instanced renderer; constructing one of each and
 * holding it as the SAME Surface.Backend variable, a virtual KindOf() dispatches
 * to the right concrete surface. Construction + KindOf + Close are headless; the
 * real D2D/D3D Attach/Paint need a window (the S7 leaf AOT demo). Kind ordinals:
 * TextGrid=0, Raster=1, Canvas=2, Indexed=3, Shader=4.
 *
 * EXPECTED:
 * textgrid: 0
 * raster: 1
 * canvas: 2
 * indexed: 3
 * indexedgpu: 3
 * shader: 4
 * poly-tg: 0
 * poly-cv: 2
 *)
FROM Surface IMPORT Backend, NewTextGrid, NewRaster, NewCanvas, NewIndexed,
  NewIndexedGpu, NewShader;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR tg, rv, cv, iv, gp, sv, b: Backend;
BEGIN
  tg := NewTextGrid(80, 25, "Consolas", 14.0);
  rv := NewRaster(64, 48);
  cv := NewCanvas();
  iv := NewIndexed(64, 40, 2);
  gp := NewIndexedGpu(64, 40, 2);
  sv := NewShader(320, 200);

  WriteString("textgrid: ");   WriteCard(ORD(tg.KindOf()), 1); WriteLn;   (* 0 *)
  WriteString("raster: ");     WriteCard(ORD(rv.KindOf()), 1); WriteLn;   (* 1 *)
  WriteString("canvas: ");     WriteCard(ORD(cv.KindOf()), 1); WriteLn;   (* 2 *)
  WriteString("indexed: ");    WriteCard(ORD(iv.KindOf()), 1); WriteLn;   (* 3 *)
  WriteString("indexedgpu: "); WriteCard(ORD(gp.KindOf()), 1); WriteLn;   (* 3 *)
  WriteString("shader: ");     WriteCard(ORD(sv.KindOf()), 1); WriteLn;   (* 4 *)

  (* one polymorphic handle drives any custom surface through the vtable *)
  b := tg; WriteString("poly-tg: "); WriteCard(ORD(b.KindOf()), 1); WriteLn;   (* 0 *)
  b := cv; WriteString("poly-cv: "); WriteCard(ORD(b.KindOf()), 1); WriteLn;   (* 2 *)

  tg.Close(); rv.Close(); cv.Close(); iv.Close(); gp.Close(); sv.Close()
END T90265SurfaceBackend.
