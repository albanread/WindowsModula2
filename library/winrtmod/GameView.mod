IMPLEMENTATION MODULE GameView;

(* Indexed-colour retro surface. gFb holds one palette INDEX (a BYTE) per pixel,
   row-major top-down, in a gW x gH framebuffer. gPal maps index -> 0x00RRGGBB.
   Present() resolves gFb through gPal into gRGBA at `gScale`x (nearest-neighbour,
   chunky pixels) and ships it with the same 32-bpp top-down DIB blit RasterView
   uses. Sprites are small indexed bitmaps (gSpr) with one transparent index that
   Blit skips. Index 255 is reserved as the transparent key for SpriteRows. *)

FROM SYSTEM IMPORT ADDRESS, ADR;
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

VAR
  gFb:    ARRAY [0..MaxIdx-1]  OF BYTE;        (* one palette index per pixel *)
  gRGBA:  ARRAY [0..MaxSurf-1] OF CARDINAL32;  (* resolved, scaled present buffer *)
  gPal:   ARRAY [0..255] OF CARDINAL32;        (* 0x00RRGGBB per index *)
  gSpr:   ARRAY [0..MaxSprites-1] OF Sprite;
  gW, gH: INTEGER;                             (* framebuffer size in indices *)
  gScale: CARDINAL;
  gHwnd:  ADDRESS;
  gBmi:   BITMAPINFOHEADER;                    (* describes the scaled RGBA surface *)
  gReady: BOOLEAN;
  gGlyph: ARRAY [0..127] OF ARRAY [0..6] OF CARDINAL;   (* 5x7 font, bit 4 = leftmost *)
  BV:     ARRAY [0..4] OF CARDINAL;                     (* column bit values 16..1 *)

PROCEDURE Width  (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gW) END Width;
PROCEDURE Height (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gH) END Height;

PROCEDURE IAbs (a: INTEGER): INTEGER; BEGIN IF a < 0 THEN RETURN -a ELSE RETURN a END END IAbs;

(* ---- palette ----------------------------------------------------------- *)

PROCEDURE SetColour (index, rgb: CARDINAL);
BEGIN
  IF index <= 255 THEN gPal[index] := VAL(CARDINAL32, rgb BAND 0FFFFFFH) END
END SetColour;

PROCEDURE SetRGB (index, r, g, b: CARDINAL);
BEGIN
  SetColour(index, ((r BAND 0FFH) * 65536) + ((g BAND 0FFH) * 256) + (b BAND 0FFH))
END SetRGB;

PROCEDURE Colour (index: CARDINAL): CARDINAL;
BEGIN
  IF index <= 255 THEN RETURN VAL(CARDINAL, gPal[index]) ELSE RETURN 0 END
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
  tmp := gPal[lo];
  FOR i := lo TO hi-1 DO gPal[i] := gPal[i+1] END;
  gPal[hi] := tmp
END CyclePalette;

(* ---- indexed drawing (all clipped to the framebuffer) ------------------ *)

PROCEDURE Pset (x, y: INTEGER; index: CARDINAL);
BEGIN
  IF (x >= 0) AND (x < gW) AND (y >= 0) AND (y < gH) THEN
    gFb[VAL(CARDINAL, y * gW + x)] := VAL(BYTE, index BAND 0FFH)
  END
END Pset;

PROCEDURE Pget (x, y: INTEGER): CARDINAL;
BEGIN
  IF (x >= 0) AND (x < gW) AND (y >= 0) AND (y < gH) THEN
    RETURN VAL(CARDINAL, gFb[VAL(CARDINAL, y * gW + x)]) BAND 0FFH
  END;
  RETURN 0
END Pget;

PROCEDURE Cls (index: CARDINAL);
  VAR i, n: CARDINAL; v: BYTE;
BEGIN
  v := VAL(BYTE, index BAND 0FFH);
  n := VAL(CARDINAL, gW * gH); i := 0;
  WHILE i < n DO gFb[i] := v; INC(i) END
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
  FOR i := 0 TO MaxSprPix-1 DO gSpr[id].px[i] := VAL(BYTE, TransKey) END
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
        gSpr[id].px[row*w+col] := VAL(BYTE, RowIndex(ch))
      END;
      INC(col)
    END
  END;
  IF row+1 > MaxSprDim THEN RETURN FALSE END;
  gSpr[id].used := TRUE; gSpr[id].w := w; gSpr[id].h := row+1; gSpr[id].trans := TransKey;
  RETURN TRUE
END SpriteRows;

PROCEDURE DefineSprite (id, w, h: CARDINAL; data: ARRAY OF CHAR; transparent: CARDINAL): BOOLEAN;
  VAR i, n: CARDINAL;
BEGIN
  IF (id >= MaxSprites) OR (w = 0) OR (h = 0) OR (w > MaxSprDim) OR (h > MaxSprDim) THEN RETURN FALSE END;
  n := w * h;
  IF n > MaxSprPix THEN RETURN FALSE END;
  FOR i := 0 TO n-1 DO
    IF i <= HIGH(data) THEN gSpr[id].px[i] := VAL(BYTE, ORD(data[i]) BAND 0FFH)
    ELSE gSpr[id].px[i] := VAL(BYTE, transparent BAND 0FFH) END
  END;
  gSpr[id].used := TRUE; gSpr[id].w := w; gSpr[id].h := h; gSpr[id].trans := transparent BAND 0FFH;
  RETURN TRUE
END DefineSprite;

PROCEDURE SpriteWidth  (id: CARDINAL): CARDINAL;
BEGIN IF (id < MaxSprites) AND gSpr[id].used THEN RETURN gSpr[id].w ELSE RETURN 0 END END SpriteWidth;
PROCEDURE SpriteHeight (id: CARDINAL): CARDINAL;
BEGIN IF (id < MaxSprites) AND gSpr[id].used THEN RETURN gSpr[id].h ELSE RETURN 0 END END SpriteHeight;

PROCEDURE Blit (id: CARDINAL; x, y: INTEGER);
  VAR sy, sx, v, w: CARDINAL;
BEGIN
  IF (id >= MaxSprites) OR NOT gSpr[id].used THEN RETURN END;
  w := gSpr[id].w;
  FOR sy := 0 TO gSpr[id].h-1 DO
    FOR sx := 0 TO w-1 DO
      v := VAL(CARDINAL, gSpr[id].px[sy*w+sx]) BAND 0FFH;
      IF v # gSpr[id].trans THEN Pset(x + VAL(INTEGER, sx), y + VAL(INTEGER, sy), v) END
    END
  END
END Blit;

PROCEDURE BlitFlip (id: CARDINAL; x, y: INTEGER; flipX, flipY: BOOLEAN);
  VAR sy, sx, srcx, srcy, v, w, h: CARDINAL;
BEGIN
  IF (id >= MaxSprites) OR NOT gSpr[id].used THEN RETURN END;
  w := gSpr[id].w; h := gSpr[id].h;
  FOR sy := 0 TO h-1 DO
    FOR sx := 0 TO w-1 DO
      IF flipX THEN srcx := w-1-sx ELSE srcx := sx END;
      IF flipY THEN srcy := h-1-sy ELSE srcy := sy END;
      v := VAL(CARDINAL, gSpr[id].px[srcy*w+srcx]) BAND 0FFH;
      IF v # gSpr[id].trans THEN Pset(x + VAL(INTEGER, sx), y + VAL(INTEGER, sy), v) END
    END
  END
END BlitFlip;

PROCEDURE BlitScale (id: CARDINAL; x, y, w, h: INTEGER);
  VAR dy, dx, sx, sy: INTEGER; sw, sh, v: CARDINAL;
BEGIN
  IF (id >= MaxSprites) OR NOT gSpr[id].used OR (w <= 0) OR (h <= 0) THEN RETURN END;
  sw := gSpr[id].w; sh := gSpr[id].h;
  dy := 0;
  WHILE dy < h DO
    sy := VAL(INTEGER, (VAL(CARDINAL, dy) * sh) DIV VAL(CARDINAL, h));
    dx := 0;
    WHILE dx < w DO
      sx := VAL(INTEGER, (VAL(CARDINAL, dx) * sw) DIV VAL(CARDINAL, w));
      v := VAL(CARDINAL, gSpr[id].px[VAL(CARDINAL, sy) * sw + VAL(CARDINAL, sx)]) BAND 0FFH;
      IF v # gSpr[id].trans THEN Pset(x + dx, y + dy, v) END;
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
  IF NOT gReady THEN RETURN END;
  w := VAL(CARDINAL, gW);
  surfW := w * gScale; surfH := VAL(CARDINAL, gH) * gScale;
  FOR sy := 0 TO VAL(CARDINAL, gH)-1 DO
    FOR sx := 0 TO w-1 DO
      c := gPal[VAL(CARDINAL, gFb[sy*w+sx]) BAND 0FFH];
      FOR py := 0 TO gScale-1 DO
        dst := (sy*gScale+py) * surfW + sx*gScale;
        FOR qx := 0 TO gScale-1 DO gRGBA[dst+qx] := c END
      END
    END
  END;
  hdc := GetDC(gHwnd);
  r := SetDIBitsToDevice(hdc, 0, 0, surfW, surfH, 0, 0, 0, surfH, ADR(gRGBA), ADR(gBmi), 0);
  r := ReleaseDC(gHwnd, hdc)
END Present;

(* ---- init -------------------------------------------------------------- *)

PROCEDURE Attach (hwnd: ADDRESS; w, h, scale: CARDINAL): BOOLEAN;
BEGIN
  IF (w = 0) OR (h = 0) OR (scale = 0) OR (scale > 8) THEN RETURN FALSE END;
  IF (w > MaxIdxW) OR (h > MaxIdxH) THEN RETURN FALSE END;
  IF (w * scale > MaxSurfW) OR (h * scale > MaxSurfH) THEN RETURN FALSE END;
  gHwnd := hwnd; gW := VAL(INTEGER, w); gH := VAL(INTEGER, h); gScale := scale;
  gBmi.biSize := 40;
  gBmi.biWidth := VAL(INTEGER32, w * scale);
  gBmi.biHeight := -VAL(INTEGER32, h * scale);     (* negative = top-down *)
  gBmi.biPlanes := 1;
  gBmi.biBitCount := 32;
  gBmi.biCompression := 0;                         (* BI_RGB *)
  gBmi.biSizeImage := 0;
  gBmi.biXPelsPerMeter := 0; gBmi.biYPelsPerMeter := 0;
  gBmi.biClrUsed := 0; gBmi.biClrImportant := 0;
  gReady := TRUE;
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

PROCEDURE Startup (): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  BuildFont;
  FOR i := 0 TO 255 DO gPal[i] := VAL(CARDINAL32, 0) END;
  LoadDefaultPalette;
  FOR i := 0 TO MaxSprites-1 DO gSpr[i].used := FALSE END;
  gReady := FALSE;
  RETURN TRUE
END Startup;

BEGIN
  gW := 0; gH := 0; gScale := 1; gHwnd := NIL; gReady := FALSE
END GameView.
