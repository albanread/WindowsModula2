IMPLEMENTATION MODULE GameViewGpu;

(* The CPU model behind the GPU retro present. There are NBuf indexed buffers
   (gBuf), each a WORLD of gFbW x gFbH index bytes — bigger than the visible VIEW
   (gViewW x gViewH) so scrolling is smooth: the LUT shader samples a view-sized
   window of the displayed buffer at (gScrollX, gScrollY). You draw into a selected
   buffer (gDraw) with the indexed primitives, Blit regions between buffers (for
   parallax layers / pre-rendered backgrounds), and present a chosen buffer
   (gDisplay). Indices 16..255 use the global palette gPal; 0..15 use the per-view-
   scanline palette gLine. Sprites are definitions (art in a shared atlas + own
   16-colour palette + frames) and instances (transform/alpha/flip/priority/frame),
   baked to a vertex buffer each frame and drawn alpha-over by ShaderView. *)

FROM SYSTEM IMPORT ADDRESS, ADR;
FROM RealMath IMPORT sin, cos;
IMPORT ShaderView;

CONST
  MaxWorldW = 1280; MaxWorldH = 512; MaxWorld = MaxWorldW*MaxWorldH;
  NBuf = 4;                          (* buffer 0 = display by default; 1..3 = scratch/layers *)
  AtlasW = 512; AtlasH = 512;
  MaxDefs = 64; MaxFrames = 16; MaxInst = 256;
  MaxSlots = 64; FrameDim = 64;

  (* background LUT shader. The constant buffer carries scroll + view so the GPU
     samples a view-sized window of the (world-sized) index texture: smooth scroll.
     index 0..15 -> per-VIEW-scanline palette; 16..255 -> global palette. *)
  LutShader = "cbuffer P:register(b0){ float scrollX; float scrollY; float viewW; float viewH; }; struct VSOut { float4 pos:SV_Position; float2 uv:TEXCOORD0; }; Texture2D<uint> gIdx:register(t0); Texture2D<float4> gPal:register(t1); Texture2D<float4> gLine:register(t2); float4 main(VSOut i):SV_Target { int px=int(scrollX + i.uv.x*viewW); int py=int(scrollY + i.uv.y*viewH); uint c=gIdx.Load(int3(px,py,0)); int sy=int(i.uv.y*viewH); if(sy<0) sy=0; if(sy>=int(viewH)) sy=int(viewH)-1; float4 col; if(c<16u) col=gLine.Load(int3(int(c),sy,0)); else col=gPal.Load(int3(int(c),0,0)); return float4(col.rgb,1.0); }";

TYPE
  CB = RECORD scrollX, scrollY, viewW, viewH: SHORTREAL END;
  SpriteDef = RECORD
    used: BOOLEAN;
    w, h, frameCount, slot: CARDINAL;
    fx, fy: ARRAY [0..MaxFrames-1] OF CARDINAL;
  END;
  Instance = RECORD
    active, visible, flipH, flipV: BOOLEAN;
    def, frame, priority: CARDINAL;
    x, y, scale, rot, alpha, fps, acc: REAL;
  END;

VAR
  gBuf:   ARRAY [0..NBuf-1] OF ARRAY [0..MaxWorld-1] OF BYTE;
  gPal:   ARRAY [0..255] OF CARDINAL32;
  gLine:  ARRAY [0..16*MaxWorldH-1] OF CARDINAL32;
  gAtlas: ARRAY [0..AtlasW*AtlasH-1] OF BYTE;
  gSPal:  ARRAY [0..16*MaxSlots-1] OF CARDINAL32;
  gDefs:  ARRAY [0..MaxDefs-1] OF SpriteDef;
  gInst:  ARRAY [0..MaxInst-1] OF Instance;
  gVerts: ARRAY [0..MaxInst*36-1] OF SHORTREAL;
  gFrame: ARRAY [0..FrameDim*FrameDim-1] OF BYTE;
  gFbW, gFbH: INTEGER;                               (* WORLD dims (drawable) *)
  gFbWR, gFbHR: REAL;
  gViewW, gViewH: INTEGER;                           (* visible VIEW dims *)
  gViewWR, gViewHR: REAL;
  gScrollX, gScrollY: INTEGER;
  gScrollXR, gScrollYR: REAL;
  gDraw, gDisplay: CARDINAL;
  gShelfX, gShelfY, gShelfH, gNextSlot: CARDINAL;
  gAtlasDirty, gSPalDirty: BOOLEAN;
  gNF: CARDINAL;
  gBcx, gBcy, gBca, gBsa, gBalpha, gBslot: REAL;
  gCB: CB;
  gGlyph: ARRAY [0..127] OF ARRAY [0..6] OF CARDINAL;
  BV: ARRAY [0..4] OF CARDINAL;

PROCEDURE Width  (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gFbW) END Width;
PROCEDURE Height (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gFbH) END Height;
PROCEDURE ViewWidth  (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gViewW) END ViewWidth;
PROCEDURE ViewHeight (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gViewH) END ViewHeight;
PROCEDURE NumBuffers (): CARDINAL; BEGIN RETURN NBuf END NumBuffers;

PROCEDURE IAbs (a: INTEGER): INTEGER; BEGIN IF a < 0 THEN RETURN -a ELSE RETURN a END END IAbs;

(* ---- buffers + scroll ------------------------------------------------- *)

PROCEDURE SelectBuffer (n: CARDINAL);   BEGIN IF n < NBuf THEN gDraw := n END END SelectBuffer;
PROCEDURE DisplayBuffer (n: CARDINAL);  BEGIN IF n < NBuf THEN gDisplay := n END END DisplayBuffer;

PROCEDURE SetScroll (x, y: INTEGER);
BEGIN
  IF x < 0 THEN x := 0 END;
  IF x > gFbW - gViewW THEN x := gFbW - gViewW END;
  IF y < 0 THEN y := 0 END;
  IF y > gFbH - gViewH THEN y := gFbH - gViewH END;
  gScrollX := x; gScrollY := y;
  gScrollXR := VAL(REAL, x); gScrollYR := VAL(REAL, y)
END SetScroll;

PROCEDURE ScrollX (): INTEGER; BEGIN RETURN gScrollX END ScrollX;
PROCEDURE ScrollY (): INTEGER; BEGIN RETURN gScrollY END ScrollY;

PROCEDURE BlitImpl (src: CARDINAL; sx, sy, w, h: INTEGER; dst: CARDINAL; dx, dy: INTEGER; trans: BOOLEAN);
  VAR r, c, px, py, qx, qy: INTEGER; v: CARDINAL;
BEGIN
  IF (src >= NBuf) OR (dst >= NBuf) THEN RETURN END;
  r := 0;
  WHILE r < h DO
    c := 0;
    WHILE c < w DO
      px := sx+c; py := sy+r; qx := dx+c; qy := dy+r;
      IF (px >= 0) AND (px < gFbW) AND (py >= 0) AND (py < gFbH)
         AND (qx >= 0) AND (qx < gFbW) AND (qy >= 0) AND (qy < gFbH) THEN
        v := VAL(CARDINAL, gBuf[src][VAL(CARDINAL, py*gFbW + px)]) BAND 0FFH;
        IF (NOT trans) OR (v # 0) THEN gBuf[dst][VAL(CARDINAL, qy*gFbW + qx)] := VAL(BYTE, v) END
      END;
      INC(c)
    END;
    INC(r)
  END
END BlitImpl;

PROCEDURE Blit (src: CARDINAL; srcX, srcY, w, h: INTEGER; dst: CARDINAL; dstX, dstY: INTEGER);
BEGIN BlitImpl(src, srcX, srcY, w, h, dst, dstX, dstY, FALSE) END Blit;
PROCEDURE BlitTrans (src: CARDINAL; srcX, srcY, w, h: INTEGER; dst: CARDINAL; dstX, dstY: INTEGER);
BEGIN BlitImpl(src, srcX, srcY, w, h, dst, dstX, dstY, TRUE) END BlitTrans;

(* ---- palettes --------------------------------------------------------- *)

PROCEDURE SetColour (index, rgb: CARDINAL);
BEGIN IF index <= 255 THEN gPal[index] := VAL(CARDINAL32, rgb BAND 0FFFFFFH) END END SetColour;
PROCEDURE SetRGB (index, r, g, b: CARDINAL);
BEGIN SetColour(index, ((r BAND 0FFH)*65536) + ((g BAND 0FFH)*256) + (b BAND 0FFH)) END SetRGB;

PROCEDURE LoadDefaultPalette;
BEGIN
  SetColour(0,000000H);SetColour(1,0000AAH);SetColour(2,000AA00H);SetColour(3,00AAAAH);
  SetColour(4,0AA0000H);SetColour(5,0AA00AAH);SetColour(6,0AA5500H);SetColour(7,0AAAAAAH);
  SetColour(8,0555555H);SetColour(9,05555FFH);SetColour(10,055FF55H);SetColour(11,055FFFFH);
  SetColour(12,0FF5555H);SetColour(13,0FF55FFH);SetColour(14,0FFFF55H);SetColour(15,0FFFFFFH);
  SeedLinePalette
END LoadDefaultPalette;

PROCEDURE CyclePalette (lo, hi: CARDINAL);
  VAR i: CARDINAL; tmp: CARDINAL32;
BEGIN
  IF (hi > 255) OR (lo >= hi) THEN RETURN END;
  tmp := gPal[lo];
  FOR i := lo TO hi-1 DO gPal[i] := gPal[i+1] END;
  gPal[hi] := tmp
END CyclePalette;

PROCEDURE SetLineColour (y, index, rgb: CARDINAL);
BEGIN
  IF (index <= 15) AND (y < VAL(CARDINAL, gViewH)) THEN
    gLine[y*16 + index] := VAL(CARDINAL32, rgb BAND 0FFFFFFH)
  END
END SetLineColour;
PROCEDURE SetLineRGB (y, index, r, g, b: CARDINAL);
BEGIN SetLineColour(y, index, ((r BAND 0FFH)*65536)+((g BAND 0FFH)*256)+(b BAND 0FFH)) END SetLineRGB;

PROCEDURE SeedLinePalette;
  VAR y, idx: CARDINAL;
BEGIN
  IF gViewH <= 0 THEN RETURN END;
  FOR y := 0 TO VAL(CARDINAL, gViewH)-1 DO
    FOR idx := 0 TO 15 DO gLine[y*16 + idx] := gPal[idx] END
  END
END SeedLinePalette;

(* ---- indexed drawing (into the selected buffer, clipped to the world) - *)

PROCEDURE Pset (x, y: INTEGER; index: CARDINAL);
BEGIN
  IF (x >= 0) AND (x < gFbW) AND (y >= 0) AND (y < gFbH) THEN
    gBuf[gDraw][VAL(CARDINAL, y*gFbW + x)] := VAL(BYTE, index BAND 0FFH)
  END
END Pset;

PROCEDURE Pget (x, y: INTEGER): CARDINAL;
BEGIN
  IF (x >= 0) AND (x < gFbW) AND (y >= 0) AND (y < gFbH) THEN
    RETURN VAL(CARDINAL, gBuf[gDraw][VAL(CARDINAL, y*gFbW + x)]) BAND 0FFH
  END;
  RETURN 0
END Pget;

PROCEDURE Cls (index: CARDINAL);
  VAR i, n: CARDINAL; v: BYTE;
BEGIN
  v := VAL(BYTE, index BAND 0FFH); n := VAL(CARDINAL, gFbW*gFbH); i := 0;
  WHILE i < n DO gBuf[gDraw][i] := v; INC(i) END
END Cls;

PROCEDURE HLine (x, y, len: INTEGER; index: CARDINAL);
  VAR i: INTEGER;
BEGIN i := 0; WHILE i < len DO Pset(x+i, y, index); INC(i) END END HLine;
PROCEDURE VLine (x, y, len: INTEGER; index: CARDINAL);
  VAR i: INTEGER;
BEGIN i := 0; WHILE i < len DO Pset(x, y+i, index); INC(i) END END VLine;
PROCEDURE FillRect (x, y, w, h: INTEGER; index: CARDINAL);
  VAR j: INTEGER;
BEGIN j := 0; WHILE j < h DO HLine(x, y+j, w, index); INC(j) END END FillRect;
PROCEDURE Rect (x, y, w, h: INTEGER; index: CARDINAL);
BEGIN HLine(x,y,w,index); HLine(x,y+h-1,w,index); VLine(x,y,h,index); VLine(x+w-1,y,h,index) END Rect;

PROCEDURE Line (x0, y0, x1, y1: INTEGER; index: CARDINAL);
  VAR dx, dy, sx, sy, err, e2: INTEGER;
BEGIN
  dx := IAbs(x1-x0); dy := -IAbs(y1-y0);
  IF x0 < x1 THEN sx := 1 ELSE sx := -1 END;
  IF y0 < y1 THEN sy := 1 ELSE sy := -1 END;
  err := dx + dy;
  LOOP
    Pset(x0, y0, index);
    IF (x0 = x1) AND (y0 = y1) THEN EXIT END;
    e2 := 2*err;
    IF e2 >= dy THEN err := err + dy; x0 := x0 + sx END;
    IF e2 <= dx THEN err := err + dx; y0 := y0 + sy END
  END
END Line;

PROCEDURE Disc (cx, cy, r: INTEGER; index: CARDINAL);
  VAR dy, span: INTEGER;
BEGIN
  dy := -r;
  WHILE dy <= r DO
    span := 0; WHILE span*span + dy*dy <= r*r DO INC(span) END;
    HLine(cx-span+1, cy+dy, 2*span-1, index); INC(dy)
  END
END Disc;

PROCEDURE Circle (cx, cy, r: INTEGER; index: CARDINAL);
  VAR x, y, err: INTEGER;
BEGIN
  x := -r; y := 0; err := 2 - 2*r;
  REPEAT
    Pset(cx-x, cy+y, index); Pset(cx-y, cy-x, index);
    Pset(cx+x, cy-y, index); Pset(cx+y, cy+x, index);
    r := err;
    IF r <= y THEN INC(y); err := err + y*2 + 1 END;
    IF (r > x) OR (err > y) THEN INC(x); err := err + x*2 + 1 END
  UNTIL x >= 0
END Circle;

PROCEDURE Upper (ch: CHAR): CHAR;
BEGIN IF (ch >= 'a') AND (ch <= 'z') THEN RETURN CHR(ORD(ch)-32) ELSE RETURN ch END END Upper;

PROCEDURE Text (x, y: INTEGER; s: ARRAY OF CHAR; index: CARDINAL);
  VAR i, col, row, cx, mask: CARDINAL; ch: CHAR; px: INTEGER;
BEGIN
  i := 0; px := x;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO
    ch := Upper(s[i]); cx := ORD(ch);
    IF cx <= 127 THEN
      FOR row := 0 TO 6 DO
        mask := gGlyph[cx][row];
        FOR col := 0 TO 4 DO
          IF (mask BAND BV[col]) # 0 THEN Pset(px + VAL(INTEGER,col), y + VAL(INTEGER,row), index) END
        END
      END
    END;
    px := px + 6; INC(i)
  END
END Text;

(* ---- sprite definitions ----------------------------------------------- *)

PROCEDURE RowIndex (ch: CHAR): CARDINAL;
BEGIN
  IF (ch >= '0') AND (ch <= '9') THEN RETURN ORD(ch) - ORD('0') END;
  IF (ch >= 'A') AND (ch <= 'F') THEN RETURN ORD(ch) - ORD('A') + 10 END;
  IF (ch >= 'a') AND (ch <= 'f') THEN RETURN ORD(ch) - ORD('a') + 10 END;
  RETURN 0
END RowIndex;

PROCEDURE ParseFrame (rows: ARRAY OF CHAR; VAR w, h: CARDINAL): BOOLEAN;
  VAR i, n, col, row: CARDINAL; ch: CHAR;
BEGIN
  n := 0; WHILE (n <= HIGH(rows)) AND (rows[n] # 0C) DO INC(n) END;
  IF n = 0 THEN RETURN FALSE END;
  w := 0; WHILE (w < n) AND (rows[w] # '/') DO INC(w) END;
  IF (w = 0) OR (w > FrameDim) THEN RETURN FALSE END;
  FOR i := 0 TO FrameDim*FrameDim-1 DO gFrame[i] := VAL(BYTE, 0) END;
  col := 0; row := 0;
  FOR i := 0 TO n-1 DO
    ch := rows[i];
    IF ch = '/' THEN INC(row); col := 0
    ELSE IF (row < FrameDim) AND (col < w) THEN gFrame[row*w + col] := VAL(BYTE, RowIndex(ch)) END; INC(col) END
  END;
  h := row + 1;
  IF h > FrameDim THEN RETURN FALSE END;
  RETURN TRUE
END ParseFrame;

PROCEDURE AllocAtlas (w, h: CARDINAL; VAR ax, ay: CARDINAL): BOOLEAN;
BEGIN
  IF gShelfX + w > AtlasW THEN gShelfX := 0; gShelfY := gShelfY + gShelfH; gShelfH := 0 END;
  IF gShelfY + h > AtlasH THEN RETURN FALSE END;
  ax := gShelfX; ay := gShelfY; gShelfX := gShelfX + w;
  IF h > gShelfH THEN gShelfH := h END;
  RETURN TRUE
END AllocAtlas;

PROCEDURE BlitFrameToAtlas (ax, ay, w, h: CARDINAL);
  VAR r, c: CARDINAL;
BEGIN
  FOR r := 0 TO h-1 DO FOR c := 0 TO w-1 DO gAtlas[(ay+r)*AtlasW + (ax+c)] := gFrame[r*w + c] END END;
  gAtlasDirty := TRUE
END BlitFrameToAtlas;

PROCEDURE DefineSprite (id: CARDINAL; rows: ARRAY OF CHAR): BOOLEAN;
  VAR w, h, ax, ay, i: CARDINAL;
BEGIN
  IF id >= MaxDefs THEN RETURN FALSE END;
  IF NOT ParseFrame(rows, w, h) THEN RETURN FALSE END;
  IF NOT AllocAtlas(w, h, ax, ay) THEN RETURN FALSE END;
  BlitFrameToAtlas(ax, ay, w, h);
  gDefs[id].used := TRUE; gDefs[id].w := w; gDefs[id].h := h; gDefs[id].frameCount := 1;
  gDefs[id].fx[0] := ax; gDefs[id].fy[0] := ay;
  gDefs[id].slot := gNextSlot;
  IF gNextSlot < MaxSlots-1 THEN INC(gNextSlot) END;
  FOR i := 0 TO 15 DO gSPal[gDefs[id].slot*16 + i] := gPal[i] END;
  gSPalDirty := TRUE;
  RETURN TRUE
END DefineSprite;

PROCEDURE AddFrame (id: CARDINAL; rows: ARRAY OF CHAR): BOOLEAN;
  VAR w, h, ax, ay, fc: CARDINAL;
BEGIN
  IF (id >= MaxDefs) OR (NOT gDefs[id].used) THEN RETURN FALSE END;
  fc := gDefs[id].frameCount;
  IF fc >= MaxFrames THEN RETURN FALSE END;
  IF NOT ParseFrame(rows, w, h) THEN RETURN FALSE END;
  IF (w # gDefs[id].w) OR (h # gDefs[id].h) THEN RETURN FALSE END;
  IF NOT AllocAtlas(w, h, ax, ay) THEN RETURN FALSE END;
  BlitFrameToAtlas(ax, ay, w, h);
  gDefs[id].fx[fc] := ax; gDefs[id].fy[fc] := ay; gDefs[id].frameCount := fc + 1;
  RETURN TRUE
END AddFrame;

PROCEDURE SpriteColour (id, index, rgb: CARDINAL);
BEGIN
  IF (id < MaxDefs) AND gDefs[id].used AND (index <= 15) THEN
    gSPal[gDefs[id].slot*16 + index] := VAL(CARDINAL32, rgb BAND 0FFFFFFH); gSPalDirty := TRUE
  END
END SpriteColour;
PROCEDURE SpriteRGB (id, index, r, g, b: CARDINAL);
BEGIN SpriteColour(id, index, ((r BAND 0FFH)*65536)+((g BAND 0FFH)*256)+(b BAND 0FFH)) END SpriteRGB;

PROCEDURE SpriteFrames (id: CARDINAL): CARDINAL;
BEGIN IF (id < MaxDefs) AND gDefs[id].used THEN RETURN gDefs[id].frameCount ELSE RETURN 0 END END SpriteFrames;
PROCEDURE SpriteWidth (id: CARDINAL): CARDINAL;
BEGIN IF (id < MaxDefs) AND gDefs[id].used THEN RETURN gDefs[id].w ELSE RETURN 0 END END SpriteWidth;
PROCEDURE SpriteHeight (id: CARDINAL): CARDINAL;
BEGIN IF (id < MaxDefs) AND gDefs[id].used THEN RETURN gDefs[id].h ELSE RETURN 0 END END SpriteHeight;

(* ---- sprite instances ------------------------------------------------- *)

PROCEDURE Place (inst, def: CARDINAL; x, y: REAL);
BEGIN
  IF (inst >= MaxInst) OR (def >= MaxDefs) OR (NOT gDefs[def].used) THEN RETURN END;
  gInst[inst].active := TRUE; gInst[inst].visible := TRUE;
  gInst[inst].flipH := FALSE; gInst[inst].flipV := FALSE;
  gInst[inst].def := def; gInst[inst].frame := 0; gInst[inst].priority := 128;
  gInst[inst].x := x; gInst[inst].y := y;
  gInst[inst].scale := 1.0; gInst[inst].rot := 0.0; gInst[inst].alpha := 1.0;
  gInst[inst].fps := 0.0; gInst[inst].acc := 0.0
END Place;

PROCEDURE MoveTo (inst: CARDINAL; x, y: REAL);
BEGIN IF inst < MaxInst THEN gInst[inst].x := x; gInst[inst].y := y END END MoveTo;

PROCEDURE SpriteX (inst: CARDINAL): REAL;
BEGIN IF inst < MaxInst THEN RETURN gInst[inst].x ELSE RETURN 0.0 END END SpriteX;
PROCEDURE SpriteY (inst: CARDINAL): REAL;
BEGIN IF inst < MaxInst THEN RETURN gInst[inst].y ELSE RETURN 0.0 END END SpriteY;
PROCEDURE Visible (inst: CARDINAL): BOOLEAN;
BEGIN RETURN (inst < MaxInst) AND gInst[inst].active AND gInst[inst].visible END Visible;

(* bounding-box overlap of two shown instances (boxes = def size x scale, centred) *)
PROCEDURE Hit (a, b: CARDINAL): BOOLEAN;
  VAR ahw, ahh, bhw, bhh, dx, dy: REAL; da, db: CARDINAL;
BEGIN
  IF (a >= MaxInst) OR (b >= MaxInst) THEN RETURN FALSE END;
  IF NOT (gInst[a].active AND gInst[a].visible AND gInst[b].active AND gInst[b].visible) THEN RETURN FALSE END;
  da := gInst[a].def; db := gInst[b].def;
  ahw := VAL(REAL, gDefs[da].w) * gInst[a].scale * 0.5;
  ahh := VAL(REAL, gDefs[da].h) * gInst[a].scale * 0.5;
  bhw := VAL(REAL, gDefs[db].w) * gInst[b].scale * 0.5;
  bhh := VAL(REAL, gDefs[db].h) * gInst[b].scale * 0.5;
  dx := gInst[a].x - gInst[b].x; IF dx < 0.0 THEN dx := -dx END;
  dy := gInst[a].y - gInst[b].y; IF dy < 0.0 THEN dy := -dy END;
  RETURN (dx < ahw + bhw) AND (dy < ahh + bhh)
END Hit;

PROCEDURE SetScale (inst: CARDINAL; s: REAL);
BEGIN IF inst < MaxInst THEN gInst[inst].scale := s END END SetScale;
PROCEDURE SetRotation (inst: CARDINAL; degrees: REAL);
BEGIN IF inst < MaxInst THEN gInst[inst].rot := degrees * 3.14159265358979 / 180.0 END END SetRotation;
PROCEDURE SetAlpha (inst: CARDINAL; a: REAL);
BEGIN
  IF inst < MaxInst THEN
    IF a < 0.0 THEN a := 0.0 END; IF a > 1.0 THEN a := 1.0 END; gInst[inst].alpha := a
  END
END SetAlpha;
PROCEDURE SetFlip (inst: CARDINAL; h, v: BOOLEAN);
BEGIN IF inst < MaxInst THEN gInst[inst].flipH := h; gInst[inst].flipV := v END END SetFlip;
PROCEDURE SetPriority (inst, p: CARDINAL);
BEGIN IF inst < MaxInst THEN gInst[inst].priority := p END END SetPriority;
PROCEDURE SetFrame (inst, frame: CARDINAL);
BEGIN IF inst < MaxInst THEN gInst[inst].frame := frame END END SetFrame;
PROCEDURE Animate (inst: CARDINAL; fps: REAL);
BEGIN IF inst < MaxInst THEN gInst[inst].fps := fps; gInst[inst].acc := 0.0 END END Animate;
PROCEDURE Show (inst: CARDINAL); BEGIN IF inst < MaxInst THEN gInst[inst].visible := TRUE END END Show;
PROCEDURE Hide (inst: CARDINAL); BEGIN IF inst < MaxInst THEN gInst[inst].visible := FALSE END END Hide;
PROCEDURE Remove (inst: CARDINAL);
BEGIN IF inst < MaxInst THEN gInst[inst].active := FALSE; gInst[inst].visible := FALSE END END Remove;

PROCEDURE Tick (dt: REAL);
  VAR i, fc: CARDINAL;
BEGIN
  FOR i := 0 TO MaxInst-1 DO
    IF gInst[i].active AND (gInst[i].fps > 0.0) THEN
      fc := gDefs[gInst[i].def].frameCount;
      IF fc > 1 THEN
        gInst[i].acc := gInst[i].acc + dt * gInst[i].fps;
        WHILE gInst[i].acc >= 1.0 DO
          gInst[i].acc := gInst[i].acc - 1.0;
          gInst[i].frame := (gInst[i].frame + 1) MOD fc
        END
      END
    END
  END
END Tick;

(* ---- bake + present (sprites are in WORLD coords; scroll is subtracted) - *)

PROCEDURE EmitVert (lx, ly, u, v: REAL);
  VAR fx, fy: REAL;
BEGIN
  fx := gBcx + lx*gBca - ly*gBsa;
  fy := gBcy + lx*gBsa + ly*gBca;
  gVerts[gNF]   := VAL(SHORTREAL, (fx - gScrollXR)/gViewWR*2.0 - 1.0);
  gVerts[gNF+1] := VAL(SHORTREAL, 1.0 - (fy - gScrollYR)/gViewHR*2.0);
  gVerts[gNF+2] := VAL(SHORTREAL, u);
  gVerts[gNF+3] := VAL(SHORTREAL, v);
  gVerts[gNF+4] := VAL(SHORTREAL, gBslot);
  gVerts[gNF+5] := VAL(SHORTREAL, gBalpha);
  gNF := gNF + 6
END EmitVert;

PROCEDURE EmitInstance (ix: CARDINAL);
  VAR d, frame, w, h: CARDINAL; hw, hh, u0, u1, v0, v1, tmp: REAL;
BEGIN
  d := gInst[ix].def; frame := gInst[ix].frame;
  IF frame >= gDefs[d].frameCount THEN frame := 0 END;
  w := gDefs[d].w; h := gDefs[d].h;
  hw := VAL(REAL, w) * gInst[ix].scale * 0.5;
  hh := VAL(REAL, h) * gInst[ix].scale * 0.5;
  gBcx := gInst[ix].x; gBcy := gInst[ix].y;
  gBca := cos(gInst[ix].rot); gBsa := sin(gInst[ix].rot);
  gBalpha := gInst[ix].alpha; gBslot := VAL(REAL, gDefs[d].slot);
  u0 := VAL(REAL, gDefs[d].fx[frame]); u1 := u0 + VAL(REAL, w);
  v0 := VAL(REAL, gDefs[d].fy[frame]); v1 := v0 + VAL(REAL, h);
  IF gInst[ix].flipH THEN tmp := u0; u0 := u1; u1 := tmp END;
  IF gInst[ix].flipV THEN tmp := v0; v0 := v1; v1 := tmp END;
  EmitVert(-hw, -hh, u0, v0); EmitVert(hw, -hh, u1, v0); EmitVert(hw, hh, u1, v1);
  EmitVert(-hw, -hh, u0, v0); EmitVert(hw, hh, u1, v1); EmitVert(-hw, hh, u0, v1)
END EmitInstance;

PROCEDURE Sync;
  VAR i, n, j, key, kp: CARDINAL; order: ARRAY [0..MaxInst-1] OF CARDINAL;
BEGIN
  n := 0;
  FOR i := 0 TO MaxInst-1 DO
    IF gInst[i].active AND gInst[i].visible THEN order[n] := i; INC(n) END
  END;
  IF n >= 2 THEN
    FOR i := 1 TO n-1 DO
      key := order[i]; kp := gInst[key].priority; j := i;
      WHILE (j >= 1) AND (gInst[order[j-1]].priority > kp) DO order[j] := order[j-1]; DEC(j) END;
      order[j] := key
    END
  END;
  gNF := 0;
  IF n >= 1 THEN FOR i := 0 TO n-1 DO EmitInstance(order[i]) END END
END Sync;

PROCEDURE Present;
BEGIN
  ShaderView.UploadTexture(0, ADR(gBuf[gDisplay][0]), VAL(CARDINAL, gFbW));
  ShaderView.UploadTexture(1, ADR(gPal), 1024);
  ShaderView.UploadTexture(2, ADR(gLine), 64);
  IF gAtlasDirty THEN ShaderView.UploadAtlas(ADR(gAtlas), AtlasW); gAtlasDirty := FALSE END;
  IF gSPalDirty THEN ShaderView.UploadSpritePalette(ADR(gSPal), 16*4); gSPalDirty := FALSE END;
  gCB.scrollX := VAL(SHORTREAL, gScrollXR); gCB.scrollY := VAL(SHORTREAL, gScrollYR);
  gCB.viewW := VAL(SHORTREAL, gViewWR);     gCB.viewH := VAL(SHORTREAL, gViewHR);
  Sync;
  ShaderView.BeginFrame(ADR(gCB));
  IF gNF > 0 THEN ShaderView.DrawSprites(ADR(gVerts), gNF DIV 6) END;
  ShaderView.EndFrame
END Present;

(* ---- font ------------------------------------------------------------- *)

PROCEDURE RowBits (r: ARRAY OF CHAR): CARDINAL;
  VAR i, v: CARDINAL;
BEGIN v := 0; FOR i := 0 TO 4 DO IF (i <= HIGH(r)) AND (r[i] = 'X') THEN v := v + BV[i] END END; RETURN v END RowBits;

PROCEDURE G (ch: CHAR; r0, r1, r2, r3, r4, r5, r6: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := ORD(ch); IF i > 127 THEN RETURN END;
  gGlyph[i][0]:=RowBits(r0); gGlyph[i][1]:=RowBits(r1); gGlyph[i][2]:=RowBits(r2);
  gGlyph[i][3]:=RowBits(r3); gGlyph[i][4]:=RowBits(r4); gGlyph[i][5]:=RowBits(r5); gGlyph[i][6]:=RowBits(r6)
END G;

PROCEDURE BuildFont;
  VAR i, j: CARDINAL;
BEGIN
  BV[0]:=16; BV[1]:=8; BV[2]:=4; BV[3]:=2; BV[4]:=1;
  FOR i := 0 TO 127 DO FOR j := 0 TO 6 DO gGlyph[i][j] := 0 END END;
  G(' ',".....",".....",".....",".....",".....",".....",".....");
  G('0',".XXX.","X...X","X..XX","X.X.X","XX..X","X...X",".XXX.");
  G('1',"..X..",".XX..","..X..","..X..","..X..","..X..",".XXX.");
  G('2',".XXX.","X...X","....X","..XX.",".X...","X....","XXXXX");
  G('3',"XXXXX","....X","...X.","..XX.","....X","X...X",".XXX.");
  G('4',"...X.","..XX.",".X.X.","X..X.","XXXXX","...X.","...X.");
  G('5',"XXXXX","X....","XXXX.","....X","....X","X...X",".XXX.");
  G('6',"..XX.",".X...","X....","XXXX.","X...X","X...X",".XXX.");
  G('7',"XXXXX","....X","...X.","..X..",".X...",".X...",".X...");
  G('8',".XXX.","X...X","X...X",".XXX.","X...X","X...X",".XXX.");
  G('9',".XXX.","X...X","X...X",".XXXX","....X","...X.",".XX..");
  G('A',".XXX.","X...X","X...X","X...X","XXXXX","X...X","X...X");
  G('B',"XXXX.","X...X","X...X","XXXX.","X...X","X...X","XXXX.");
  G('C',".XXX.","X...X","X....","X....","X....","X...X",".XXX.");
  G('D',"XXXX.","X...X","X...X","X...X","X...X","X...X","XXXX.");
  G('E',"XXXXX","X....","X....","XXXX.","X....","X....","XXXXX");
  G('F',"XXXXX","X....","X....","XXXX.","X....","X....","X....");
  G('G',".XXX.","X...X","X....","X.XXX","X...X","X...X",".XXXX");
  G('H',"X...X","X...X","X...X","XXXXX","X...X","X...X","X...X");
  G('I',".XXX.","..X..","..X..","..X..","..X..","..X..",".XXX.");
  G('J',"..XXX","...X.","...X.","...X.","X..X.","X..X.",".XX..");
  G('K',"X...X","X..X.","X.X..","XX...","X.X..","X..X.","X...X");
  G('L',"X....","X....","X....","X....","X....","X....","XXXXX");
  G('M',"X...X","XX.XX","X.X.X","X.X.X","X...X","X...X","X...X");
  G('N',"X...X","XX..X","X.X.X","X..XX","X...X","X...X","X...X");
  G('O',".XXX.","X...X","X...X","X...X","X...X","X...X",".XXX.");
  G('P',"XXXX.","X...X","X...X","XXXX.","X....","X....","X....");
  G('Q',".XXX.","X...X","X...X","X...X","X.X.X","X..X.",".XX.X");
  G('R',"XXXX.","X...X","X...X","XXXX.","X.X..","X..X.","X...X");
  G('S',".XXXX","X....","X....",".XXX.","....X","....X","XXXX.");
  G('T',"XXXXX","..X..","..X..","..X..","..X..","..X..","..X..");
  G('U',"X...X","X...X","X...X","X...X","X...X","X...X",".XXX.");
  G('V',"X...X","X...X","X...X","X...X","X...X",".X.X.","..X..");
  G('W',"X...X","X...X","X...X","X.X.X","X.X.X","XX.XX","X...X");
  G('X',"X...X","X...X",".X.X.","..X..",".X.X.","X...X","X...X");
  G('Y',"X...X","X...X",".X.X.","..X..","..X..","..X..","..X..");
  G('Z',"XXXXX","....X","...X.","..X..",".X...","X....","XXXXX");
  G('.',".....",".....",".....",".....",".....",".XX..",".XX..");
  G(':',".....",".XX..",".XX..",".....",".XX..",".XX..",".....");
  G('-',".....",".....",".....","XXXXX",".....",".....",".....");
  G('!',"..X..","..X..","..X..","..X..","..X..",".....","..X..")
END BuildFont;

(* ---- lifecycle -------------------------------------------------------- *)

PROCEDURE Startup (): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  BuildFont;
  FOR i := 0 TO 255 DO gPal[i] := VAL(CARDINAL32, 0) END;
  FOR i := 0 TO MaxDefs-1 DO gDefs[i].used := FALSE END;
  FOR i := 0 TO MaxInst-1 DO gInst[i].active := FALSE; gInst[i].visible := FALSE END;
  gShelfX := 0; gShelfY := 0; gShelfH := 0; gNextSlot := 0;
  gDraw := 0; gDisplay := 0; gScrollX := 0; gScrollY := 0; gScrollXR := 0.0; gScrollYR := 0.0;
  gAtlasDirty := TRUE; gSPalDirty := TRUE;
  RETURN ShaderView.Startup()
END Startup;

PROCEDURE Attach (hwnd: ADDRESS; worldW, worldH, viewW, viewH, surfW, surfH: CARDINAL): BOOLEAN;
BEGIN
  IF (worldW = 0) OR (worldH = 0) OR (worldW > MaxWorldW) OR (worldH > MaxWorldH) THEN RETURN FALSE END;
  IF (viewW = 0) OR (viewH = 0) OR (viewW > worldW) OR (viewH > worldH) THEN RETURN FALSE END;
  gFbW := VAL(INTEGER, worldW); gFbH := VAL(INTEGER, worldH);
  gFbWR := VAL(REAL, worldW); gFbHR := VAL(REAL, worldH);
  gViewW := VAL(INTEGER, viewW); gViewH := VAL(INTEGER, viewH);
  gViewWR := VAL(REAL, viewW); gViewHR := VAL(REAL, viewH);
  IF NOT ShaderView.Attach(hwnd, surfW, surfH) THEN RETURN FALSE END;
  IF NOT ShaderView.SetShader(LutShader, SIZE(gCB)) THEN RETURN FALSE END;
  IF NOT ShaderView.BindTexture(0, worldW, worldH, 62) THEN RETURN FALSE END;
  IF NOT ShaderView.BindTexture(1, 256, 1, 87) THEN RETURN FALSE END;
  IF NOT ShaderView.BindTexture(2, 16, viewH, 87) THEN RETURN FALSE END;
  IF NOT ShaderView.InitSprites(AtlasW, AtlasH, 16, MaxSlots, MaxInst*6) THEN RETURN FALSE END;
  RETURN TRUE
END Attach;

BEGIN
  gFbW := 0; gFbH := 0; gFbWR := 1.0; gFbHR := 1.0;
  gViewW := 0; gViewH := 0; gViewWR := 1.0; gViewHR := 1.0;
  gScrollX := 0; gScrollY := 0; gScrollXR := 0.0; gScrollYR := 0.0;
  gDraw := 0; gDisplay := 0;
  gShelfX := 0; gShelfY := 0; gShelfH := 0; gNextSlot := 0;
  gAtlasDirty := TRUE; gSPalDirty := TRUE
END GameViewGpu.
