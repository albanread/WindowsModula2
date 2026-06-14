IMPLEMENTATION MODULE Chart;

FROM RasterView IMPORT Pixel, FillRect, Rect, HLine, VLine, ThickLine,
  Disc, Circle, Text, TextWidth;
IMPORT RealStr;
FROM RealMath IMPORT arctan;

CONST
  PI = 3.14159265358979;
  GridCol = 0DDDDDDH;

(* ---- helpers ----------------------------------------------------------- *)

PROCEDURE MaxReal (VAR v: ARRAY OF REAL; n: CARDINAL): REAL;
  VAR i: CARDINAL; m: REAL;
BEGIN
  m := 0.0;
  FOR i := 0 TO n-1 DO IF v[i] > m THEN m := v[i] END END;
  RETURN m
END MaxReal;

PROCEDURE SumReal (VAR v: ARRAY OF REAL; n: CARDINAL): REAL;
  VAR i: CARDINAL; s: REAL;
BEGIN s := 0.0; FOR i := 0 TO n-1 DO s := s + v[i] END; RETURN s END SumReal;

(* round `m` up to the next 1/2/5 x 10^k "nice" axis maximum *)
PROCEDURE NiceTop (m: REAL): REAL;
  VAR p: REAL;
BEGIN
  IF m <= 0.0 THEN RETURN 1.0 END;
  p := 1.0;
  WHILE p * 10.0 <= m DO p := p * 10.0 END;
  IF    m <= p       THEN RETURN p
  ELSIF m <= 2.0 * p THEN RETURN 2.0 * p
  ELSIF m <= 5.0 * p THEN RETURN 5.0 * p
  ELSE RETURN 10.0 * p END
END NiceTop;

PROCEDURE Trim (VAR s: ARRAY OF CHAR);
  VAR i, dot, last: CARDINAL; hasDot: BOOLEAN;
BEGIN
  i := 0; hasDot := FALSE; dot := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO IF s[i] = '.' THEN hasDot := TRUE; dot := i END; INC(i) END;
  IF NOT hasDot THEN RETURN END;
  last := i;
  WHILE (last > dot + 1) AND (s[last-1] = '0') DO DEC(last) END;
  IF last = dot + 1 THEN last := dot END;
  s[last] := 0C
END Trim;

PROCEDURE FmtNum (v: REAL; VAR s: ARRAY OF CHAR);
BEGIN RealStr.RealToFixed(v, 1, s); Trim(s) END FmtNum;

PROCEDURE PixOf (val, top: REAL; plotH: INTEGER): INTEGER;
BEGIN
  IF top <= 0.0 THEN RETURN 0 END;
  RETURN VAL(INTEGER, TRUNC((val / top) * VAL(REAL, plotH)))
END PixOf;

(* draw the panel + value axis + gridlines + title; return the plot rectangle *)
PROCEDURE Frame (px, py, pw, ph: INTEGER; top: REAL; title: ARRAY OF CHAR;
                 axisCol, bgCol: CARDINAL; VAR plotX, plotY, plotW, plotH: INTEGER);
  VAR g, yy: INTEGER; lbl: ARRAY [0..31] OF CHAR;
BEGIN
  FillRect(px, py, pw, ph, bgCol);
  Rect(px, py, pw, ph, GridCol);
  Text(px + 12, py + 8, 2, axisCol, title);
  plotX := px + 52; plotY := py + 36; plotW := pw - 52 - 16; plotH := ph - 36 - 26;
  (* gridlines + value labels at 0, 1/5 .. 5/5 of `top` *)
  FOR g := 0 TO 5 DO
    yy := plotY + plotH - (g * plotH DIV 5);
    HLine(plotX, yy, plotW, GridCol);
    FmtNum(top * VAL(REAL, g) / 5.0, lbl);
    Text(plotX - 4 - TextWidth(1, lbl), yy - 3, 1, axisCol, lbl)
  END;
  VLine(plotX, plotY, plotH, axisCol);
  HLine(plotX, plotY + plotH, plotW, axisCol)
END Frame;

(* ---- charts ------------------------------------------------------------ *)

PROCEDURE BarChart (px, py, pw, ph: INTEGER; VAR vals: ARRAY OF REAL; n: CARDINAL;
                    title: ARRAY OF CHAR; barCol, axisCol, bgCol: CARDINAL);
  VAR plotX, plotY, plotW, plotH, slot, bw, bh, i: INTEGER; top: REAL; idx: CARDINAL;
      lbl: ARRAY [0..15] OF CHAR;
BEGIN
  IF n = 0 THEN RETURN END;
  top := NiceTop(MaxReal(vals, n));
  Frame(px, py, pw, ph, top, title, axisCol, bgCol, plotX, plotY, plotW, plotH);
  slot := plotW DIV VAL(INTEGER, n);
  bw := slot - 8; IF bw < 2 THEN bw := 2 END;
  FOR idx := 0 TO n-1 DO
    i := VAL(INTEGER, idx);
    bh := PixOf(vals[idx], top, plotH);
    FillRect(plotX + i*slot + 4, plotY + plotH - bh, bw, bh, barCol);
    RealStr.RealToFixed(vals[idx], 0, lbl); Trim(lbl);     (* index label under bar *)
    Text(plotX + i*slot + slot DIV 2 - TextWidth(1, lbl) DIV 2, plotY + plotH + 6, 1, axisCol, lbl)
  END
END BarChart;

PROCEDURE LineChart (px, py, pw, ph: INTEGER; VAR vals: ARRAY OF REAL; n: CARDINAL;
                     title: ARRAY OF CHAR; lineCol, axisCol, bgCol: CARDINAL);
  VAR plotX, plotY, plotW, plotH, i, x0, y0, x1, y1, step: INTEGER; top: REAL; idx: CARDINAL;
BEGIN
  IF n = 0 THEN RETURN END;
  top := NiceTop(MaxReal(vals, n));
  Frame(px, py, pw, ph, top, title, axisCol, bgCol, plotX, plotY, plotW, plotH);
  IF n = 1 THEN step := plotW ELSE step := plotW DIV VAL(INTEGER, n-1) END;
  FOR idx := 0 TO n-1 DO
    i := VAL(INTEGER, idx);
    x1 := plotX + i*step;
    y1 := plotY + plotH - PixOf(vals[idx], top, plotH);
    IF idx > 0 THEN ThickLine(x0, y0, x1, y1, 2, lineCol) END;
    Disc(x1, y1, 3, lineCol);
    x0 := x1; y0 := y1
  END
END LineChart;

PROCEDURE Atan2 (y, x: REAL): REAL;
BEGIN
  IF x > 0.0 THEN RETURN arctan(y / x)
  ELSIF x < 0.0 THEN
    IF y >= 0.0 THEN RETURN arctan(y / x) + PI ELSE RETURN arctan(y / x) - PI END
  ELSE
    IF y > 0.0 THEN RETURN PI / 2.0 ELSIF y < 0.0 THEN RETURN -PI / 2.0 ELSE RETURN 0.0 END
  END
END Atan2;

PROCEDURE PieChart (cx, cy, r: INTEGER; VAR vals: ARRAY OF REAL; n: CARDINAL;
                    VAR cols: ARRAY OF CARDINAL; title: ARRAY OF CHAR; bgCol: CARDINAL);
  VAR dx, dy: INTEGER; total, a, frac, acc: REAL; s, slice: CARDINAL;
      cum: ARRAY [0..63] OF REAL;
BEGIN
  IF (n = 0) OR (n > 64) THEN RETURN END;
  total := SumReal(vals, n);
  IF total <= 0.0 THEN RETURN END;
  acc := 0.0;                                  (* cumulative slice fractions *)
  FOR s := 0 TO n-1 DO acc := acc + vals[s] / total; cum[s] := acc END;
  FillRect(cx - r - 10, cy - r - 30, 2*r + 20, 2*r + 50, bgCol);
  Text(cx - TextWidth(2, title) DIV 2, cy - r - 26, 2, 0404040H, title);
  dy := -r;
  WHILE dy <= r DO
    dx := -r;
    WHILE dx <= r DO
      IF dx*dx + dy*dy <= r*r THEN
        a := Atan2(VAL(REAL, dy), VAL(REAL, dx));   (* angle, clockwise from +x *)
        IF a < 0.0 THEN a := a + 2.0*PI END;
        frac := a / (2.0*PI);
        slice := 0;
        WHILE (slice < n-1) AND (frac > cum[slice]) DO INC(slice) END;
        Pixel(cx + dx, cy + dy, cols[slice])
      END;
      INC(dx)
    END;
    INC(dy)
  END;
  Circle(cx, cy, r, 0404040H)
END PieChart;

PROCEDURE LegendItem (px, py: INTEGER; col: CARDINAL; label: ARRAY OF CHAR): INTEGER;
BEGIN
  FillRect(px, py, 16, 14, col);
  Rect(px, py, 16, 14, 0404040H);
  Text(px + 24, py + 1, 1, 0303030H, label);
  RETURN py + 22
END LegendItem;

END Chart.
