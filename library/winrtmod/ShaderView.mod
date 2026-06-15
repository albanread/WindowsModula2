IMPLEMENTATION MODULE ShaderView;

(* A generic full-screen pixel-shader host on Direct3D11. The fixed vertex shader
   emits one full-screen triangle from SV_VertexID; the demo's pixel shader does
   all the work. The COM interfaces (ID3D11Device, ID3D11DeviceContext,
   IDXGISwapChain, ID3DBlob, IUnknown) are IMPORTed from the winapi-gen-generated
   Win32 modules and every vtable slot is @ordinal-checked by the compiler. *)

FROM SYSTEM IMPORT ADDRESS, ADR;
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

VAR
  gDevice, gContext, gSwap, gRTV, gVS, gPS, gCB: ADDRESS;
  gVP:   Viewport;
  gW, gH, gCbSize: CARDINAL;
  gTexN: CARDINAL;                                  (* highest bound SRV slot + 1 *)
  gTex, gSRV: ARRAY [0..7] OF ADDRESS;              (* input textures + their views *)
  (* --- sprite layer (a 2nd alpha-blended quad pass over the background) --- *)
  gSpriteVS, gSpritePS, gSpriteIL, gSpriteVB, gBlend: ADDRESS;
  gAtlas, gAtlasSRV, gSPal, gSPalSRV: ADDRESS;
  gSpriteSRVs: ARRAY [0..1] OF ADDRESS;             (* [atlas, sprite-palette] *)
  gIL: ARRAY [0..2] OF IElem;                       (* POSITION, TEXCOORD0, TEXCOORD1 *)
  gSpriteVBCap: CARDINAL;                           (* vertex-buffer capacity (verts) *)
  gSpriteReady: BOOLEAN;
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
   (8-bit ACHAR) buffer, truncating each code unit to its low byte. Narrow
   *literals* now assign directly (`buf := "..."A`); this is for wide→narrow
   conversion of a runtime array, which has no literal shortcut. *)
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

PROCEDURE Width  (): CARDINAL; BEGIN RETURN gW END Width;
PROCEDURE Height (): CARDINAL; BEGIN RETURN gH END Height;

PROCEDURE Attach (hwnd: ADDRESS; w, h: CARDINAL): BOOLEAN;
  VAR scd: SwapDesc; iid: ARRAY [0..15] OF BYTE; level: INTEGER32;
      hr: INTEGER32; vr: INTEGER;
      sc: IDXGISwapChain; dev: ID3D11Device;
      backbuf, vsBlob, errBlob: ADDRESS; bb: IUnknown; vb: ID3DBlob;
BEGIN
  gW := w; gH := h;
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
  gDevice := NIL; gContext := NIL; gSwap := NIL;
  hr := D3D11CreateDeviceAndSwapChain(
          NIL, VAL(INTEGER32, 1), NIL, VAL(DWORD, 32),
          ADR(level), VAL(DWORD, 1), VAL(DWORD, 7),
          ADR(scd), ADR(gSwap), ADR(gDevice), NIL, ADR(gContext));
  IF hr < 0 THEN RETURN FALSE END;
  IF NOT FromString("{6f15aaf2-d208-4e89-9ab4-489535d34f9c}", iid) THEN RETURN FALSE END;
  sc := gSwap; backbuf := NIL;
  vr := sc.GetBuffer(VAL(INTEGER32, 0), ADR(iid), ADR(backbuf));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  dev := gDevice; gRTV := NIL;
  vr := dev.CreateRenderTargetView(backbuf, NIL, ADR(gRTV));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  bb := backbuf; vr := bb.Release();
  (* fixed full-screen-triangle vertex shader *)
  tgtVS := "vs_4_0"A; entMain := "main"A;
  vsBlob := NIL; errBlob := NIL;
  hr := D3DCompile(ADR(vsSrc), VAL(ADRCARD, ALen(vsSrc)), NIL, NIL, NIL,
                   ADR(entMain), ADR(tgtVS), VAL(DWORD, 0), VAL(DWORD, 0),
                   ADR(vsBlob), ADR(errBlob));
  IF hr < 0 THEN RETURN FALSE END;
  vb := vsBlob; gVS := NIL;
  vr := dev.CreateVertexShader(vb.GetBufferPointer(), vb.GetBufferSize(), NIL, ADR(gVS));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gVP.topLeftX := VAL(SHORTREAL, 0.0); gVP.topLeftY := VAL(SHORTREAL, 0.0);
  gVP.width := VAL(SHORTREAL, VAL(REAL, w)); gVP.height := VAL(SHORTREAL, VAL(REAL, h));
  gVP.minDepth := VAL(SHORTREAL, 0.0); gVP.maxDepth := VAL(SHORTREAL, 1.0);
  RETURN TRUE
END Attach;

PROCEDURE SetShader (pixelHlsl: ARRAY OF CHAR; cbSize: CARDINAL): BOOLEAN;
  VAR bd: BufDesc; hr: INTEGER32; vr: INTEGER;
      dev: ID3D11Device; psBlob, errBlob: ADDRESS; pb: ID3DBlob;
BEGIN
  IF gDevice = NIL THEN RETURN FALSE END;
  SetNarrow(psSrc, pixelHlsl);
  tgtPS := "ps_4_0"A; entMain := "main"A;
  dev := gDevice;
  psBlob := NIL; errBlob := NIL;
  hr := D3DCompile(ADR(psSrc), VAL(ADRCARD, ALen(psSrc)), NIL, NIL, NIL,
                   ADR(entMain), ADR(tgtPS), VAL(DWORD, 0), VAL(DWORD, 0),
                   ADR(psBlob), ADR(errBlob));
  IF hr < 0 THEN RETURN FALSE END;
  pb := psBlob; gPS := NIL;
  vr := dev.CreatePixelShader(pb.GetBufferPointer(), pb.GetBufferSize(), NIL, ADR(gPS));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  (* constant buffer, ByteWidth rounded up to a 16-byte multiple *)
  gCbSize := ((cbSize + 15) DIV 16) * 16;
  ZeroMem(ADR(bd), SIZE(bd));
  bd.byteWidth := VAL(DWORD, gCbSize);
  bd.usage := VAL(INTEGER32, 0);
  bd.bindFlags := VAL(DWORD, 4);                (* D3D11_BIND_CONSTANT_BUFFER *)
  gCB := NIL;
  vr := dev.CreateBuffer(ADR(bd), NIL, ADR(gCB));
  RETURN (vr BAND 80000000H) = 0
END SetShader;

PROCEDURE BindTexture (slot, w, h: CARDINAL; format: INTEGER32): BOOLEAN;
  VAR td: TexDesc; dev: ID3D11Device; vr: INTEGER; tex, srv: ADDRESS;
BEGIN
  IF (gDevice = NIL) OR (slot > 7) OR (w = 0) OR (h = 0) THEN RETURN FALSE END;
  ZeroMem(ADR(td), SIZE(td));
  td.width := VAL(DWORD, w); td.height := VAL(DWORD, h);
  td.mipLevels := VAL(DWORD, 1); td.arraySize := VAL(DWORD, 1);
  td.format := format;
  td.sampleCount := VAL(DWORD, 1); td.sampleQuality := VAL(DWORD, 0);
  td.usage := VAL(INTEGER32, 0);                     (* D3D11_USAGE_DEFAULT *)
  td.bindFlags := VAL(DWORD, 8);                     (* D3D11_BIND_SHADER_RESOURCE *)
  td.cpuAccess := VAL(DWORD, 0); td.miscFlags := VAL(DWORD, 0);
  dev := gDevice; tex := NIL;
  vr := dev.CreateTexture2D(ADR(td), NIL, ADR(tex));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  srv := NIL;
  vr := dev.CreateShaderResourceView(tex, NIL, ADR(srv));   (* NIL desc = whole resource *)
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gTex[slot] := tex; gSRV[slot] := srv;
  IF slot + 1 > gTexN THEN gTexN := slot + 1 END;
  RETURN TRUE
END BindTexture;

PROCEDURE UploadTexture (slot: CARDINAL; pixels: ADDRESS; rowPitch: CARDINAL);
  VAR ctx: ID3D11DeviceContext;
BEGIN
  IF (gContext = NIL) OR (slot > 7) OR (gTex[slot] = NIL) THEN RETURN END;
  ctx := gContext;
  ctx.UpdateSubresource(gTex[slot], VAL(INTEGER32, 0), NIL, pixels,
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
  IF (gDevice = NIL) OR (maxVerts = 0) THEN RETURN FALSE END;
  dev := gDevice;
  ZeroMem(ADR(td), SIZE(td));
  td.width := VAL(DWORD, atlasW); td.height := VAL(DWORD, atlasH);
  td.mipLevels := VAL(DWORD, 1); td.arraySize := VAL(DWORD, 1);
  td.format := VAL(INTEGER32, 62);                 (* R8_UINT *)
  td.sampleCount := VAL(DWORD, 1); td.usage := VAL(INTEGER32, 0); td.bindFlags := VAL(DWORD, 8);
  gAtlas := NIL;
  vr := dev.CreateTexture2D(ADR(td), NIL, ADR(gAtlas));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gAtlasSRV := NIL;
  vr := dev.CreateShaderResourceView(gAtlas, NIL, ADR(gAtlasSRV));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  ZeroMem(ADR(td), SIZE(td));
  td.width := VAL(DWORD, palW); td.height := VAL(DWORD, palH);
  td.mipLevels := VAL(DWORD, 1); td.arraySize := VAL(DWORD, 1);
  td.format := VAL(INTEGER32, 87);                 (* B8G8R8A8_UNORM *)
  td.sampleCount := VAL(DWORD, 1); td.usage := VAL(INTEGER32, 0); td.bindFlags := VAL(DWORD, 8);
  gSPal := NIL;
  vr := dev.CreateTexture2D(ADR(td), NIL, ADR(gSPal));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gSPalSRV := NIL;
  vr := dev.CreateShaderResourceView(gSPal, NIL, ADR(gSPalSRV));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gSpriteSRVs[0] := gAtlasSRV; gSpriteSRVs[1] := gSPalSRV;
  (* sprite VS + input layout (from its bytecode) *)
  tgtVS := "vs_4_0"A; tgtPS := "ps_4_0"A; entMain := "main"A;
  vsBlob := NIL; errBlob := NIL;
  hr := D3DCompile(ADR(gSpriteVsSrc), VAL(ADRCARD, ALen(gSpriteVsSrc)), NIL, NIL, NIL,
                   ADR(entMain), ADR(tgtVS), VAL(DWORD, 0), VAL(DWORD, 0), ADR(vsBlob), ADR(errBlob));
  IF hr < 0 THEN RETURN FALSE END;
  vb := vsBlob; gSpriteVS := NIL;
  vr := dev.CreateVertexShader(vb.GetBufferPointer(), vb.GetBufferSize(), NIL, ADR(gSpriteVS));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gSemPos := "POSITION"A; gSemTex := "TEXCOORD"A;
  gIL[0].semantic := ADR(gSemPos); gIL[0].semIndex := VAL(DWORD,0); gIL[0].format := VAL(INTEGER32,16);
  gIL[0].inputSlot := VAL(DWORD,0); gIL[0].alignedOffset := VAL(DWORD,0);  gIL[0].slotClass := VAL(INTEGER32,0); gIL[0].stepRate := VAL(DWORD,0);
  gIL[1].semantic := ADR(gSemTex); gIL[1].semIndex := VAL(DWORD,0); gIL[1].format := VAL(INTEGER32,16);
  gIL[1].inputSlot := VAL(DWORD,0); gIL[1].alignedOffset := VAL(DWORD,8);  gIL[1].slotClass := VAL(INTEGER32,0); gIL[1].stepRate := VAL(DWORD,0);
  gIL[2].semantic := ADR(gSemTex); gIL[2].semIndex := VAL(DWORD,1); gIL[2].format := VAL(INTEGER32,16);
  gIL[2].inputSlot := VAL(DWORD,0); gIL[2].alignedOffset := VAL(DWORD,16); gIL[2].slotClass := VAL(INTEGER32,0); gIL[2].stepRate := VAL(DWORD,0);
  gSpriteIL := NIL;
  vr := dev.CreateInputLayout(ADR(gIL), VAL(DWORD,3), vb.GetBufferPointer(), vb.GetBufferSize(), ADR(gSpriteIL));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  (* sprite PS *)
  psBlob := NIL; errBlob := NIL;
  hr := D3DCompile(ADR(gSpritePsSrc), VAL(ADRCARD, ALen(gSpritePsSrc)), NIL, NIL, NIL,
                   ADR(entMain), ADR(tgtPS), VAL(DWORD, 0), VAL(DWORD, 0), ADR(psBlob), ADR(errBlob));
  IF hr < 0 THEN RETURN FALSE END;
  pb := psBlob; gSpritePS := NIL;
  vr := dev.CreatePixelShader(pb.GetBufferPointer(), pb.GetBufferSize(), NIL, ADR(gSpritePS));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  (* alpha-over blend state: SRC_ALPHA / INV_SRC_ALPHA *)
  ZeroMem(ADR(bl), SIZE(bl));
  bl.rt0Enable := VAL(INTEGER32, 1);
  bl.rt0Src    := VAL(INTEGER32, 5); bl.rt0Dest  := VAL(INTEGER32, 6); bl.rt0Op  := VAL(INTEGER32, 1);
  bl.rt0SrcA   := VAL(INTEGER32, 2); bl.rt0DestA := VAL(INTEGER32, 6); bl.rt0OpA := VAL(INTEGER32, 1);
  bl.rt0WriteMask := VAL(DWORD, 15);
  gBlend := NIL;
  vr := dev.CreateBlendState(ADR(bl), ADR(gBlend));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  (* dynamic vertex buffer: maxVerts * 24 bytes (pos.xy, uv.xy, meta.xy) *)
  ZeroMem(ADR(bd), SIZE(bd));
  bd.byteWidth := VAL(DWORD, maxVerts * 24);
  bd.usage := VAL(INTEGER32, 2);                   (* DYNAMIC *)
  bd.bindFlags := VAL(DWORD, 1);                   (* VERTEX_BUFFER *)
  bd.cpuAccess := VAL(DWORD, 65536);               (* CPU_ACCESS_WRITE = 0x10000 *)
  gSpriteVB := NIL;
  vr := dev.CreateBuffer(ADR(bd), NIL, ADR(gSpriteVB));
  IF (vr BAND 80000000H) # 0 THEN RETURN FALSE END;
  gSpriteVBCap := maxVerts; gSpriteReady := TRUE;
  RETURN TRUE
END InitSprites;

PROCEDURE UploadAtlas (pixels: ADDRESS; rowPitch: CARDINAL);
  VAR ctx: ID3D11DeviceContext;
BEGIN
  IF (gContext = NIL) OR (gAtlas = NIL) THEN RETURN END;
  ctx := gContext;
  ctx.UpdateSubresource(gAtlas, VAL(INTEGER32,0), NIL, pixels, VAL(INTEGER32, VAL(INTEGER,rowPitch)), VAL(INTEGER32,0))
END UploadAtlas;

PROCEDURE UploadSpritePalette (pixels: ADDRESS; rowPitch: CARDINAL);
  VAR ctx: ID3D11DeviceContext;
BEGIN
  IF (gContext = NIL) OR (gSPal = NIL) THEN RETURN END;
  ctx := gContext;
  ctx.UpdateSubresource(gSPal, VAL(INTEGER32,0), NIL, pixels, VAL(INTEGER32, VAL(INTEGER,rowPitch)), VAL(INTEGER32,0))
END UploadSpritePalette;

(* Background pass: clear + the full-screen index->RGBA LUT draw. No Present. *)
PROCEDURE BeginFrame (constants: ADDRESS);
  VAR ctx: ID3D11DeviceContext; clr: ARRAY [0..3] OF SHORTREAL;
BEGIN
  IF (gContext = NIL) OR (gRTV = NIL) OR (gPS = NIL) THEN RETURN END;
  ctx := gContext;
  ctx.UpdateSubresource(gCB, VAL(INTEGER32, 0), NIL, constants, VAL(INTEGER32, 0), VAL(INTEGER32, 0));
  ctx.OMSetRenderTargets(VAL(INTEGER32, 1), ADR(gRTV), NIL);
  clr[0] := VAL(SHORTREAL, 0.0); clr[1] := VAL(SHORTREAL, 0.0);
  clr[2] := VAL(SHORTREAL, 0.0); clr[3] := VAL(SHORTREAL, 1.0);
  ctx.ClearRenderTargetView(gRTV, ADR(clr));
  ctx.IASetInputLayout(NIL);                         (* background VS = SV_VertexID *)
  ctx.IASetPrimitiveTopology(VAL(INTEGER32, 4));     (* TRIANGLELIST *)
  ctx.VSSetShader(gVS, NIL, VAL(INTEGER32, 0));
  ctx.PSSetShader(gPS, NIL, VAL(INTEGER32, 0));
  ctx.PSSetConstantBuffers(VAL(INTEGER32, 0), VAL(INTEGER32, 1), ADR(gCB));
  IF gTexN > 0 THEN
    ctx.PSSetShaderResources(VAL(INTEGER32, 0), VAL(INTEGER32, VAL(INTEGER, gTexN)), ADR(gSRV))
  END;
  ctx.RSSetViewports(VAL(INTEGER32, 1), ADR(gVP));
  ctx.Draw(VAL(INTEGER32, 3), VAL(INTEGER32, 0))
END BeginFrame;

(* Sprite pass: upload `vertCount` vertices (6 floats each: pos.xy NDC, atlas px
   uv.xy, meta.xy = palette-slot, alpha) and draw them alpha-over the background. *)
PROCEDURE DrawSprites (verts: ADDRESS; vertCount: CARDINAL);
  VAR ctx: ID3D11DeviceContext; m: Mapped; vr: INTEGER; stride, offset: DWORD;
BEGIN
  IF (NOT gSpriteReady) OR (vertCount = 0) OR (vertCount > gSpriteVBCap) THEN RETURN END;
  ctx := gContext;
  vr := ctx.Map(gSpriteVB, VAL(DWORD, 0), VAL(INTEGER32, 4), VAL(DWORD, 0), ADR(m));  (* WRITE_DISCARD *)
  IF (vr BAND 80000000H) # 0 THEN RETURN END;
  MoveMem(m.pData, verts, vertCount * 24);
  ctx.Unmap(gSpriteVB, VAL(DWORD, 0));
  stride := VAL(DWORD, 24); offset := VAL(DWORD, 0);
  ctx.IASetInputLayout(gSpriteIL);
  ctx.IASetVertexBuffers(VAL(DWORD, 0), VAL(DWORD, 1), ADR(gSpriteVB), ADR(stride), ADR(offset));
  ctx.IASetPrimitiveTopology(VAL(INTEGER32, 4));
  ctx.VSSetShader(gSpriteVS, NIL, VAL(INTEGER32, 0));
  ctx.PSSetShader(gSpritePS, NIL, VAL(INTEGER32, 0));
  ctx.PSSetShaderResources(VAL(INTEGER32, 0), VAL(INTEGER32, 2), ADR(gSpriteSRVs));
  ctx.OMSetBlendState(gBlend, NIL, VAL(DWORD, 0FFFFFFFFH));
  ctx.RSSetViewports(VAL(INTEGER32, 1), ADR(gVP));
  ctx.Draw(VAL(INTEGER32, VAL(INTEGER, vertCount)), VAL(INTEGER32, 0));
  ctx.OMSetBlendState(NIL, NIL, VAL(DWORD, 0FFFFFFFFH))      (* back to opaque *)
END DrawSprites;

PROCEDURE EndFrame;
  VAR sc: IDXGISwapChain; vr: INTEGER;
BEGIN
  IF gSwap = NIL THEN RETURN END;
  sc := gSwap; vr := sc.Present(VAL(INTEGER32, 1), VAL(INTEGER32, 0))
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

PROCEDURE Shutdown;
  VAR o: IUnknown; d: INTEGER; i: CARDINAL;
BEGIN
  FOR i := 0 TO 7 DO
    IF gSRV[i] # NIL THEN o := gSRV[i]; d := o.Release(); gSRV[i] := NIL END;
    IF gTex[i] # NIL THEN o := gTex[i]; d := o.Release(); gTex[i] := NIL END
  END;
  gTexN := 0;
  IF gSpriteVB # NIL THEN o := gSpriteVB; d := o.Release(); gSpriteVB := NIL END;
  IF gBlend # NIL THEN o := gBlend; d := o.Release(); gBlend := NIL END;
  IF gSpriteIL # NIL THEN o := gSpriteIL; d := o.Release(); gSpriteIL := NIL END;
  IF gSpritePS # NIL THEN o := gSpritePS; d := o.Release(); gSpritePS := NIL END;
  IF gSpriteVS # NIL THEN o := gSpriteVS; d := o.Release(); gSpriteVS := NIL END;
  IF gAtlasSRV # NIL THEN o := gAtlasSRV; d := o.Release(); gAtlasSRV := NIL END;
  IF gAtlas # NIL THEN o := gAtlas; d := o.Release(); gAtlas := NIL END;
  IF gSPalSRV # NIL THEN o := gSPalSRV; d := o.Release(); gSPalSRV := NIL END;
  IF gSPal # NIL THEN o := gSPal; d := o.Release(); gSPal := NIL END;
  gSpriteReady := FALSE;
  IF gCB # NIL THEN o := gCB; d := o.Release(); gCB := NIL END;
  IF gPS # NIL THEN o := gPS; d := o.Release(); gPS := NIL END;
  IF gVS # NIL THEN o := gVS; d := o.Release(); gVS := NIL END;
  IF gRTV # NIL THEN o := gRTV; d := o.Release(); gRTV := NIL END;
  IF gContext # NIL THEN o := gContext; d := o.Release(); gContext := NIL END;
  IF gSwap # NIL THEN o := gSwap; d := o.Release(); gSwap := NIL END;
  IF gDevice # NIL THEN o := gDevice; d := o.Release(); gDevice := NIL END
END Shutdown;

VAR i: CARDINAL;
BEGIN
  gDevice := NIL; gContext := NIL; gSwap := NIL; gRTV := NIL;
  gVS := NIL; gPS := NIL; gCB := NIL; gCbSize := 16;
  gTexN := 0;
  FOR i := 0 TO 7 DO gTex[i] := NIL; gSRV[i] := NIL END;
  gSpriteVS := NIL; gSpritePS := NIL; gSpriteIL := NIL; gSpriteVB := NIL; gBlend := NIL;
  gAtlas := NIL; gAtlasSRV := NIL; gSPal := NIL; gSPalSRV := NIL;
  gSpriteVBCap := 0; gSpriteReady := FALSE;
  vsSrc := "struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; }; VSOut main(uint id : SV_VertexID) { VSOut o; float2 uv = float2((id << 1) & 2, id & 2); o.uv = uv; o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0); return o; }"A;
  (* sprite VS: vertices already carry NDC pos + atlas-pixel uv + (palette-slot, alpha) *)
  gSpriteVsSrc := "struct VSIn { float2 pos:POSITION; float2 uv:TEXCOORD0; float2 meta:TEXCOORD1; }; struct VSOut { float4 pos:SV_Position; float2 uv:TEXCOORD0; float2 meta:TEXCOORD1; }; VSOut main(VSIn i){ VSOut o; o.pos=float4(i.pos,0,1); o.uv=i.uv; o.meta=i.meta; return o; }"A;
  (* sprite PS: atlas index -> discard 0 -> per-sprite palette[slot][index] -> *alpha *)
  gSpritePsSrc := "Texture2D<uint> gAtlas:register(t0); Texture2D<float4> gSPal:register(t1); struct VSOut { float4 pos:SV_Position; float2 uv:TEXCOORD0; float2 meta:TEXCOORD1; }; float4 main(VSOut i):SV_Target { int2 ap=int2(i.uv); uint idx=gAtlas.Load(int3(ap,0)); if(idx==0u) discard; int slot=int(i.meta.x+0.5); float4 c=gSPal.Load(int3(int(idx),slot,0)); return float4(c.rgb, i.meta.y); }"A
END ShaderView.
