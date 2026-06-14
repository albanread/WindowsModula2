IMPLEMENTATION MODULE Canvas2D;

(* Direct2D immediate-mode 2-D drawing. The COM path here is the one TermRender
   proves (factory -> HWND render target -> solid brush; Begin/Clear/Fill*/EndDraw
   inherited from ID2D1RenderTarget); this module adds FillEllipse (@21) and the
   public REAL/RGB convenience wrappers. *)

FROM SYSTEM IMPORT ADDRESS, ADR, SIZE;
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

VAR
  gFactory, gFormat, gRT, gBrush: ADDRESS;
  gW, gH: CARDINAL;

PROCEDURE ToColorF (packed: CARDINAL; VAR cf: ColorF);
BEGIN
  cf.r := VAL(SHORTREAL, VAL(REAL, (packed SHR 16) BAND 0FFH) / 255.0);
  cf.g := VAL(SHORTREAL, VAL(REAL, (packed SHR 8)  BAND 0FFH) / 255.0);
  cf.b := VAL(SHORTREAL, VAL(REAL,  packed         BAND 0FFH) / 255.0);
  cf.a := VAL(SHORTREAL, 1.0)
END ToColorF;

PROCEDURE SetBrush (rgb: CARDINAL);
  VAR br: ID2D1SolidColorBrush; cf: ColorF;
BEGIN
  IF gBrush = NIL THEN RETURN END;
  br := gBrush; ToColorF(rgb, cf); br.SetColor(ADR(cf))
END SetBrush;

PROCEDURE Startup (): BOOLEAN;
  VAR iid: ARRAY [0..15] OF BYTE; hr: INTEGER32;
BEGIN
  IF NOT FromString("{06152247-6f50-465a-9245-118bfd3b6007}", iid) THEN RETURN FALSE END;
  gFactory := NIL;
  hr := D2D1CreateFactory(0, ADR(iid), NIL, ADR(gFactory));     (* 0 = SINGLE_THREADED *)
  IF (hr < 0) OR (gFactory = NIL) THEN RETURN FALSE END;
  IF NOT DWrite.Startup() THEN RETURN FALSE END;
  gFormat := DWrite.CreateFormat("Segoe UI", VAL(SHORTREAL, 20.0));
  RETURN gFormat # NIL
END Startup;

PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  VAR fac: ID2D1Factory; rt: ID2D1HwndRenderTarget; rtp: RTProps; hwp: HwndRTProps;
      cf: ColorF; hr: INTEGER32;
BEGIN
  IF gFactory = NIL THEN RETURN FALSE END;
  gW := pxW; gH := pxH;
  ZeroMem(ADR(rtp), SIZE(rtp));                  (* all-default RT properties *)
  hwp.hwnd := hwnd;
  hwp.pixelSize.w := VAL(DWORD, pxW);
  hwp.pixelSize.h := VAL(DWORD, pxH);
  hwp.present := 0;
  fac := gFactory; gRT := NIL;
  hr := fac.CreateHwndRenderTarget(ADR(rtp), ADR(hwp), ADR(gRT));
  IF (hr < 0) OR (gRT = NIL) THEN RETURN FALSE END;
  rt := gRT;
  ToColorF(0FFFFFFH, cf);
  gBrush := NIL;
  hr := rt.CreateSolidColorBrush(ADR(cf), NIL, ADR(gBrush));
  RETURN (hr >= 0) AND (gBrush # NIL)
END Attach;

PROCEDURE Width  (): CARDINAL; BEGIN RETURN gW END Width;
PROCEDURE Height (): CARDINAL; BEGIN RETURN gH END Height;

PROCEDURE Begin;
  VAR rt: ID2D1HwndRenderTarget;
BEGIN
  IF gRT = NIL THEN RETURN END;
  rt := gRT; rt.BeginDraw()
END Begin;

PROCEDURE Flush;
  VAR rt: ID2D1HwndRenderTarget; hr: INTEGER;
BEGIN
  IF gRT = NIL THEN RETURN END;
  rt := gRT; hr := rt.EndDraw(NIL, NIL)
END Flush;

PROCEDURE Clear (rgb: CARDINAL);
  VAR rt: ID2D1HwndRenderTarget; cf: ColorF;
BEGIN
  IF gRT = NIL THEN RETURN END;
  rt := gRT; ToColorF(rgb, cf); rt.Clear(ADR(cf))
END Clear;

PROCEDURE FillRect (x, y, w, h: REAL; rgb: CARDINAL);
  VAR rt: ID2D1HwndRenderTarget; rc: RectF;
BEGIN
  IF gRT = NIL THEN RETURN END;
  rt := gRT;
  rc.left   := VAL(SHORTREAL, x);       rc.top    := VAL(SHORTREAL, y);
  rc.right  := VAL(SHORTREAL, x + w);    rc.bottom := VAL(SHORTREAL, y + h);
  SetBrush(rgb);
  rt.FillRectangle(ADR(rc), gBrush)
END FillRect;

PROCEDURE FillEllipse (cx, cy, rx, ry: REAL; rgb: CARDINAL);
  VAR rt: ID2D1HwndRenderTarget; el: EllipseF;
BEGIN
  IF gRT = NIL THEN RETURN END;
  rt := gRT;
  el.cx := VAL(SHORTREAL, cx); el.cy := VAL(SHORTREAL, cy);
  el.rx := VAL(SHORTREAL, rx); el.ry := VAL(SHORTREAL, ry);
  SetBrush(rgb);
  rt.FillEllipse(ADR(el), gBrush)
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
  IF (gRT = NIL) OR (gFormat = NIL) THEN RETURN END;
  rt := gRT; n := TextLen(s);
  IF n = 0 THEN RETURN END;
  rc.left   := VAL(SHORTREAL, x);       rc.top    := VAL(SHORTREAL, y);
  rc.right  := VAL(SHORTREAL, x + w);    rc.bottom := VAL(SHORTREAL, y + h);
  SetBrush(rgb);
  rt.DrawText(ADR(s), VAL(DWORD, n), gFormat, ADR(rc), gBrush,
              VAL(INTEGER32, 0), VAL(INTEGER32, 0))
END DrawText;

PROCEDURE Shutdown;
  VAR o: ID2D1SolidColorBrush; rt: ID2D1HwndRenderTarget; fac: ID2D1Factory; d: INTEGER;
BEGIN
  IF gBrush # NIL THEN o := gBrush; d := o.Release(); gBrush := NIL END;
  IF gRT # NIL THEN rt := gRT; d := rt.Release(); gRT := NIL END;
  IF gFactory # NIL THEN fac := gFactory; d := fac.Release(); gFactory := NIL END
END Shutdown;

BEGIN
  gFactory := NIL; gFormat := NIL; gRT := NIL; gBrush := NIL; gW := 0; gH := 0
END Canvas2D.
