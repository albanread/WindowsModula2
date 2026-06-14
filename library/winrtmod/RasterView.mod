IMPLEMENTATION MODULE RasterView;

(* A software RGBA framebuffer. gBuf holds one 0x00RRGGBB word per pixel, row-major
   top-down (row 0 = top). The 32-bpp BI_RGB DIB format reads each word as
   0x00RRGGBB, so Present() and SaveBMP() ship gBuf verbatim — no byte swizzling. *)

FROM SYSTEM IMPORT ADDRESS, ADR;
FROM Graphics_Gdi IMPORT GetDC, ReleaseDC, SetDIBitsToDevice, BITMAPINFOHEADER;
IMPORT StreamFile, IOChan, ChanConsts;

CONST
  MaxW = 1280; MaxH = 800; MaxPix = MaxW * MaxH;

VAR
  gBuf:   ARRAY [0..MaxPix-1] OF CARDINAL32;
  gW, gH: INTEGER;
  gHwnd:  ADDRESS;
  gBmi:   BITMAPINFOHEADER;
  gReady: BOOLEAN;
  gGlyph: ARRAY [0..127] OF ARRAY [0..6] OF CARDINAL;   (* 5x7 font, bit 4 = leftmost *)
  BV:     ARRAY [0..4] OF CARDINAL;                     (* column bit values 16..1 *)

(* ---- low-level pixel access (clipped) ---------------------------------- *)

PROCEDURE Width  (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gW) END Width;
PROCEDURE Height (): CARDINAL; BEGIN RETURN VAL(CARDINAL, gH) END Height;

PROCEDURE Pixel (x, y: INTEGER; rgb: CARDINAL);
BEGIN
  IF (x >= 0) AND (x < gW) AND (y >= 0) AND (y < gH) THEN
    gBuf[VAL(CARDINAL, y * gW + x)] := VAL(CARDINAL32, rgb BAND 0FFFFFFH)
  END
END Pixel;

PROCEDURE Clear (rgb: CARDINAL);
  VAR i, n: CARDINAL; v: CARDINAL32;
BEGIN
  v := VAL(CARDINAL32, rgb BAND 0FFFFFFH);
  n := VAL(CARDINAL, gW * gH); i := 0;
  WHILE i < n DO gBuf[i] := v; INC(i) END
END Clear;

PROCEDURE HLine (x, y, len: INTEGER; rgb: CARDINAL);
  VAR i: INTEGER;
BEGIN i := 0; WHILE i < len DO Pixel(x + i, y, rgb); INC(i) END END HLine;

PROCEDURE VLine (x, y, len: INTEGER; rgb: CARDINAL);
  VAR i: INTEGER;
BEGIN i := 0; WHILE i < len DO Pixel(x, y + i, rgb); INC(i) END END VLine;

PROCEDURE FillRect (x, y, w, h: INTEGER; rgb: CARDINAL);
  VAR j: INTEGER;
BEGIN j := 0; WHILE j < h DO HLine(x, y + j, w, rgb); INC(j) END END FillRect;

PROCEDURE Rect (x, y, w, h: INTEGER; rgb: CARDINAL);
BEGIN
  HLine(x, y, w, rgb); HLine(x, y + h - 1, w, rgb);
  VLine(x, y, h, rgb); VLine(x + w - 1, y, h, rgb)
END Rect;

PROCEDURE IAbs (a: INTEGER): INTEGER; BEGIN IF a < 0 THEN RETURN -a ELSE RETURN a END END IAbs;

PROCEDURE Line (x0, y0, x1, y1: INTEGER; rgb: CARDINAL);
  VAR dx, dy, sx, sy, err, e2: INTEGER;
BEGIN
  dx := IAbs(x1 - x0); dy := -IAbs(y1 - y0);
  IF x0 < x1 THEN sx := 1 ELSE sx := -1 END;
  IF y0 < y1 THEN sy := 1 ELSE sy := -1 END;
  err := dx + dy;
  LOOP
    Pixel(x0, y0, rgb);
    IF (x0 = x1) AND (y0 = y1) THEN EXIT END;
    e2 := 2 * err;
    IF e2 >= dy THEN err := err + dy; x0 := x0 + sx END;
    IF e2 <= dx THEN err := err + dx; y0 := y0 + sy END
  END
END Line;

PROCEDURE ThickLine (x0, y0, x1, y1, t: INTEGER; rgb: CARDINAL);
  VAR i: INTEGER;
BEGIN
  IF t <= 1 THEN Line(x0, y0, x1, y1, rgb); RETURN END;
  (* offset perpendicular-ish: thicken across whichever axis is shorter *)
  i := -(t DIV 2);
  WHILE i <= t DIV 2 DO
    IF IAbs(x1 - x0) >= IAbs(y1 - y0) THEN Line(x0, y0 + i, x1, y1 + i, rgb)
    ELSE Line(x0 + i, y0, x1 + i, y1, rgb) END;
    INC(i)
  END
END ThickLine;

PROCEDURE Disc (cx, cy, r: INTEGER; rgb: CARDINAL);
  VAR dy, span: INTEGER;
BEGIN
  dy := -r;
  WHILE dy <= r DO
    span := 0;
    WHILE span * span + dy * dy <= r * r DO INC(span) END;
    HLine(cx - span + 1, cy + dy, 2 * span - 1, rgb);
    INC(dy)
  END
END Disc;

PROCEDURE Circle (cx, cy, r: INTEGER; rgb: CARDINAL);
  VAR x, y, err: INTEGER;
BEGIN
  x := -r; y := 0; err := 2 - 2 * r;
  REPEAT
    Pixel(cx - x, cy + y, rgb); Pixel(cx - y, cy - x, rgb);
    Pixel(cx + x, cy - y, rgb); Pixel(cx + y, cy + x, rgb);
    r := err;
    IF r <= y THEN INC(y); err := err + y * 2 + 1 END;
    IF (r > x) OR (err > y) THEN INC(x); err := err + x * 2 + 1 END
  UNTIL x >= 0
END Circle;

(* ---- 5x7 bitmap font --------------------------------------------------- *)

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

PROCEDURE Upper (ch: CHAR): CHAR;
BEGIN
  IF (ch >= 'a') AND (ch <= 'z') THEN RETURN CHR(ORD(ch) - 32) ELSE RETURN ch END
END Upper;

PROCEDURE TextWidth (scale: INTEGER; s: ARRAY OF CHAR): INTEGER;
  VAR n: CARDINAL;
BEGIN
  n := 0; WHILE (n <= HIGH(s)) AND (s[n] # 0C) DO INC(n) END;
  RETURN VAL(INTEGER, n) * 6 * scale
END TextWidth;

PROCEDURE Text (x, y, scale: INTEGER; rgb: CARDINAL; s: ARRAY OF CHAR);
  VAR i, col: CARDINAL; row: CARDINAL; cx, mask: CARDINAL; ch: CHAR; px: INTEGER;
BEGIN
  i := 0; px := x;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO
    ch := Upper(s[i]); cx := ORD(ch);
    IF cx <= 127 THEN
      FOR row := 0 TO 6 DO
        mask := gGlyph[cx][row];
        FOR col := 0 TO 4 DO
          IF (mask BAND BV[col]) # 0 THEN
            FillRect(px + VAL(INTEGER, col) * scale, y + VAL(INTEGER, row) * scale, scale, scale, rgb)
          END
        END
      END
    END;
    px := px + 6 * scale; INC(i)
  END
END Text;

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
  G('/', "....X", "...X.", "..X..", "..X..", ".X...", "X....", "X....");
  G('%', "XX..X", "XX.X.", "..X..", ".X...", "X..XX", ".X.XX", ".....");
  G('(', "..X..", ".X...", "X....", "X....", "X....", ".X...", "..X..");
  G(')', "..X..", "...X.", "....X", "....X", "....X", "...X.", "..X..")
END BuildFont;

(* ---- present + export -------------------------------------------------- *)

PROCEDURE Startup (): BOOLEAN;
BEGIN BuildFont; gReady := FALSE; RETURN TRUE END Startup;

PROCEDURE Attach (hwnd: ADDRESS; w, h: CARDINAL): BOOLEAN;
BEGIN
  IF (w > MaxW) OR (h > MaxH) OR (w = 0) OR (h = 0) THEN RETURN FALSE END;
  gHwnd := hwnd; gW := VAL(INTEGER, w); gH := VAL(INTEGER, h);
  gBmi.biSize := 40;
  gBmi.biWidth := VAL(INTEGER32, w);
  gBmi.biHeight := -VAL(INTEGER32, h);            (* negative = top-down *)
  gBmi.biPlanes := 1;
  gBmi.biBitCount := 32;
  gBmi.biCompression := 0;                        (* BI_RGB *)
  gBmi.biSizeImage := 0;
  gBmi.biXPelsPerMeter := 0; gBmi.biYPelsPerMeter := 0;
  gBmi.biClrUsed := 0; gBmi.biClrImportant := 0;
  gReady := TRUE;
  RETURN TRUE
END Attach;

PROCEDURE Present;
  VAR hdc: ADDRESS; r: INTEGER;
BEGIN
  IF NOT gReady THEN RETURN END;
  hdc := GetDC(gHwnd);
  r := SetDIBitsToDevice(hdc, 0, 0, VAL(CARDINAL, gW), VAL(CARDINAL, gH),
                         0, 0, 0, VAL(CARDINAL, gH), ADR(gBuf), ADR(gBmi), 0);
  r := ReleaseDC(gHwnd, hdc)
END Present;

PROCEDURE PutU16 (VAR b: ARRAY OF BYTE; off, v: CARDINAL);
BEGIN
  b[off]   := VAL(BYTE, v BAND 0FFH);
  b[off+1] := VAL(BYTE, (v SHR 8) BAND 0FFH)
END PutU16;

PROCEDURE PutU32 (VAR b: ARRAY OF BYTE; off, v: CARDINAL);
BEGIN
  b[off]   := VAL(BYTE, v BAND 0FFH);
  b[off+1] := VAL(BYTE, (v SHR 8) BAND 0FFH);
  b[off+2] := VAL(BYTE, (v SHR 16) BAND 0FFH);
  b[off+3] := VAL(BYTE, (v SHR 24) BAND 0FFH)
END PutU32;

PROCEDURE SaveBMP (name: ARRAY OF CHAR): BOOLEAN;
  VAR cid: StreamFile.ChanId; res: ChanConsts.OpenResults;
      hdr: ARRAY [0..53] OF BYTE; i, pixBytes, negH: CARDINAL;
BEGIN
  IF NOT gReady THEN RETURN FALSE END;
  StreamFile.Open(cid, name, StreamFile.write + StreamFile.raw, res);
  IF res # ChanConsts.opened THEN RETURN FALSE END;
  pixBytes := VAL(CARDINAL, gW * gH) * 4;
  FOR i := 0 TO 53 DO hdr[i] := VAL(BYTE, 0) END;
  hdr[0] := VAL(BYTE, 42H); hdr[1] := VAL(BYTE, 4DH);       (* 'BM' *)
  PutU32(hdr, 2, 54 + pixBytes);                            (* bfSize *)
  PutU32(hdr, 10, 54);                                      (* bfOffBits *)
  PutU32(hdr, 14, 40);                                      (* biSize *)
  PutU32(hdr, 18, VAL(CARDINAL, gW));                       (* biWidth *)
  negH := 4294967296 - VAL(CARDINAL, gH);                   (* biHeight = -gH (top-down) *)
  PutU32(hdr, 22, negH);
  PutU16(hdr, 26, 1);                                       (* planes *)
  PutU16(hdr, 28, 32);                                      (* bpp *)
  PutU32(hdr, 30, 0);                                       (* BI_RGB *)
  PutU32(hdr, 34, pixBytes);                                (* biSizeImage *)
  IOChan.RawWrite(cid, ADR(hdr), 54);
  IOChan.RawWrite(cid, ADR(gBuf), pixBytes);
  StreamFile.Close(cid);
  RETURN TRUE
END SaveBMP;

BEGIN
  gW := 0; gH := 0; gHwnd := NIL; gReady := FALSE
END RasterView.
