IMPLEMENTATION MODULE Canvas2D;

(* Direct2D immediate-mode 2-D drawing. The COM path here is the one TermRender
   proves (factory -> HWND render target -> solid brush; Begin/Clear/Fill*/EndDraw
   inherited from ID2D1RenderTarget); this module adds FillEllipse (@21) and the
   public REAL/RGB convenience wrappers.

   S2 (PaneShell): instanced. Each canvas instance owns its DirectWrite text
   format and (after Attach) its own ID2D1HwndRenderTarget + brush + size. The
   Direct2D factory and the DirectWrite factory are shared module singletons. A
   module-global gActive points at the current canvas (never NIL); an eager
   default backs the legacy singleton API, so existing callers (calculator,
   reversi_gui, simd_particles) behave exactly as before. *)

FROM SYSTEM IMPORT ADDRESS, ADR, SIZE, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM Graphics_Direct2D IMPORT D2D1CreateFactory,
  ID2D1Factory, ID2D1HwndRenderTarget, ID2D1SolidColorBrush;
FROM Guid IMPORT FromString;
FROM WIN32 IMPORT DWORD;
FROM MemUtils IMPORT ZeroMem;
IMPORT DWrite;

TYPE
  ColorF      = RECORD r, g, b, a: SHORTREAL END;            (* D2D1_COLOR_F *)
  RectF       = RECORD left, top, right, bottom: SHORTREAL END;
  EllipseF    = RECORD cx, cy, rx, ry: SHORTREAL END;       (* D2D1_ELLIPSE *)
  SizeU       = RECORD w, h: DWORD END;
  PixFmt      = RECORD format, alphaMode: DWORD END;
  RTProps     = RECORD rtype: DWORD; pixFmt: PixFmt; dpiX, dpiY: SHORTREAL; usage, minLevel: DWORD END;
  HwndRTProps = RECORD hwnd: ADDRESS; pixelSize: SizeU; present: DWORD END;

  CInstRec = RECORD
    format: ADDRESS;       (* IDWriteTextFormat — per instance *)
    rt:     ADDRESS;       (* ID2D1HwndRenderTarget — per window (after Attach) *)
    brush:  ADDRESS;       (* ID2D1SolidColorBrush *)
    w, h:   CARDINAL;
  END;
  CInstPtr = POINTER TO CInstRec;

VAR
  gFactory: ADDRESS;       (* shared Direct2D factory (created once) *)
  gActive:  CInstPtr;      (* the current canvas (never NIL) *)
  gDefault: CInstPtr;      (* backs the legacy singleton API; never freed *)

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
    hr := D2D1CreateFactory(0, ADR(iid), NIL, ADR(gFactory));     (* 0 = SINGLE_THREADED *)
    IF (hr < 0) OR (gFactory = NIL) THEN gFactory := NIL; RETURN FALSE END
  END;
  RETURN DWrite.Startup()                                          (* idempotent (DWrite S1 fix) *)
END EnsureFactory;

(* Release a COM interface (Release is IUnknown slot 2 on every interface) and NIL it *)
PROCEDURE FreeObj (VAR h: ADDRESS);
  VAR o: ID2D1SolidColorBrush; d: INTEGER;
BEGIN
  IF h # NIL THEN o := h; d := o.Release(); h := NIL END
END FreeObj;

(* ---- instance lifecycle ---- *)
PROCEDURE NewCInst (): CInstPtr;
  VAR a: ADDRESS; p: CInstPtr;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(CInstRec));
  p := CAST(CInstPtr, a);
  p^.format := NIL; p^.rt := NIL; p^.brush := NIL; p^.w := 0; p^.h := 0;
  RETURN p
END NewCInst;

PROCEDURE Create (): Instance;
  VAR p: CInstPtr;
BEGIN
  p := NewCInst();
  IF EnsureFactory() THEN p^.format := DWrite.CreateFormat("Segoe UI", VAL(SHORTREAL, 20.0)) END;
  RETURN CAST(Instance, p)
END Create;

PROCEDURE Use (i: Instance);
BEGIN
  IF i = NIL THEN gActive := gDefault ELSE gActive := CAST(CInstPtr, i) END
END Use;

PROCEDURE Free (VAR i: Instance);
  VAR p: CInstPtr;
BEGIN
  IF i # NIL THEN
    p := CAST(CInstPtr, i);
    IF p = gActive THEN gActive := gDefault END;
    FreeObj(p^.brush); FreeObj(p^.rt); FreeObj(p^.format);
    IF p # gDefault THEN DEALLOCATE(i, SIZE(CInstRec)) END;
    i := NIL
  END
END Free;

PROCEDURE FormatReady (i: Instance): BOOLEAN;
  VAR p: CInstPtr;
BEGIN
  IF i = NIL THEN RETURN FALSE END;
  p := CAST(CInstPtr, i);
  RETURN p^.format # NIL
END FormatReady;

(* ---- singleton API: operates on the current canvas (gActive^) ---- *)
PROCEDURE SetBrush (rgb: CARDINAL);
  VAR br: ID2D1SolidColorBrush; cf: ColorF;
BEGIN
  IF gActive^.brush = NIL THEN RETURN END;
  br := gActive^.brush; ToColorF(rgb, cf); br.SetColor(ADR(cf))
END SetBrush;

PROCEDURE Startup (): BOOLEAN;
BEGIN
  IF NOT EnsureFactory() THEN RETURN FALSE END;
  gActive^.format := DWrite.CreateFormat("Segoe UI", VAL(SHORTREAL, 20.0));
  RETURN gActive^.format # NIL
END Startup;

PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  VAR fac: ID2D1Factory; rt: ID2D1HwndRenderTarget; rtp: RTProps; hwp: HwndRTProps;
      cf: ColorF; hr: INTEGER32;
BEGIN
  IF gFactory = NIL THEN RETURN FALSE END;
  gActive^.w := pxW; gActive^.h := pxH;
  ZeroMem(ADR(rtp), SIZE(rtp));                  (* all-default RT properties *)
  hwp.hwnd := hwnd;
  hwp.pixelSize.w := VAL(DWORD, pxW);
  hwp.pixelSize.h := VAL(DWORD, pxH);
  hwp.present := 0;
  fac := gFactory; gActive^.rt := NIL;
  hr := fac.CreateHwndRenderTarget(ADR(rtp), ADR(hwp), ADR(gActive^.rt));
  IF (hr < 0) OR (gActive^.rt = NIL) THEN RETURN FALSE END;
  rt := gActive^.rt;
  ToColorF(0FFFFFFH, cf);
  gActive^.brush := NIL;
  hr := rt.CreateSolidColorBrush(ADR(cf), NIL, ADR(gActive^.brush));
  RETURN (hr >= 0) AND (gActive^.brush # NIL)
END Attach;

PROCEDURE Width  (): CARDINAL; BEGIN RETURN gActive^.w END Width;
PROCEDURE Height (): CARDINAL; BEGIN RETURN gActive^.h END Height;

PROCEDURE Begin;
  VAR rt: ID2D1HwndRenderTarget;
BEGIN
  IF gActive^.rt = NIL THEN RETURN END;
  rt := gActive^.rt; rt.BeginDraw()
END Begin;

PROCEDURE Flush;
  VAR rt: ID2D1HwndRenderTarget; hr: INTEGER;
BEGIN
  IF gActive^.rt = NIL THEN RETURN END;
  rt := gActive^.rt; hr := rt.EndDraw(NIL, NIL)
END Flush;

PROCEDURE Clear (rgb: CARDINAL);
  VAR rt: ID2D1HwndRenderTarget; cf: ColorF;
BEGIN
  IF gActive^.rt = NIL THEN RETURN END;
  rt := gActive^.rt; ToColorF(rgb, cf); rt.Clear(ADR(cf))
END Clear;

PROCEDURE FillRect (x, y, w, h: REAL; rgb: CARDINAL);
  VAR rt: ID2D1HwndRenderTarget; rc: RectF;
BEGIN
  IF gActive^.rt = NIL THEN RETURN END;
  rt := gActive^.rt;
  rc.left   := VAL(SHORTREAL, x);       rc.top    := VAL(SHORTREAL, y);
  rc.right  := VAL(SHORTREAL, x + w);    rc.bottom := VAL(SHORTREAL, y + h);
  SetBrush(rgb);
  rt.FillRectangle(ADR(rc), gActive^.brush)
END FillRect;

PROCEDURE FillEllipse (cx, cy, rx, ry: REAL; rgb: CARDINAL);
  VAR rt: ID2D1HwndRenderTarget; el: EllipseF;
BEGIN
  IF gActive^.rt = NIL THEN RETURN END;
  rt := gActive^.rt;
  el.cx := VAL(SHORTREAL, cx); el.cy := VAL(SHORTREAL, cy);
  el.rx := VAL(SHORTREAL, rx); el.ry := VAL(SHORTREAL, ry);
  SetBrush(rgb);
  rt.FillEllipse(ADR(el), gActive^.brush)
END FillEllipse;

PROCEDURE FillCircle (cx, cy, r: REAL; rgb: CARDINAL);
BEGIN
  FillEllipse(cx, cy, r, r, rgb)
END FillCircle;

PROCEDURE TextLen (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END;
  RETURN i
END TextLen;

PROCEDURE DrawText (x, y, w, h: REAL; rgb: CARDINAL; s: ARRAY OF CHAR);
  VAR rt: ID2D1HwndRenderTarget; rc: RectF; n: CARDINAL;
BEGIN
  IF (gActive^.rt = NIL) OR (gActive^.format = NIL) THEN RETURN END;
  rt := gActive^.rt; n := TextLen(s);
  IF n = 0 THEN RETURN END;
  rc.left   := VAL(SHORTREAL, x);       rc.top    := VAL(SHORTREAL, y);
  rc.right  := VAL(SHORTREAL, x + w);    rc.bottom := VAL(SHORTREAL, y + h);
  SetBrush(rgb);
  rt.DrawText(ADR(s), VAL(DWORD, n), gActive^.format, ADR(rc), gActive^.brush,
              VAL(INTEGER32, 0), VAL(INTEGER32, 0))
END DrawText;

PROCEDURE Shutdown;
  VAR fac: ID2D1Factory; d: INTEGER;
BEGIN
  FreeObj(gActive^.brush); FreeObj(gActive^.rt); FreeObj(gActive^.format);
  IF gFactory # NIL THEN fac := gFactory; d := fac.Release(); gFactory := NIL END
END Shutdown;

BEGIN
  gFactory := NIL;
  gDefault := NewCInst();
  gActive  := gDefault
END Canvas2D.
