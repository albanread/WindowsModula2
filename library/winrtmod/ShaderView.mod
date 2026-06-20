IMPLEMENTATION MODULE ShaderView;

(* A generic full-screen pixel-shader host on Direct3D11. The fixed vertex shader
   emits one full-screen triangle from SV_VertexID; the demo's pixel shader does
   all the work. The COM interfaces (ID3D11Device, ID3D11DeviceContext,
   IDXGISwapChain, ID3DBlob, IUnknown) are IMPORTed from the winapi-gen-generated
   Win32 modules and every vtable slot is @ordinal-checked by the compiler.

   S3 (PaneShell): instanced. Each instance owns its own D3D11 device + swapchain
   + render target + shaders + textures + sprite layer — so two ShaderViews each
   drive their own GPU device/window (and GameViewGpu, S4, layers one per game).
   gActive points at the current instance (never NIL); an eager default backs the
   legacy singleton API. The HLSL source strings + compile scratch are read-only/
   reused and stay shared (single UI thread). Device creation lives in Attach
   (needs a real window), so only construction/Free are headless. *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST, SIZE;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM WIN32 IMPORT DWORD;
FROM MemUtils IMPORT ZeroMem, MoveMem;
FROM Guid IMPORT FromString;
IMPORT WinShell;

FROM System_Com IMPORT IUnknown;
FROM Graphics_Direct3D11 IMPORT ID3D11Device, ID3D11DeviceContext,
  D3D11CreateDeviceAndSwapChain;
FROM Graphics_Dxgi IMPORT IDXGISwapChain;
FROM Graphics_Direct3D IMPORT ID3DBlob;
FROM Graphics_Direct3D_Fxc IMPORT D3DCompile;

TYPE
  (* DXGI_SWAP_CHAIN_DESC, flattened (f32 fields as SHORTREAL; see note in the
     mandelbrot demo). Every D3D create-call takes its desc by pointer. *)
  SwapDesc = RECORD
    bufWidth, bufHeight, refreshNum, refreshDen: DWORD;
    format: INTEGER32; scanOrder, scaling: INTEGER32;
    sampleCount, sampleQuality: DWORD;
    bufferUsage, bufferCount: DWORD; outputWindow: ADDRESS;
    windowed: INTEGER32; swapEffect: INTEGER32; flags: DWORD
  END;
  Viewport = RECORD topLeftX, topLeftY, width, height, minDepth, maxDepth: SHORTREAL END;
  BufDesc  = RECORD byteWidth: DWORD; usage: INTEGER32;
                    bindFlags, cpuAccess, miscFlags, structStride: DWORD END;
  (* D3D11_TEXTURE2D_DESC, flattened (44 bytes; all DWORD/INTEGER32 — no floats,
     so no FLOAT->REAL mis-sizing risk). SampleDesc inlined as 2 DWORDs. *)
  TexDesc = RECORD
    width, height, mipLevels, arraySize: DWORD;
    format: INTEGER32;
    sampleCount, sampleQuality: DWORD;
    usage: INTEGER32;
    bindFlags, cpuAccess, miscFlags: DWORD
  END;
  (* D3D11_INPUT_ELEMENT_DESC (32 bytes). *)
  IElem = RECORD
    semantic: ADDRESS; semIndex: DWORD; format: INTEGER32;
    inputSlot, alignedOffset: DWORD; slotClass: INTEGER32; stepRate: DWORD
  END;
  (* D3D11_BLEND_DESC, HAND-FLATTENED (264 bytes). The generated record types
     RenderTarget as ADDRESS, but it is really an inline RenderTarget[8] array of
     D3D11_RENDER_TARGET_BLEND_DESC — so we inline RenderTarget[0]'s 8 fields and
     pad out [1..7] (unused: IndependentBlendEnable=FALSE). BOOLs as INTEGER32. *)
  BlendDesc = RECORD
    alphaToCoverage, independentBlend: INTEGER32;            (* 0, 4 *)
    rt0Enable, rt0Src, rt0Dest, rt0Op,
    rt0SrcA, rt0DestA, rt0OpA: INTEGER32;                    (* 8..32 *)
    rt0WriteMask: DWORD;                                     (* 36 *)
    restPad: ARRAY [0..223] OF BYTE                          (* 40..263: RenderTarget[1..7] *)
  END;
  (* D3D11_MAPPED_SUBRESOURCE (16 bytes). *)
  Mapped = RECORD pData: ADDRESS; rowPitch, depthPitch: DWORD END;

  (* one instance = a whole D3D11 device/swapchain/shader/sprite-layer set *)
  SInstRec = RECORD
    device, context, swap, rtv, vs, ps, cb: ADDRESS;
    vp:      Viewport;
    w, h, cbSize: CARDINAL;
    texN:    CARDINAL;                                (* highest bound SRV slot + 1 *)
    tex, srv: ARRAY [0..7] OF ADDRESS;                (* input textures + their views *)
    spriteVS, spritePS, spriteIL, spriteVB, blend: ADDRESS;
    atlas, atlasSRV, sPal, sPalSRV: ADDRESS;
    spriteSRVs: ARRAY [0..1] OF ADDRESS;              (* [atlas, sprite-palette] *)
    il:      ARRAY [0..2] OF IElem;                   (* POSITION, TEXCOORD0, TEXCOORD1 *)
    spriteVBCap: CARDINAL;                            (* vertex-buffer capacity (verts) *)
    spriteReady: BOOLEAN;
  END;
  SInstPtr = POINTER TO SInstRec;

VAR
  gActive, gDefault: SInstPtr;
  (* shared compile scratch + read-only HLSL sources (single UI thread) *)
  gSemPos, gSemTex: ARRAY [0..15] OF ACHAR;
  gSpriteVsSrc, gSpritePsSrc: ARRAY [0..1023] OF ACHAR;
  vsSrc, psSrc: ARRAY [0..4095] OF ACHAR;
  tgtVS, tgtPS, entMain: ARRAY [0..7] OF ACHAR;

PROCEDURE ALen (VAR s: ARRAY OF ACHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (ORD(s[i]) # 0) DO INC(i) END;
  RETURN i
END ALen;

(* Copy a runtime WIDE string (e.g. a caller's `pixelHlsl` param) into a narrow
   (8-bit ACHAR) buffer, truncating each code unit to its low byte. *)
PROCEDURE SetNarrow (VAR a: ARRAY OF ACHAR; w: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i < HIGH(a)) AND (i <= HIGH(w)) AND (w[i] # 0C) DO
    a[i] := VAL(ACHAR, ORD(w[i])); INC(i)
  END;
  a[i] := VAL(ACHAR, 0)
END SetNarrow;

PROCEDURE Startup (): BOOLEAN;
BEGIN RETURN TRUE END Startup;

PROCEDURE Width  (): CARDINAL; BEGIN RETURN gActive^.w END Width;
PROCEDURE Height (): CARDINAL; BEGIN RETURN gActive^.h END Height;

PROCEDURE Attach (hwnd: ADDRESS; w, h: CARDINAL): BOOLEAN;
  VAR scd: SwapDesc; iid: ARRAY [0..15] OF BYTE; level: INTEGER32;
      hr: INTEGER32; vr: INTEGER;
      sc: IDXGISwapChain; dev: ID3D11Device;
      backbuf, vsBlob, errBlob: ADDRESS; bb: IUnknown; vb: ID3DBlob;
BEGIN
  gActive^.w := w; gActive^.h := h;
  ZeroMem(ADR(scd), SIZE(scd));
  scd.bufWidth := VAL(DWORD, w); scd.bufHeight := VAL(DWORD, h);
  scd.refreshNum := VAL(DWORD, 60); scd.refreshDen := VAL(DWORD, 1);
  scd.format := VAL(INTEGER32, 87);             (* DXGI_FORMAT_B8G8R8A8_UNORM *)
  scd.sampleCount := VAL(DWORD, 1);
  scd.bufferUsage := VAL(DWORD, 32);            (* RENDER_TARGET_OUTPUT *)
  scd.bufferCount := VAL(DWORD, 2);
  scd.outputWindow := hwnd;
  scd.windowed := VAL(INTEGER32, 1);
  scd.swapEffect := VAL(INTEGER32, 0);          (* DISCARD *)
  level := VAL(INTEGER32, 45056);               (* D3D_FEATURE_LEVEL_11_0 *)
  gActive^.device := NIL; gActive^.context := NIL; gActive^.swap := NIL;
  hr := D3D11CreateDeviceAndSwapChain(
          NIL, VAL(INTEGER32, 1), NIL, VAL(DWORD, 32),
          ADR(level), VAL(DWORD, 1), VAL(DWORD, 7),
          ADR(scd), ADR(gActive^.swap), ADR(gActive^.device), NIL, ADR(gActive^.context));
  IF hr < 0 THEN RETURN FALSE END;
  IF NOT FromString("{6f15aaf2-d208-4e89-9ab4-489535d34f9c}", iid) THEN RETURN FALSE END;
  sc := gActive^.swap; backbuf := NIL;
  vr := sc.GetBuffer(VAL(INTEGER32, 0), ADR(iid), ADR(backbuf));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  dev := gActive^.device; gActive^.rtv := NIL;
  vr := dev.CreateRenderTargetView(backbuf, NIL, ADR(gActive^.rtv));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  bb := backbuf; vr := bb.Release();
  (* fixed full-screen-triangle vertex shader *)
  tgtVS := "vs_4_0"A; entMain := "main"A;
  vsBlob := NIL; errBlob := NIL;
  hr := D3DCompile(ADR(vsSrc), VAL(ADRCARD, ALen(vsSrc)), NIL, NIL, NIL,
                   ADR(entMain), ADR(tgtVS), VAL(DWORD, 0), VAL(DWORD, 0),
                   ADR(vsBlob), ADR(errBlob));
  IF hr < 0 THEN RETURN FALSE END;
  vb := vsBlob; gActive^.vs := NIL;
  vr := dev.CreateVertexShader(vb.GetBufferPointer(), vb.GetBufferSize(), NIL, ADR(gActive^.vs));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gActive^.vp.topLeftX := VAL(SHORTREAL, 0.0); gActive^.vp.topLeftY := VAL(SHORTREAL, 0.0);
  gActive^.vp.width := VAL(SHORTREAL, VAL(REAL, w)); gActive^.vp.height := VAL(SHORTREAL, VAL(REAL, h));
  gActive^.vp.minDepth := VAL(SHORTREAL, 0.0); gActive^.vp.maxDepth := VAL(SHORTREAL, 1.0);
  RETURN TRUE
END Attach;

PROCEDURE SetShader (pixelHlsl: ARRAY OF CHAR; cbSize: CARDINAL): BOOLEAN;
  VAR bd: BufDesc; hr: INTEGER32; vr: INTEGER;
      dev: ID3D11Device; psBlob, errBlob: ADDRESS; pb: ID3DBlob;
BEGIN
  IF gActive^.device = NIL THEN RETURN FALSE END;
  SetNarrow(psSrc, pixelHlsl);
  tgtPS := "ps_4_0"A; entMain := "main"A;
  dev := gActive^.device;
  psBlob := NIL; errBlob := NIL;
  hr := D3DCompile(ADR(psSrc), VAL(ADRCARD, ALen(psSrc)), NIL, NIL, NIL,
                   ADR(entMain), ADR(tgtPS), VAL(DWORD, 0), VAL(DWORD, 0),
                   ADR(psBlob), ADR(errBlob));
  IF hr < 0 THEN RETURN FALSE END;
  pb := psBlob; gActive^.ps := NIL;
  vr := dev.CreatePixelShader(pb.GetBufferPointer(), pb.GetBufferSize(), NIL, ADR(gActive^.ps));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  (* constant buffer, ByteWidth rounded up to a 16-byte multiple *)
  gActive^.cbSize := ((cbSize + 15) DIV 16) * 16;
  ZeroMem(ADR(bd), SIZE(bd));
  bd.byteWidth := VAL(DWORD, gActive^.cbSize);
  bd.usage := VAL(INTEGER32, 0);
  bd.bindFlags := VAL(DWORD, 4);                (* D3D11_BIND_CONSTANT_BUFFER *)
  gActive^.cb := NIL;
  vr := dev.CreateBuffer(ADR(bd), NIL, ADR(gActive^.cb));
  RETURN (vr BAND 80000000H) = 0
END SetShader;

PROCEDURE BindTexture (slot, w, h: CARDINAL; format: INTEGER32): BOOLEAN;
  VAR td: TexDesc; dev: ID3D11Device; vr: INTEGER; tex, srv: ADDRESS;
BEGIN
  IF (gActive^.device = NIL) OR (slot > 7) OR (w = 0) OR (h = 0) THEN RETURN FALSE END;
  ZeroMem(ADR(td), SIZE(td));
  td.width := VAL(DWORD, w); td.height := VAL(DWORD, h);
  td.mipLevels := VAL(DWORD, 1); td.arraySize := VAL(DWORD, 1);
  td.format := format;
  td.sampleCount := VAL(DWORD, 1); td.sampleQuality := VAL(DWORD, 0);
  td.usage := VAL(INTEGER32, 0);                     (* D3D11_USAGE_DEFAULT *)
  td.bindFlags := VAL(DWORD, 8);                     (* D3D11_BIND_SHADER_RESOURCE *)
  td.cpuAccess := VAL(DWORD, 0); td.miscFlags := VAL(DWORD, 0);
  dev := gActive^.device; tex := NIL;
  vr := dev.CreateTexture2D(ADR(td), NIL, ADR(tex));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  srv := NIL;
  vr := dev.CreateShaderResourceView(tex, NIL, ADR(srv));   (* NIL desc = whole resource *)
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gActive^.tex[slot] := tex; gActive^.srv[slot] := srv;
  IF slot + 1 > gActive^.texN THEN gActive^.texN := slot + 1 END;
  RETURN TRUE
END BindTexture;

PROCEDURE UploadTexture (slot: CARDINAL; pixels: ADDRESS; rowPitch: CARDINAL);
  VAR ctx: ID3D11DeviceContext;
BEGIN
  IF (gActive^.context = NIL) OR (slot > 7) OR (gActive^.tex[slot] = NIL) THEN RETURN END;
  ctx := gActive^.context;
  ctx.UpdateSubresource(gActive^.tex[slot], VAL(INTEGER32, 0), NIL, pixels,
                        VAL(INTEGER32, VAL(INTEGER, rowPitch)), VAL(INTEGER32, 0))
END UploadTexture;

(* Create the sprite layer: a sprite atlas (R8_UINT, index 0 transparent), a sprite
   palette LUT (B8G8R8A8, row = sprite slot, column = colour index), an alpha-over
   blend state, the sprite VS/PS pair + input layout, and a dynamic vertex buffer
   (maxVerts vertices of 6 floats each). Call after Attach. FALSE on failure. *)
PROCEDURE InitSprites (atlasW, atlasH, palW, palH, maxVerts: CARDINAL): BOOLEAN;
  VAR dev: ID3D11Device; vr: INTEGER; hr: INTEGER32;
      td: TexDesc; bd: BufDesc; bl: BlendDesc;
      vsBlob, errBlob, psBlob: ADDRESS; vb, pb: ID3DBlob;
BEGIN
  IF (gActive^.device = NIL) OR (maxVerts = 0) THEN RETURN FALSE END;
  dev := gActive^.device;
  ZeroMem(ADR(td), SIZE(td));
  td.width := VAL(DWORD, atlasW); td.height := VAL(DWORD, atlasH);
  td.mipLevels := VAL(DWORD, 1); td.arraySize := VAL(DWORD, 1);
  td.format := VAL(INTEGER32, 62);                 (* R8_UINT *)
  td.sampleCount := VAL(DWORD, 1); td.usage := VAL(INTEGER32, 0); td.bindFlags := VAL(DWORD, 8);
  gActive^.atlas := NIL;
  vr := dev.CreateTexture2D(ADR(td), NIL, ADR(gActive^.atlas));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gActive^.atlasSRV := NIL;
  vr := dev.CreateShaderResourceView(gActive^.atlas, NIL, ADR(gActive^.atlasSRV));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  ZeroMem(ADR(td), SIZE(td));
  td.width := VAL(DWORD, palW); td.height := VAL(DWORD, palH);
  td.mipLevels := VAL(DWORD, 1); td.arraySize := VAL(DWORD, 1);
  td.format := VAL(INTEGER32, 87);                 (* B8G8R8A8_UNORM *)
  td.sampleCount := VAL(DWORD, 1); td.usage := VAL(INTEGER32, 0); td.bindFlags := VAL(DWORD, 8);
  gActive^.sPal := NIL;
  vr := dev.CreateTexture2D(ADR(td), NIL, ADR(gActive^.sPal));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gActive^.sPalSRV := NIL;
  vr := dev.CreateShaderResourceView(gActive^.sPal, NIL, ADR(gActive^.sPalSRV));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gActive^.spriteSRVs[0] := gActive^.atlasSRV; gActive^.spriteSRVs[1] := gActive^.sPalSRV;
  (* sprite VS + input layout (from its bytecode) *)
  tgtVS := "vs_4_0"A; tgtPS := "ps_4_0"A; entMain := "main"A;
  vsBlob := NIL; errBlob := NIL;
  hr := D3DCompile(ADR(gSpriteVsSrc), VAL(ADRCARD, ALen(gSpriteVsSrc)), NIL, NIL, NIL,
                   ADR(entMain), ADR(tgtVS), VAL(DWORD, 0), VAL(DWORD, 0), ADR(vsBlob), ADR(errBlob));
  IF hr < 0 THEN RETURN FALSE END;
  vb := vsBlob; gActive^.spriteVS := NIL;
  vr := dev.CreateVertexShader(vb.GetBufferPointer(), vb.GetBufferSize(), NIL, ADR(gActive^.spriteVS));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gSemPos := "POSITION"A; gSemTex := "TEXCOORD"A;
  gActive^.il[0].semantic := ADR(gSemPos); gActive^.il[0].semIndex := VAL(DWORD,0); gActive^.il[0].format := VAL(INTEGER32,16);
  gActive^.il[0].inputSlot := VAL(DWORD,0); gActive^.il[0].alignedOffset := VAL(DWORD,0);  gActive^.il[0].slotClass := VAL(INTEGER32,0); gActive^.il[0].stepRate := VAL(DWORD,0);
  gActive^.il[1].semantic := ADR(gSemTex); gActive^.il[1].semIndex := VAL(DWORD,0); gActive^.il[1].format := VAL(INTEGER32,16);
  gActive^.il[1].inputSlot := VAL(DWORD,0); gActive^.il[1].alignedOffset := VAL(DWORD,8);  gActive^.il[1].slotClass := VAL(INTEGER32,0); gActive^.il[1].stepRate := VAL(DWORD,0);
  gActive^.il[2].semantic := ADR(gSemTex); gActive^.il[2].semIndex := VAL(DWORD,1); gActive^.il[2].format := VAL(INTEGER32,16);
  gActive^.il[2].inputSlot := VAL(DWORD,0); gActive^.il[2].alignedOffset := VAL(DWORD,16); gActive^.il[2].slotClass := VAL(INTEGER32,0); gActive^.il[2].stepRate := VAL(DWORD,0);
  gActive^.spriteIL := NIL;
  vr := dev.CreateInputLayout(ADR(gActive^.il), VAL(DWORD,3), vb.GetBufferPointer(), vb.GetBufferSize(), ADR(gActive^.spriteIL));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  (* sprite PS *)
  psBlob := NIL; errBlob := NIL;
  hr := D3DCompile(ADR(gSpritePsSrc), VAL(ADRCARD, ALen(gSpritePsSrc)), NIL, NIL, NIL,
                   ADR(entMain), ADR(tgtPS), VAL(DWORD, 0), VAL(DWORD, 0), ADR(psBlob), ADR(errBlob));
  IF hr < 0 THEN RETURN FALSE END;
  pb := psBlob; gActive^.spritePS := NIL;
  vr := dev.CreatePixelShader(pb.GetBufferPointer(), pb.GetBufferSize(), NIL, ADR(gActive^.spritePS));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  (* alpha-over blend state: SRC_ALPHA / INV_SRC_ALPHA *)
  ZeroMem(ADR(bl), SIZE(bl));
  bl.rt0Enable := VAL(INTEGER32, 1);
  bl.rt0Src    := VAL(INTEGER32, 5); bl.rt0Dest  := VAL(INTEGER32, 6); bl.rt0Op  := VAL(INTEGER32, 1);
  bl.rt0SrcA   := VAL(INTEGER32, 2); bl.rt0DestA := VAL(INTEGER32, 6); bl.rt0OpA := VAL(INTEGER32, 1);
  bl.rt0WriteMask := VAL(DWORD, 15);
  gActive^.blend := NIL;
  vr := dev.CreateBlendState(ADR(bl), ADR(gActive^.blend));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  (* dynamic vertex buffer: maxVerts * 24 bytes (pos.xy, uv.xy, meta.xy) *)
  ZeroMem(ADR(bd), SIZE(bd));
  bd.byteWidth := VAL(DWORD, maxVerts * 24);
  bd.usage := VAL(INTEGER32, 2);                   (* DYNAMIC *)
  bd.bindFlags := VAL(DWORD, 1);                   (* VERTEX_BUFFER *)
  bd.cpuAccess := VAL(DWORD, 65536);               (* CPU_ACCESS_WRITE = 0x10000 *)
  gActive^.spriteVB := NIL;
  vr := dev.CreateBuffer(ADR(bd), NIL, ADR(gActive^.spriteVB));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gActive^.spriteVBCap := maxVerts; gActive^.spriteReady := TRUE;
  RETURN TRUE
END InitSprites;

PROCEDURE UploadAtlas (pixels: ADDRESS; rowPitch: CARDINAL);
  VAR ctx: ID3D11DeviceContext;
BEGIN
  IF (gActive^.context = NIL) OR (gActive^.atlas = NIL) THEN RETURN END;
  ctx := gActive^.context;
  ctx.UpdateSubresource(gActive^.atlas, VAL(INTEGER32,0), NIL, pixels, VAL(INTEGER32, VAL(INTEGER,rowPitch)), VAL(INTEGER32,0))
END UploadAtlas;

PROCEDURE UploadSpritePalette (pixels: ADDRESS; rowPitch: CARDINAL);
  VAR ctx: ID3D11DeviceContext;
BEGIN
  IF (gActive^.context = NIL) OR (gActive^.sPal = NIL) THEN RETURN END;
  ctx := gActive^.context;
  ctx.UpdateSubresource(gActive^.sPal, VAL(INTEGER32,0), NIL, pixels, VAL(INTEGER32, VAL(INTEGER,rowPitch)), VAL(INTEGER32,0))
END UploadSpritePalette;

(* Background pass: clear + the full-screen index->RGBA LUT draw. No Present. *)
PROCEDURE BeginFrame (constants: ADDRESS);
  VAR ctx: ID3D11DeviceContext; clr: ARRAY [0..3] OF SHORTREAL;
BEGIN
  IF (gActive^.context = NIL) OR (gActive^.rtv = NIL) OR (gActive^.ps = NIL) THEN RETURN END;
  ctx := gActive^.context;
  ctx.UpdateSubresource(gActive^.cb, VAL(INTEGER32, 0), NIL, constants, VAL(INTEGER32, 0), VAL(INTEGER32, 0));
  ctx.OMSetRenderTargets(VAL(INTEGER32, 1), ADR(gActive^.rtv), NIL);
  clr[0] := VAL(SHORTREAL, 0.0); clr[1] := VAL(SHORTREAL, 0.0);
  clr[2] := VAL(SHORTREAL, 0.0); clr[3] := VAL(SHORTREAL, 1.0);
  ctx.ClearRenderTargetView(gActive^.rtv, ADR(clr));
  ctx.IASetInputLayout(NIL);                         (* background VS = SV_VertexID *)
  ctx.IASetPrimitiveTopology(VAL(INTEGER32, 4));     (* TRIANGLELIST *)
  ctx.VSSetShader(gActive^.vs, NIL, VAL(INTEGER32, 0));
  ctx.PSSetShader(gActive^.ps, NIL, VAL(INTEGER32, 0));
  ctx.PSSetConstantBuffers(VAL(INTEGER32, 0), VAL(INTEGER32, 1), ADR(gActive^.cb));
  IF gActive^.texN > 0 THEN
    ctx.PSSetShaderResources(VAL(INTEGER32, 0), VAL(INTEGER32, VAL(INTEGER, gActive^.texN)), ADR(gActive^.srv))
  END;
  ctx.RSSetViewports(VAL(INTEGER32, 1), ADR(gActive^.vp));
  ctx.Draw(VAL(INTEGER32, 3), VAL(INTEGER32, 0))
END BeginFrame;

(* Sprite pass: upload `vertCount` vertices (6 floats each: pos.xy NDC, atlas px
   uv.xy, meta.xy = palette-slot, alpha) and draw them alpha-over the background. *)
PROCEDURE DrawSprites (verts: ADDRESS; vertCount: CARDINAL);
  VAR ctx: ID3D11DeviceContext; m: Mapped; vr: INTEGER; stride, offset: DWORD;
BEGIN
  IF (NOT gActive^.spriteReady) OR (vertCount = 0) OR (vertCount > gActive^.spriteVBCap) THEN RETURN END;
  ctx := gActive^.context;
  vr := ctx.Map(gActive^.spriteVB, VAL(DWORD, 0), VAL(INTEGER32, 4), VAL(DWORD, 0), ADR(m));  (* WRITE_DISCARD *)
  IF (vr BAND 80000000H) # 0 THEN RETURN END;
  MoveMem(m.pData, verts, vertCount * 24);
  ctx.Unmap(gActive^.spriteVB, VAL(DWORD, 0));
  stride := VAL(DWORD, 24); offset := VAL(DWORD, 0);
  ctx.IASetInputLayout(gActive^.spriteIL);
  ctx.IASetVertexBuffers(VAL(DWORD, 0), VAL(DWORD, 1), ADR(gActive^.spriteVB), ADR(stride), ADR(offset));
  ctx.IASetPrimitiveTopology(VAL(INTEGER32, 4));
  ctx.VSSetShader(gActive^.spriteVS, NIL, VAL(INTEGER32, 0));
  ctx.PSSetShader(gActive^.spritePS, NIL, VAL(INTEGER32, 0));
  ctx.PSSetShaderResources(VAL(INTEGER32, 0), VAL(INTEGER32, 2), ADR(gActive^.spriteSRVs));
  ctx.OMSetBlendState(gActive^.blend, NIL, VAL(DWORD, 0FFFFFFFFH));
  ctx.RSSetViewports(VAL(INTEGER32, 1), ADR(gActive^.vp));
  ctx.Draw(VAL(INTEGER32, VAL(INTEGER, vertCount)), VAL(INTEGER32, 0));
  ctx.OMSetBlendState(NIL, NIL, VAL(DWORD, 0FFFFFFFFH))      (* back to opaque *)
END DrawSprites;

PROCEDURE EndFrame;
  VAR sc: IDXGISwapChain; vr: INTEGER;
BEGIN
  IF gActive^.swap = NIL THEN RETURN END;
  sc := gActive^.swap; vr := sc.Present(VAL(INTEGER32, 1), VAL(INTEGER32, 0))
END EndFrame;

PROCEDURE Frame (constants: ADDRESS);
BEGIN BeginFrame(constants); EndFrame END Frame;

PROCEDURE RunLoop (build: BuildProc);
  VAR t: SHORTREAL;
BEGIN
  t := VAL(SHORTREAL, 0.0);
  LOOP
    IF NOT WinShell.PumpMessages() THEN EXIT END;
    Frame(build(t));
    t := t + VAL(SHORTREAL, 0.016)
  END
END RunLoop;

PROCEDURE Resize (w, h: CARDINAL);
BEGIN END Resize;

(* Release all D3D resources held by instance p^. Safe to call repeatedly. *)
PROCEDURE ReleaseInst (p: SInstPtr);
  VAR o: IUnknown; d: INTEGER; i: CARDINAL;
BEGIN
  FOR i := 0 TO 7 DO
    IF p^.srv[i] # NIL THEN o := p^.srv[i]; d := o.Release(); p^.srv[i] := NIL END;
    IF p^.tex[i] # NIL THEN o := p^.tex[i]; d := o.Release(); p^.tex[i] := NIL END
  END;
  p^.texN := 0;
  IF p^.spriteVB # NIL THEN o := p^.spriteVB; d := o.Release(); p^.spriteVB := NIL END;
  IF p^.blend # NIL THEN o := p^.blend; d := o.Release(); p^.blend := NIL END;
  IF p^.spriteIL # NIL THEN o := p^.spriteIL; d := o.Release(); p^.spriteIL := NIL END;
  IF p^.spritePS # NIL THEN o := p^.spritePS; d := o.Release(); p^.spritePS := NIL END;
  IF p^.spriteVS # NIL THEN o := p^.spriteVS; d := o.Release(); p^.spriteVS := NIL END;
  IF p^.atlasSRV # NIL THEN o := p^.atlasSRV; d := o.Release(); p^.atlasSRV := NIL END;
  IF p^.atlas # NIL THEN o := p^.atlas; d := o.Release(); p^.atlas := NIL END;
  IF p^.sPalSRV # NIL THEN o := p^.sPalSRV; d := o.Release(); p^.sPalSRV := NIL END;
  IF p^.sPal # NIL THEN o := p^.sPal; d := o.Release(); p^.sPal := NIL END;
  p^.spriteReady := FALSE;
  IF p^.cb # NIL THEN o := p^.cb; d := o.Release(); p^.cb := NIL END;
  IF p^.ps # NIL THEN o := p^.ps; d := o.Release(); p^.ps := NIL END;
  IF p^.vs # NIL THEN o := p^.vs; d := o.Release(); p^.vs := NIL END;
  IF p^.rtv # NIL THEN o := p^.rtv; d := o.Release(); p^.rtv := NIL END;
  IF p^.context # NIL THEN o := p^.context; d := o.Release(); p^.context := NIL END;
  IF p^.swap # NIL THEN o := p^.swap; d := o.Release(); p^.swap := NIL END;
  IF p^.device # NIL THEN o := p^.device; d := o.Release(); p^.device := NIL END
END ReleaseInst;

PROCEDURE Shutdown;
BEGIN ReleaseInst(gActive) END Shutdown;

(* ---- instancing (S3) --------------------------------------------------- *)
PROCEDURE NewSInst (): SInstPtr;
  VAR a: ADDRESS; p: SInstPtr; i: CARDINAL;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(SInstRec)); p := CAST(SInstPtr, a);
  p^.device := NIL; p^.context := NIL; p^.swap := NIL; p^.rtv := NIL;
  p^.vs := NIL; p^.ps := NIL; p^.cb := NIL; p^.cbSize := 16;
  p^.w := 0; p^.h := 0; p^.texN := 0;
  FOR i := 0 TO 7 DO p^.tex[i] := NIL; p^.srv[i] := NIL END;
  p^.spriteVS := NIL; p^.spritePS := NIL; p^.spriteIL := NIL; p^.spriteVB := NIL; p^.blend := NIL;
  p^.atlas := NIL; p^.atlasSRV := NIL; p^.sPal := NIL; p^.sPalSRV := NIL;
  p^.spriteVBCap := 0; p^.spriteReady := FALSE;
  RETURN p
END NewSInst;

PROCEDURE Create (): Instance;
BEGIN
  RETURN CAST(Instance, NewSInst())
END Create;

PROCEDURE Use (i: Instance);
BEGIN
  IF i = NIL THEN gActive := gDefault ELSE gActive := CAST(SInstPtr, i) END
END Use;

PROCEDURE Free (VAR i: Instance);
  VAR p: SInstPtr;
BEGIN
  IF i # NIL THEN
    p := CAST(SInstPtr, i);
    IF p = gActive THEN gActive := gDefault END;
    IF p # gDefault THEN ReleaseInst(p); DEALLOCATE(i, SIZE(SInstRec)) END;
    i := NIL
  END
END Free;

VAR i: CARDINAL;
BEGIN
  vsSrc := "struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; }; VSOut main(uint id : SV_VertexID) { VSOut o; float2 uv = float2((id << 1) & 2, id & 2); o.uv = uv; o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0); return o; }"A;
  (* sprite VS: vertices already carry NDC pos + atlas-pixel uv + (palette-slot, alpha) *)
  gSpriteVsSrc := "struct VSIn { float2 pos:POSITION; float2 uv:TEXCOORD0; float2 meta:TEXCOORD1; }; struct VSOut { float4 pos:SV_Position; float2 uv:TEXCOORD0; float2 meta:TEXCOORD1; }; VSOut main(VSIn i){ VSOut o; o.pos=float4(i.pos,0,1); o.uv=i.uv; o.meta=i.meta; return o; }"A;
  (* sprite PS: atlas index -> discard 0 -> per-sprite palette[slot][index] -> *alpha *)
  gSpritePsSrc := "Texture2D<uint> gAtlas:register(t0); Texture2D<float4> gSPal:register(t1); struct VSOut { float4 pos:SV_Position; float2 uv:TEXCOORD0; float2 meta:TEXCOORD1; }; float4 main(VSOut i):SV_Target { int2 ap=int2(i.uv); uint idx=gAtlas.Load(int3(ap,0)); if(idx==0u) discard; int slot=int(i.meta.x+0.5); float4 c=gSPal.Load(int3(int(idx),slot,0)); return float4(c.rgb, i.meta.y); }"A;
  i := 0;                              (* (silence unused; module init runs once) *)
  gDefault := NewSInst();
  gActive  := gDefault
END ShaderView.
