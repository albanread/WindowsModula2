IMPLEMENTATION MODULE TermRender;

(* S1 (PaneShell): instanced. Each renderer instance owns its DirectWrite text
   format and (after Attach) its own ID2D1HwndRenderTarget + brush + cell size,
   plus the Terminal instance it paints (Bind; NIL = the current Terminal). The
   Direct2D factory and the DirectWrite factory are shared module singletons
   (created once). A module-global `gActive` points at the current renderer
   (never NIL); an eager default renderer backs the legacy singleton API, so
   existing callers (FastM2, term-demo, t-90-246) behave exactly as before. *)

FROM SYSTEM IMPORT ADDRESS, ADR, SIZE, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
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

  (* one renderer instance *)
  RInstRec = RECORD
    format: ADDRESS;             (* IDWriteTextFormat — per instance *)
    rt:     ADDRESS;             (* ID2D1HwndRenderTarget — per window (after Attach) *)
    brush:  ADDRESS;             (* ID2D1SolidColorBrush *)
    cellW, cellH: CARDINAL;
    term:   Terminal.Instance;   (* the grid this renderer paints; NIL = current Terminal *)
  END;
  RInstPtr = POINTER TO RInstRec;

(* The Direct2D interfaces — ID2D1Factory (CreateHwndRenderTarget @14),
   ID2D1HwndRenderTarget (CreateSolidColorBrush @8, FillRectangle @17, DrawText
   @27, Clear @47, BeginDraw @48, EndDraw @49) and ID2D1SolidColorBrush
   (SetColor @8) — are IMPORTed from the winapi-gen-generated Graphics_Direct2D
   module; every vtable slot is machine-checked by the compiler. *)

VAR
  gFactory: ADDRESS;             (* shared Direct2D factory (created once) *)
  gActive:  RInstPtr;            (* the current renderer (never NIL) *)
  gDefault: RInstPtr;            (* backs the legacy singleton API; never freed *)

PROCEDURE ToColorF (packed: CARDINAL; VAR cf: ColorF);
BEGIN
  cf.r := VAL(SHORTREAL, VAL(REAL, (packed SHR 16) BAND 0FFH) / 255.0);
  cf.g := VAL(SHORTREAL, VAL(REAL, (packed SHR 8)  BAND 0FFH) / 255.0);
  cf.b := VAL(SHORTREAL, VAL(REAL,  packed         BAND 0FFH) / 255.0);
  cf.a := VAL(SHORTREAL, 1.0)
END ToColorF;

(* create the shared Direct2D factory (once) + the shared DWrite factory *)
PROCEDURE EnsureFactory (): BOOLEAN;
  VAR iid: ARRAY [0..15] OF BYTE; hr: INTEGER32;
BEGIN
  IF gFactory = NIL THEN
    IF NOT FromString("{06152247-6f50-465a-9245-118bfd3b6007}", iid) THEN RETURN FALSE END;
    hr := D2D1CreateFactory(0, ADR(iid), NIL, ADR(gFactory));   (* 0 = SINGLE_THREADED *)
    IF FAILED(hr) OR (gFactory = NIL) THEN gFactory := NIL; RETURN FALSE END
  END;
  RETURN DWrite.Startup()                                       (* idempotent (DWrite S1 fix) *)
END EnsureFactory;

(* ---- instance lifecycle ---- *)
PROCEDURE NewRInst (): RInstPtr;
  VAR a: ADDRESS; p: RInstPtr;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(RInstRec));
  p := CAST(RInstPtr, a);
  p^.format := NIL; p^.rt := NIL; p^.brush := NIL;
  p^.cellW := 9; p^.cellH := 18; p^.term := NIL;
  RETURN p
END NewRInst;

PROCEDURE Create (fontName: ARRAY OF CHAR; fontSize: SHORTREAL): Instance;
  VAR p: RInstPtr;
BEGIN
  p := NewRInst();
  IF EnsureFactory() THEN p^.format := DWrite.CreateFormat(fontName, fontSize) END;
  RETURN CAST(Instance, p)
END Create;

PROCEDURE Use (i: Instance);
BEGIN
  IF i = NIL THEN gActive := gDefault ELSE gActive := CAST(RInstPtr, i) END
END Use;

PROCEDURE Bind (term: Terminal.Instance);
BEGIN gActive^.term := term END Bind;

PROCEDURE Free (VAR i: Instance);
  VAR p: RInstPtr;
BEGIN
  IF i # NIL THEN
    p := CAST(RInstPtr, i);
    IF p = gActive THEN gActive := gDefault END;
    (* TODO S5/P8: Release the COM objects (format/rt/brush) before freeing *)
    IF p # gDefault THEN DEALLOCATE(i, SIZE(RInstRec)) END;
    i := NIL
  END
END Free;

PROCEDURE FormatReady (i: Instance): BOOLEAN;
  VAR p: RInstPtr;
BEGIN
  IF i = NIL THEN RETURN FALSE END;
  p := CAST(RInstPtr, i);
  RETURN p^.format # NIL
END FormatReady;

(* ---- singleton API: operates on the current renderer (gActive^) ---- *)
PROCEDURE Startup (fontName: ARRAY OF CHAR; fontSize: SHORTREAL): BOOLEAN;
BEGIN
  IF NOT EnsureFactory() THEN RETURN FALSE END;
  gActive^.format := DWrite.CreateFormat(fontName, fontSize);
  RETURN gActive^.format # NIL
END Startup;

PROCEDURE Ready (): BOOLEAN;
BEGIN RETURN (gActive^.rt # NIL) AND (gActive^.format # NIL) END Ready;

PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH, cellW, cellH: CARDINAL): BOOLEAN;
  VAR fac: ID2D1Factory; rt: ID2D1HwndRenderTarget; rtp: RTProps; hwp: HwndRTProps;
      cf: ColorF; hr: INTEGER;
BEGIN
  IF gFactory = NIL THEN RETURN FALSE END;
  gActive^.cellW := cellW; gActive^.cellH := cellH;
  ZeroMem(ADR(rtp), SIZE(rtp));                 (* all-default RT properties *)
  hwp.hwnd := hwnd;
  hwp.pixelSize.w := VAL(DWORD, pxW);
  hwp.pixelSize.h := VAL(DWORD, pxH);
  hwp.present := 0;
  fac := gFactory;
  gActive^.rt := NIL;
  hr := fac.CreateHwndRenderTarget(ADR(rtp), ADR(hwp), ADR(gActive^.rt));
  IF FAILED(hr) THEN RETURN FALSE END;
  IF gActive^.rt = NIL THEN RETURN FALSE END;
  rt := gActive^.rt;
  ToColorF(Terminal.White, cf);
  gActive^.brush := NIL;
  hr := rt.CreateSolidColorBrush(ADR(cf), NIL, ADR(gActive^.brush));
  RETURN SUCCEEDED(hr) AND (gActive^.brush # NIL)
END Attach;

PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  VAR rt: ID2D1HwndRenderTarget; su: SizeU; hr: INTEGER;
BEGIN
  IF gActive^.rt = NIL THEN RETURN FALSE END;
  rt := gActive^.rt;
  su.w := VAL(DWORD, pxW);
  su.h := VAL(DWORD, pxH);
  hr := rt.Resize(ADR(su));                         (* ID2D1HwndRenderTarget.Resize @58 *)
  RETURN SUCCEEDED(hr)
END Resize;

PROCEDURE Paint;
  VAR rt: ID2D1HwndRenderTarget; br: ID2D1SolidColorBrush; cf: ColorF; rc: RectF;
      col, row, cols, rows, cw, chh: CARDINAL; ch: CHAR; s: ARRAY [0..1] OF CHAR; hr: INTEGER;
BEGIN
  IF (gActive^.rt = NIL) OR (gActive^.brush = NIL) THEN RETURN END;
  IF gActive^.term # NIL THEN Terminal.Use(gActive^.term) END;   (* render the bound grid *)
  rt := gActive^.rt; br := gActive^.brush;
  cw := gActive^.cellW; chh := gActive^.cellH;
  rt.BeginDraw();                                  (* Begin/Clear/Fill/DrawText/SetColor *)
  ToColorF(Terminal.Black, cf); rt.Clear(ADR(cf)); (* return void in D2D — called as statements *)
  cols := Terminal.Cols(); rows := Terminal.Rows();
  row := 0;
  WHILE row < rows DO
    col := 0;
    WHILE col < cols DO
      rc.left   := VAL(SHORTREAL, VAL(REAL, col * cw));
      rc.top    := VAL(SHORTREAL, VAL(REAL, row * chh));
      rc.right  := VAL(SHORTREAL, VAL(REAL, (col + 1) * cw));
      rc.bottom := VAL(SHORTREAL, VAL(REAL, (row + 1) * chh));
      ToColorF(Terminal.CellBg(col, row), cf);
      br.SetColor(ADR(cf));
      rt.FillRectangle(ADR(rc), gActive^.brush);
      ch := Terminal.CellChar(col, row);
      IF ch # ' ' THEN
        ToColorF(Terminal.CellFg(col, row), cf);
        br.SetColor(ADR(cf));
        s[0] := ch; s[1] := 0C;
        rt.DrawText(ADR(s), VAL(DWORD, 1), gActive^.format, ADR(rc), gActive^.brush,
                    VAL(INTEGER32, 0), VAL(INTEGER32, 0))
      END;
      INC(col)
    END;
    INC(row)
  END;
  hr := rt.EndDraw(NIL, NIL)
END Paint;

BEGIN
  gFactory := NIL;
  gDefault := NewRInst();
  gActive  := gDefault
END TermRender.
