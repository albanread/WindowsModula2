MODULE T90246TermRender;
(*
 * Group 90 — Direct2D/DirectWrite Terminal renderer foundation. Creates the
 * Direct2D factory and a DirectWrite monospaced text format (headless-safe — no
 * window). This exercises the large ID2D1Factory / ID2D1HwndRenderTarget /
 * ID2D1SolidColorBrush vtable declarations compiling and the factory creating.
 * Painting the cell grid to a real window is verified by the interactive demo.
 *
 * EXPECTED:
 * d2d: Y
 *)
FROM TermRender IMPORT Startup;
FROM StrIO IMPORT WriteString, WriteLn;
PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;
VAR ok: BOOLEAN;
BEGIN
  ok := Startup("Consolas", VAL(SHORTREAL, 16.0));
  WriteString("d2d: "); YN(ok); WriteLn
END T90246TermRender.
