IMPLEMENTATION MODULE TermRender;

FROM SYSTEM IMPORT ADDRESS, ADR, SIZE;
FROM Graphics_Direct2D IMPORT D2D1CreateFactory,
  ID2D1Factory, ID2D1HwndRenderTarget, ID2D1SolidColorBrush;
FROM Guid IMPORT FromString;
FROM WIN32 IMPORT DWORD;
FROM MemUtils IMPORT ZeroMem;
IMPORT Terminal;
IMPORT DWrite;

TYPE
  ColorF      = RECORD r, g, b, a: SHORTREAL END;             (* D2D1_COLOR_F (4x f32) *)
  RectF       = RECORD left, top, right, bottom: SHORTREAL END;
  SizeU       = RECORD w, h: DWORD END;
  PixFmt      = RECORD format, alphaMode: DWORD END;
  RTProps     = RECORD rtype: DWORD; pixFmt: PixFmt; dpiX, dpiY: SHORTREAL; usage, minLevel: DWORD END;
  HwndRTProps = RECORD hwnd: ADDRESS; pixelSize: SizeU; present: DWORD END;

(* The Direct2D interfaces — ID2D1Factory (CreateHwndRenderTarget @14),
   ID2D1HwndRenderTarget (the render target; CreateSolidColorBrush @8,
   FillRectangle @17, DrawText @27, Clear @47, BeginDraw @48, EndDraw @49, all
   inherited from ID2D1RenderTarget) and ID2D1SolidColorBrush (SetColor @8) — are
   IMPORTed from the winapi-gen-generated Graphics_Direct2D module above.
   Their vtables come from the Windows metadata and every slot is machine-checked
   by the compiler. *)

VAR
  gFactory, gFormat, gRT, gBrush: ADDRESS;
  gCellW, gCellH: CARDINAL;

PROCEDURE ToColorF (packed: CARDINAL; VAR cf: ColorF);
BEGIN
  cf.r := VAL(SHORTREAL, VAL(REAL, (packed SHR 16) BAND 0FFH) / 255.0);
  cf.g := VAL(SHORTREAL, VAL(REAL, (packed SHR 8)  BAND 0FFH) / 255.0);
  cf.b := VAL(SHORTREAL, VAL(REAL,  packed         BAND 0FFH) / 255.0);
  cf.a := VAL(SHORTREAL, 1.0)
END ToColorF;

PROCEDURE Startup (fontName: ARRAY OF CHAR; fontSize: SHORTREAL): BOOLEAN;
  VAR iid: ARRAY [0..15] OF BYTE; hr: INTEGER32;
BEGIN
  IF NOT FromString("{06152247-6f50-465a-9245-118bfd3b6007}", iid) THEN RETURN FALSE END;
  gFactory := NIL;
  hr := D2D1CreateFactory(0, ADR(iid), NIL, ADR(gFactory));   (* 0 = SINGLE_THREADED *)
  IF FAILED(hr) OR (gFactory = NIL) THEN RETURN FALSE END;
  IF NOT DWrite.Startup() THEN RETURN FALSE END;
  gFormat := DWrite.CreateFormat(fontName, fontSize);
  RETURN gFormat # NIL
END Startup;

PROCEDURE Ready (): BOOLEAN;
BEGIN RETURN (gRT # NIL) AND (gFormat # NIL) END Ready;

PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH, cellW, cellH: CARDINAL): BOOLEAN;
  VAR fac: ID2D1Factory; rt: ID2D1HwndRenderTarget; rtp: RTProps; hwp: HwndRTProps;
      cf: ColorF; hr: INTEGER;
BEGIN
  IF gFactory = NIL THEN RETURN FALSE END;
  gCellW := cellW; gCellH := cellH;
  ZeroMem(ADR(rtp), SIZE(rtp));                 (* all-default RT properties *)
  hwp.hwnd := hwnd;
  hwp.pixelSize.w := VAL(DWORD, pxW);
  hwp.pixelSize.h := VAL(DWORD, pxH);
  hwp.present := 0;
  fac := gFactory;
  gRT := NIL;
  hr := fac.CreateHwndRenderTarget(ADR(rtp), ADR(hwp), ADR(gRT));
  IF FAILED(hr) THEN RETURN FALSE END;
  IF gRT = NIL THEN RETURN FALSE END;
  rt := gRT;
  ToColorF(Terminal.White, cf);
  gBrush := NIL;
  hr := rt.CreateSolidColorBrush(ADR(cf), NIL, ADR(gBrush));
  RETURN SUCCEEDED(hr) AND (gBrush # NIL)
END Attach;

PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  VAR rt: ID2D1HwndRenderTarget; su: SizeU; hr: INTEGER;
BEGIN
  IF gRT = NIL THEN RETURN FALSE END;
  rt := gRT;
  su.w := VAL(DWORD, pxW);
  su.h := VAL(DWORD, pxH);
  hr := rt.Resize(ADR(su));                         (* ID2D1HwndRenderTarget.Resize @58 *)
  RETURN SUCCEEDED(hr)
END Resize;

PROCEDURE Paint;
  VAR rt: ID2D1HwndRenderTarget; br: ID2D1SolidColorBrush; cf: ColorF; rc: RectF;
      col, row, cols, rows: CARDINAL; ch: CHAR; s: ARRAY [0..1] OF CHAR; hr: INTEGER;
BEGIN
  IF (gRT = NIL) OR (gBrush = NIL) THEN RETURN END;
  rt := gRT; br := gBrush;
  rt.BeginDraw();                                  (* Begin/Clear/Fill/DrawText/SetColor *)
  ToColorF(Terminal.Black, cf); rt.Clear(ADR(cf)); (* return void in D2D — called as statements *)
  cols := Terminal.Cols(); rows := Terminal.Rows();
  row := 0;
  WHILE row < rows DO
    col := 0;
    WHILE col < cols DO
      rc.left   := VAL(SHORTREAL, VAL(REAL, col * gCellW));
      rc.top    := VAL(SHORTREAL, VAL(REAL, row * gCellH));
      rc.right  := VAL(SHORTREAL, VAL(REAL, (col + 1) * gCellW));
      rc.bottom := VAL(SHORTREAL, VAL(REAL, (row + 1) * gCellH));
      ToColorF(Terminal.CellBg(col, row), cf);
      br.SetColor(ADR(cf));
      rt.FillRectangle(ADR(rc), gBrush);
      ch := Terminal.CellChar(col, row);
      IF ch # ' ' THEN
        ToColorF(Terminal.CellFg(col, row), cf);
        br.SetColor(ADR(cf));
        s[0] := ch; s[1] := 0C;
        rt.DrawText(ADR(s), VAL(DWORD, 1), gFormat, ADR(rc), gBrush,
                    VAL(INTEGER32, 0), VAL(INTEGER32, 0))
      END;
      INC(col)
    END;
    INC(row)
  END;
  hr := rt.EndDraw(NIL, NIL)
END Paint;

BEGIN
  gFactory := NIL; gFormat := NIL; gRT := NIL; gBrush := NIL;
  gCellW := 9; gCellH := 18
END TermRender.
