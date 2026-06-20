IMPLEMENTATION MODULE GameView;

(* Indexed-colour retro surface. Per instance: fb^ holds one palette INDEX (a
   BYTE) per pixel, row-major top-down, in a w x h framebuffer; pal maps index ->
   0x00RRGGBB; Present() resolves fb^ through pal into rgba^ at `scale`x
   (nearest-neighbour, chunky pixels) and ships it with the same 32-bpp top-down
   DIB blit RasterView uses. Sprites (spr) are small indexed bitmaps with one
   transparent index that Blit skips. Index 255 is the transparent key for
   SpriteRows.

   S3 (PaneShell): instanced. The big buffers (index framebuffer ~256 KiB,
   scaled RGBA ~4 MiB) are heap-allocated per instance (off module globals — the
   §0.4 mandate); the 5x7 font table is read-only and stays shared. gActive
   points at the current instance (never NIL); an eager default backs the legacy
   singleton API, so gameview_demo behaves exactly as before. *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST, SIZE;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM Graphics_Gdi IMPORT GetDC, ReleaseDC, SetDIBitsToDevice, BITMAPINFOHEADER;

CONST
  MaxIdxW  = 640;  MaxIdxH = 400;  MaxIdx  = MaxIdxW * MaxIdxH;   (* framebuffer cap *)
  MaxSurfW = 1280; MaxSurfH = 800; MaxSurf = MaxSurfW * MaxSurfH; (* presented (scaled) cap *)
  MaxSprites = 128;
  MaxSprDim  = 64;  MaxSprPix = MaxSprDim * MaxSprDim;
  TransKey   = 255;                                              (* '.' in SpriteRows *)

TYPE
  Sprite = RECORD
    used:  BOOLEAN;
    w, h:  CARDINAL;
    trans: CARDINAL;
    px:    ARRAY [0..MaxSprPix-1] OF BYTE;
  END;

  PFb   = POINTER TO ARRAY [0..MaxIdx-1]  OF BYTE;        (* index framebuffer — heap *)
  PSurf = POINTER TO ARRAY [0..MaxSurf-1] OF CARDINAL32;  (* scaled present buffer — heap *)

  GInstRec = RECORD
    fb:     PFb;                                 (* one palette index per pixel *)
    rgba:   PSurf;                               (* resolved, scaled present buffer *)
    pal:    ARRAY [0..255] OF CARDINAL32;        (* 0x00RRGGBB per index *)
    spr:    ARRAY [0..MaxSprites-1] OF Sprite;
    w, h:   INTEGER;                             (* framebuffer size in indices *)
    scale:  CARDINAL;
    hwnd:   ADDRESS;
    bmi:    BITMAPINFOHEADER;                    (* describes the scaled RGBA surface *)
    ready:  BOOLEAN;
  END;
  GInstPtr = POINTER TO GInstRec;

VAR
  gActive, gDefault: GInstPtr;
  gFontReady: BOOLEAN;
  gGlyph: ARRAY [0..127] OF ARRAY [0..6] OF CARDINAL;   (* 5x7 font, bit 4 = leftmost — SHARED *)
  BV:     ARRAY [0..4] OF CARDINAL;                     (* column bit values 16..1 — SHARED *)

PROCEDURE Width  (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gActive^.w) END Width;
PROCEDURE Height (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gActive^.h) END Height;

PROCEDURE IAbs (a: INTEGER): INTEGER; BEGIN IF a < 0 THEN RETURN -a ELSE RETURN a END END IAbs;

(* ---- palette ----------------------------------------------------------- *)

PROCEDURE SetColour (index, rgb: CARDINAL);
BEGIN
  IF index <= 255 THEN gActive^.pal[index] := VAL(CARDINAL32, rgb BAND 0FFFFFFH) END
END SetColour;

PROCEDURE SetRGB (index, r, g, b: CARDINAL);
BEGIN
  SetColour(index, ((r BAND 0FFH) * 65536) + ((g BAND 0FFH) * 256) + (b BAND 0FFH))
END SetRGB;

PROCEDURE Colour (index: CARDINAL): CARDINAL;
BEGIN
  IF index <= 255 THEN RETURN VAL(CARDINAL, gActive^.pal[index]) ELSE RETURN 0 END
END Colour;

PROCEDURE LoadDefaultPalette;
BEGIN
  SetColour(0,  000000H); SetColour(1,  0000AAH); SetColour(2,  000AA00H); SetColour(3,  00AAAAH);
  SetColour(4,  0AA0000H); SetColour(5,  0AA00AAH); SetColour(6,  0AA5500H); SetColour(7,  0AAAAAAH);
  SetColour(8,  0555555H); SetColour(9,  05555FFH); SetColour(10, 055FF55H); SetColour(11, 055FFFFH);
  SetColour(12, 0FF5555H); SetColour(13, 0FF55FFH); SetColour(14, 0FFFF55H); SetColour(15, 0FFFFFFH)
END LoadDefaultPalette;

PROCEDURE CyclePalette (lo, hi: CARDINAL);            (* rotate lo..hi up by one entry *)
  VAR i: CARDINAL; tmp: CARDINAL32;
BEGIN
  IF (hi > 255) OR (lo >= hi) THEN RETURN END;
  tmp := gActive^.pal[lo];
  FOR i := lo TO hi-1 DO gActive^.pal[i] := gActive^.pal[i+1] END;
  gActive^.pal[hi] := tmp
END CyclePalette;

(* ---- indexed drawing (all clipped to the framebuffer) ------------------ *)

PROCEDURE Pset (x, y: INTEGER; index: CARDINAL);
BEGIN
  IF (x >= 0) AND (x < gActive^.w) AND (y >= 0) AND (y < gActive^.h) THEN
    gActive^.fb^[VAL(CARDINAL, y * gActive^.w + x)] := VAL(BYTE, index BAND 0FFH)
  END
END Pset;

PROCEDURE Pget (x, y: INTEGER): CARDINAL;
BEGIN
  IF (x >= 0) AND (x < gActive^.w) AND (y >= 0) AND (y < gActive^.h) THEN
    RETURN VAL(CARDINAL, gActive^.fb^[VAL(CARDINAL, y * gActive^.w + x)]) BAND 0FFH
  END;
  RETURN 0
END Pget;

PROCEDURE Cls (index: CARDINAL);
  VAR i, n: CARDINAL; v: BYTE;
BEGIN
  v := VAL(BYTE, index BAND 0FFH);
  n := VAL(CARDINAL, gActive^.w * gActive^.h); i := 0;
  WHILE i < n DO gActive^.fb^[i] := v; INC(i) END
END Cls;

PROCEDURE HLine (x, y, len: INTEGER; index: CARDINAL);
  VAR i: INTEGER;
BEGIN i := 0; WHILE i < len DO Pset(x + i, y, index); INC(i) END END HLine;

PROCEDURE VLine (x, y, len: INTEGER; index: CARDINAL);
  VAR i: INTEGER;
BEGIN i := 0; WHILE i < len DO Pset(x, y + i, index); INC(i) END END VLine;

PROCEDURE FillRect (x, y, w, h: INTEGER; index: CARDINAL);
  VAR j: INTEGER;
BEGIN j := 0; WHILE j < h DO HLine(x, y + j, w, index); INC(j) END END FillRect;

PROCEDURE Rect (x, y, w, h: INTEGER; index: CARDINAL);
BEGIN
  HLine(x, y, w, index); HLine(x, y + h - 1, w, index);
  VLine(x, y, h, index); VLine(x + w - 1, y, h, index)
END Rect;

PROCEDURE Line (x0, y0, x1, y1: INTEGER; index: CARDINAL);
  VAR dx, dy, sx, sy, err, e2: INTEGER;
BEGIN
  dx := IAbs(x1 - x0); dy := -IAbs(y1 - y0);
  IF x0 < x1 THEN sx := 1 ELSE sx := -1 END;
  IF y0 < y1 THEN sy := 1 ELSE sy := -1 END;
  err := dx + dy;
  LOOP
    Pset(x0, y0, index);
    IF (x0 = x1) AND (y0 = y1) THEN EXIT END;
    e2 := 2 * err;
    IF e2 >= dy THEN err := err + dy; x0 := x0 + sx END;
    IF e2 <= dx THEN err := err + dx; y0 := y0 + sy END
  END
END Line;

PROCEDURE Disc (cx, cy, r: INTEGER; index: CARDINAL);
  VAR dy, span: INTEGER;
BEGIN
  dy := -r;
  WHILE dy <= r DO
    span := 0;
    WHILE span * span + dy * dy <= r * r DO INC(span) END;
    HLine(cx - span + 1, cy + dy, 2 * span - 1, index);
    INC(dy)
  END
END Disc;

PROCEDURE Circle (cx, cy, r: INTEGER; index: CARDINAL);
  VAR x, y, err: INTEGER;
BEGIN
  x := -r; y := 0; err := 2 - 2 * r;
  REPEAT
    Pset(cx - x, cy + y, index); Pset(cx - y, cy - x, index);
    Pset(cx + x, cy - y, index); Pset(cx + y, cy + x, index);
    r := err;
    IF r <= y THEN INC(y); err := err + y * 2 + 1 END;
    IF (r > x) OR (err > y) THEN INC(x); err := err + x * 2 + 1 END
  UNTIL x >= 0
END Circle;

(* ---- 5x7 bitmap font (1 index per glyph pixel) ------------------------- *)

PROCEDURE Upper (ch: CHAR): CHAR;
BEGIN
  IF (ch >= 'a') AND (ch <= 'z') THEN RETURN CHR(ORD(ch) - 32) ELSE RETURN ch END
END Upper;

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
          IF (mask BAND BV[col]) # 0 THEN
            Pset(px + VAL(INTEGER, col), y + VAL(INTEGER, row), index)
          END
        END
      END
    END;
    px := px + 6; INC(i)
  END
END Text;

(* ---- sprites ----------------------------------------------------------- *)

(* map a SpriteRows char to a palette index, or TransKey for transparent *)
PROCEDURE RowIndex (ch: CHAR): CARDINAL;
BEGIN
  IF (ch >= '0') AND (ch <= '9') THEN RETURN ORD(ch) - ORD('0') END;
  IF (ch >= 'A') AND (ch <= 'F') THEN RETURN ORD(ch) - ORD('A') + 10 END;
  IF (ch >= 'a') AND (ch <= 'f') THEN RETURN ORD(ch) - ORD('a') + 10 END;
  RETURN TransKey                                    (* '.', ' ', anything else *)
END RowIndex;

PROCEDURE ClearSprite (id: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO MaxSprPix-1 DO gActive^.spr[id].px[i] := VAL(BYTE, TransKey) END
END ClearSprite;

PROCEDURE SpriteRows (id: CARDINAL; rows: ARRAY OF CHAR): BOOLEAN;
  VAR i, n, w, col, row: CARDINAL; ch: CHAR;
BEGIN
  IF id >= MaxSprites THEN RETURN FALSE END;
  n := 0; WHILE (n <= HIGH(rows)) AND (rows[n] # 0C) DO INC(n) END;
  IF n = 0 THEN RETURN FALSE END;
  w := 0; WHILE (w < n) AND (rows[w] # '/') DO INC(w) END;   (* first row's width *)
  IF (w = 0) OR (w > MaxSprDim) THEN RETURN FALSE END;
  ClearSprite(id);
  col := 0; row := 0;
  FOR i := 0 TO n-1 DO
    ch := rows[i];
    IF ch = '/' THEN
      INC(row); col := 0
    ELSE
      IF (row < MaxSprDim) AND (col < w) THEN
        gActive^.spr[id].px[row*w+col] := VAL(BYTE, RowIndex(ch))
      END;
      INC(col)
    END
  END;
  IF row+1 > MaxSprDim THEN RETURN FALSE END;
  gActive^.spr[id].used := TRUE; gActive^.spr[id].w := w; gActive^.spr[id].h := row+1; gActive^.spr[id].trans := TransKey;
  RETURN TRUE
END SpriteRows;

PROCEDURE DefineSprite (id, w, h: CARDINAL; data: ARRAY OF CHAR; transparent: CARDINAL): BOOLEAN;
  VAR i, n: CARDINAL;
BEGIN
  IF (id >= MaxSprites) OR (w = 0) OR (h = 0) OR (w > MaxSprDim) OR (h > MaxSprDim) THEN RETURN FALSE END;
  n := w * h;
  IF n > MaxSprPix THEN RETURN FALSE END;
  FOR i := 0 TO n-1 DO
    IF i <= HIGH(data) THEN gActive^.spr[id].px[i] := VAL(BYTE, ORD(data[i]) BAND 0FFH)
    ELSE gActive^.spr[id].px[i] := VAL(BYTE, transparent BAND 0FFH) END
  END;
  gActive^.spr[id].used := TRUE; gActive^.spr[id].w := w; gActive^.spr[id].h := h; gActive^.spr[id].trans := transparent BAND 0FFH;
  RETURN TRUE
END DefineSprite;

PROCEDURE SpriteWidth  (id: CARDINAL): CARDINAL;
BEGIN IF (id < MaxSprites) AND gActive^.spr[id].used THEN RETURN gActive^.spr[id].w ELSE RETURN 0 END END SpriteWidth;
PROCEDURE SpriteHeight (id: CARDINAL): CARDINAL;
BEGIN IF (id < MaxSprites) AND gActive^.spr[id].used THEN RETURN gActive^.spr[id].h ELSE RETURN 0 END END SpriteHeight;

PROCEDURE Blit (id: CARDINAL; x, y: INTEGER);
  VAR sy, sx, v, w: CARDINAL;
BEGIN
  IF (id >= MaxSprites) OR NOT gActive^.spr[id].used THEN RETURN END;
  w := gActive^.spr[id].w;
  FOR sy := 0 TO gActive^.spr[id].h-1 DO
    FOR sx := 0 TO w-1 DO
      v := VAL(CARDINAL, gActive^.spr[id].px[sy*w+sx]) BAND 0FFH;
      IF v # gActive^.spr[id].trans THEN Pset(x + VAL(INTEGER, sx), y + VAL(INTEGER, sy), v) END
    END
  END
END Blit;

PROCEDURE BlitFlip (id: CARDINAL; x, y: INTEGER; flipX, flipY: BOOLEAN);
  VAR sy, sx, srcx, srcy, v, w, h: CARDINAL;
BEGIN
  IF (id >= MaxSprites) OR NOT gActive^.spr[id].used THEN RETURN END;
  w := gActive^.spr[id].w; h := gActive^.spr[id].h;
  FOR sy := 0 TO h-1 DO
    FOR sx := 0 TO w-1 DO
      IF flipX THEN srcx := w-1-sx ELSE srcx := sx END;
      IF flipY THEN srcy := h-1-sy ELSE srcy := sy END;
      v := VAL(CARDINAL, gActive^.spr[id].px[srcy*w+srcx]) BAND 0FFH;
      IF v # gActive^.spr[id].trans THEN Pset(x + VAL(INTEGER, sx), y + VAL(INTEGER, sy), v) END
    END
  END
END BlitFlip;

PROCEDURE BlitScale (id: CARDINAL; x, y, w, h: INTEGER);
  VAR dy, dx, sx, sy: INTEGER; sw, sh, v: CARDINAL;
BEGIN
  IF (id >= MaxSprites) OR NOT gActive^.spr[id].used OR (w <= 0) OR (h <= 0) THEN RETURN END;
  sw := gActive^.spr[id].w; sh := gActive^.spr[id].h;
  dy := 0;
  WHILE dy < h DO
    sy := VAL(INTEGER, (VAL(CARDINAL, dy) * sh) DIV VAL(CARDINAL, h));
    dx := 0;
    WHILE dx < w DO
      sx := VAL(INTEGER, (VAL(CARDINAL, dx) * sw) DIV VAL(CARDINAL, w));
      v := VAL(CARDINAL, gActive^.spr[id].px[VAL(CARDINAL, sy) * sw + VAL(CARDINAL, sx)]) BAND 0FFH;
      IF v # gActive^.spr[id].trans THEN Pset(x + dx, y + dy, v) END;
      INC(dx)
    END;
    INC(dy)
  END
END BlitScale;

(* ---- present ----------------------------------------------------------- *)

PROCEDURE Present;
  VAR hdc: ADDRESS; r: INTEGER;
      sy, sx, py, qx, surfW, surfH, w, dst: CARDINAL; c: CARDINAL32;
BEGIN
  IF NOT gActive^.ready THEN RETURN END;
  w := VAL(CARDINAL, gActive^.w);
  surfW := w * gActive^.scale; surfH := VAL(CARDINAL, gActive^.h) * gActive^.scale;
  FOR sy := 0 TO VAL(CARDINAL, gActive^.h)-1 DO
    FOR sx := 0 TO w-1 DO
      c := gActive^.pal[VAL(CARDINAL, gActive^.fb^[sy*w+sx]) BAND 0FFH];
      FOR py := 0 TO gActive^.scale-1 DO
        dst := (sy*gActive^.scale+py) * surfW + sx*gActive^.scale;
        FOR qx := 0 TO gActive^.scale-1 DO gActive^.rgba^[dst+qx] := c END
      END
    END
  END;
  hdc := GetDC(gActive^.hwnd);
  r := SetDIBitsToDevice(hdc, 0, 0, surfW, surfH, 0, 0, 0, surfH, ADR(gActive^.rgba^), ADR(gActive^.bmi), 0);
  r := ReleaseDC(gActive^.hwnd, hdc)
END Present;

(* ---- init -------------------------------------------------------------- *)

PROCEDURE Attach (hwnd: ADDRESS; w, h, scale: CARDINAL): BOOLEAN;
BEGIN
  IF (w = 0) OR (h = 0) OR (scale = 0) OR (scale > 8) THEN RETURN FALSE END;
  IF (w > MaxIdxW) OR (h > MaxIdxH) THEN RETURN FALSE END;
  IF (w * scale > MaxSurfW) OR (h * scale > MaxSurfH) THEN RETURN FALSE END;
  gActive^.hwnd := hwnd; gActive^.w := VAL(INTEGER, w); gActive^.h := VAL(INTEGER, h); gActive^.scale := scale;
  gActive^.bmi.biSize := 40;
  gActive^.bmi.biWidth := VAL(INTEGER32, w * scale);
  gActive^.bmi.biHeight := -VAL(INTEGER32, h * scale);     (* negative = top-down *)
  gActive^.bmi.biPlanes := 1;
  gActive^.bmi.biBitCount := 32;
  gActive^.bmi.biCompression := 0;                         (* BI_RGB *)
  gActive^.bmi.biSizeImage := 0;
  gActive^.bmi.biXPelsPerMeter := 0; gActive^.bmi.biYPelsPerMeter := 0;
  gActive^.bmi.biClrUsed := 0; gActive^.bmi.biClrImportant := 0;
  gActive^.ready := TRUE;
  RETURN TRUE
END Attach;

(* ---- font table (5x7, shared shape with RasterView) -------------------- *)

PROCEDURE RowBits (r: ARRAY OF CHAR): CARDINAL;
  VAR i, v: CARDINAL;
BEGIN
  v := 0;
  FOR i := 0 TO 4 DO
    IF (i <= HIGH(r)) AND (r[i] = 'X') THEN v := v + BV[i] END
  END;
  RETURN v
END RowBits;

PROCEDURE G (ch: CHAR; r0, r1, r2, r3, r4, r5, r6: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := ORD(ch);
  IF i > 127 THEN RETURN END;
  gGlyph[i][0] := RowBits(r0); gGlyph[i][1] := RowBits(r1); gGlyph[i][2] := RowBits(r2);
  gGlyph[i][3] := RowBits(r3); gGlyph[i][4] := RowBits(r4); gGlyph[i][5] := RowBits(r5);
  gGlyph[i][6] := RowBits(r6)
END G;

PROCEDURE BuildFont;
  VAR i, j: CARDINAL;
BEGIN
  BV[0] := 16; BV[1] := 8; BV[2] := 4; BV[3] := 2; BV[4] := 1;
  FOR i := 0 TO 127 DO FOR j := 0 TO 6 DO gGlyph[i][j] := 0 END END;
  G(' ', ".....", ".....", ".....", ".....", ".....", ".....", ".....");
  G('0', ".XXX.", "X...X", "X..XX", "X.X.X", "XX..X", "X...X", ".XXX.");
  G('1', "..X..", ".XX..", "..X..", "..X..", "..X..", "..X..", ".XXX.");
  G('2', ".XXX.", "X...X", "....X", "..XX.", ".X...", "X....", "XXXXX");
  G('3', "XXXXX", "....X", "...X.", "..XX.", "....X", "X...X", ".XXX.");
  G('4', "...X.", "..XX.", ".X.X.", "X..X.", "XXXXX", "...X.", "...X.");
  G('5', "XXXXX", "X....", "XXXX.", "....X", "....X", "X...X", ".XXX.");
  G('6', "..XX.", ".X...", "X....", "XXXX.", "X...X", "X...X", ".XXX.");
  G('7', "XXXXX", "....X", "...X.", "..X..", ".X...", ".X...", ".X...");
  G('8', ".XXX.", "X...X", "X...X", ".XXX.", "X...X", "X...X", ".XXX.");
  G('9', ".XXX.", "X...X", "X...X", ".XXXX", "....X", "...X.", ".XX..");
  G('A', ".XXX.", "X...X", "X...X", "X...X", "XXXXX", "X...X", "X...X");
  G('B', "XXXX.", "X...X", "X...X", "XXXX.", "X...X", "X...X", "XXXX.");
  G('C', ".XXX.", "X...X", "X....", "X....", "X....", "X...X", ".XXX.");
  G('D', "XXXX.", "X...X", "X...X", "X...X", "X...X", "X...X", "XXXX.");
  G('E', "XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "XXXXX");
  G('F', "XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "X....");
  G('G', ".XXX.", "X...X", "X....", "X.XXX", "X...X", "X...X", ".XXXX");
  G('H', "X...X", "X...X", "X...X", "XXXXX", "X...X", "X...X", "X...X");
  G('I', ".XXX.", "..X..", "..X..", "..X..", "..X..", "..X..", ".XXX.");
  G('J', "..XXX", "...X.", "...X.", "...X.", "X..X.", "X..X.", ".XX..");
  G('K', "X...X", "X..X.", "X.X..", "XX...", "X.X..", "X..X.", "X...X");
  G('L', "X....", "X....", "X....", "X....", "X....", "X....", "XXXXX");
  G('M', "X...X", "XX.XX", "X.X.X", "X.X.X", "X...X", "X...X", "X...X");
  G('N', "X...X", "XX..X", "X.X.X", "X..XX", "X...X", "X...X", "X...X");
  G('O', ".XXX.", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX.");
  G('P', "XXXX.", "X...X", "X...X", "XXXX.", "X....", "X....", "X....");
  G('Q', ".XXX.", "X...X", "X...X", "X...X", "X.X.X", "X..X.", ".XX.X");
  G('R', "XXXX.", "X...X", "X...X", "XXXX.", "X.X..", "X..X.", "X...X");
  G('S', ".XXXX", "X....", "X....", ".XXX.", "....X", "....X", "XXXX.");
  G('T', "XXXXX", "..X..", "..X..", "..X..", "..X..", "..X..", "..X..");
  G('U', "X...X", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX.");
  G('V', "X...X", "X...X", "X...X", "X...X", "X...X", ".X.X.", "..X..");
  G('W', "X...X", "X...X", "X...X", "X.X.X", "X.X.X", "XX.XX", "X...X");
  G('X', "X...X", "X...X", ".X.X.", "..X..", ".X.X.", "X...X", "X...X");
  G('Y', "X...X", "X...X", ".X.X.", "..X..", "..X..", "..X..", "..X..");
  G('Z', "XXXXX", "....X", "...X.", "..X..", ".X...", "X....", "XXXXX");
  G('.', ".....", ".....", ".....", ".....", ".....", ".XX..", ".XX..");
  G(',', ".....", ".....", ".....", ".....", ".XX..", ".XX..", ".X...");
  G('-', ".....", ".....", ".....", "XXXXX", ".....", ".....", ".....");
  G('+', ".....", "..X..", "..X..", "XXXXX", "..X..", "..X..", ".....");
  G(':', ".....", ".XX..", ".XX..", ".....", ".XX..", ".XX..", ".....");
  G('!', "..X..", "..X..", "..X..", "..X..", "..X..", ".....", "..X..");
  G('/', "....X", "...X.", "..X..", "..X..", ".X...", "X....", "X....");
  G('(', "..X..", ".X...", "X....", "X....", "X....", ".X...", "..X..");
  G(')', "..X..", "...X.", "....X", "....X", "....X", "...X.", "..X..")
END BuildFont;

(* ---- instancing (S3) --------------------------------------------------- *)

PROCEDURE InitGInst (p: GInstPtr);
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO 255 DO p^.pal[i] := VAL(CARDINAL32, 0) END;
  p^.pal[0]  := VAL(CARDINAL32, 000000H);  p^.pal[1]  := VAL(CARDINAL32, 0000AAH);
  p^.pal[2]  := VAL(CARDINAL32, 000AA00H); p^.pal[3]  := VAL(CARDINAL32, 00AAAAH);
  p^.pal[4]  := VAL(CARDINAL32, 0AA0000H); p^.pal[5]  := VAL(CARDINAL32, 0AA00AAH);
  p^.pal[6]  := VAL(CARDINAL32, 0AA5500H); p^.pal[7]  := VAL(CARDINAL32, 0AAAAAAH);
  p^.pal[8]  := VAL(CARDINAL32, 0555555H); p^.pal[9]  := VAL(CARDINAL32, 05555FFH);
  p^.pal[10] := VAL(CARDINAL32, 055FF55H); p^.pal[11] := VAL(CARDINAL32, 055FFFFH);
  p^.pal[12] := VAL(CARDINAL32, 0FF5555H); p^.pal[13] := VAL(CARDINAL32, 0FF55FFH);
  p^.pal[14] := VAL(CARDINAL32, 0FFFF55H); p^.pal[15] := VAL(CARDINAL32, 0FFFFFFH);
  FOR i := 0 TO MaxSprites-1 DO p^.spr[i].used := FALSE END;
  p^.w := 0; p^.h := 0; p^.scale := 1; p^.hwnd := NIL; p^.ready := FALSE
END InitGInst;

PROCEDURE AllocGInst (): GInstPtr;
  VAR a: ADDRESS; p: GInstPtr;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(GInstRec)); p := CAST(GInstPtr, a);
  a := NIL; ALLOCATE(a, MaxIdx);          (* index framebuffer, 1 byte/pixel *)
  p^.fb := CAST(PFb, a);
  a := NIL; ALLOCATE(a, MaxSurf * 4);     (* scaled RGBA present buffer *)
  p^.rgba := CAST(PSurf, a);
  InitGInst(p);
  RETURN p
END AllocGInst;

PROCEDURE EnsureFont;
BEGIN IF NOT gFontReady THEN BuildFont; gFontReady := TRUE END END EnsureFont;

PROCEDURE Create (w, h, scale: CARDINAL): Instance;
  VAR p: GInstPtr;
BEGIN
  EnsureFont;
  IF w > MaxIdxW THEN w := MaxIdxW ELSIF w = 0 THEN w := 1 END;
  IF h > MaxIdxH THEN h := MaxIdxH ELSIF h = 0 THEN h := 1 END;
  IF scale > 8 THEN scale := 8 ELSIF scale = 0 THEN scale := 1 END;
  p := AllocGInst();
  p^.w := VAL(INTEGER, w); p^.h := VAL(INTEGER, h); p^.scale := scale;
  RETURN CAST(Instance, p)
END Create;

PROCEDURE Use (i: Instance);
BEGIN
  IF i = NIL THEN gActive := gDefault ELSE gActive := CAST(GInstPtr, i) END
END Use;

PROCEDURE Free (VAR i: Instance);
  VAR p: GInstPtr; b: ADDRESS;
BEGIN
  IF i # NIL THEN
    p := CAST(GInstPtr, i);
    IF p = gActive THEN gActive := gDefault END;
    IF p # gDefault THEN
      b := p^.fb;   DEALLOCATE(b, MaxIdx);
      b := p^.rgba; DEALLOCATE(b, MaxSurf * 4);
      DEALLOCATE(i, SIZE(GInstRec))
    END;
    i := NIL
  END
END Free;

PROCEDURE IndexAt (i: Instance; x, y: CARDINAL): CARDINAL;
  VAR p: GInstPtr; xi, yi: INTEGER;
BEGIN
  IF i = NIL THEN RETURN 0 END;
  p := CAST(GInstPtr, i);
  xi := VAL(INTEGER, x); yi := VAL(INTEGER, y);
  IF (xi < p^.w) AND (yi < p^.h) THEN
    RETURN VAL(CARDINAL, p^.fb^[VAL(CARDINAL, yi * p^.w + xi)]) BAND 0FFH
  END;
  RETURN 0
END IndexAt;

PROCEDURE Startup (): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  EnsureFont;
  FOR i := 0 TO 255 DO gActive^.pal[i] := VAL(CARDINAL32, 0) END;
  LoadDefaultPalette;
  FOR i := 0 TO MaxSprites-1 DO gActive^.spr[i].used := FALSE END;
  gActive^.ready := FALSE;
  RETURN TRUE
END Startup;

BEGIN
  gFontReady := FALSE;
  gDefault := AllocGInst();
  gActive  := gDefault
END GameView.
