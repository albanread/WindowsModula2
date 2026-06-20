MODULE T90262BCanvasConstruct;
(*
 * Group 90 — PaneShell S2: Canvas2D (Direct2D) is instanceable to the
 * construction level. Two canvas instances each create their own DirectWrite
 * text format from the shared factory (headless: factory + format only —
 * Attach/Begin/draw need a real window because a D2D HwndRenderTarget rejects a
 * message-only window, exercised by the manual AOT demo). Coexistence proven by
 * per-instance FormatReady read-back; the DWrite factory is idempotent (S1) so
 * the two canvases don't clobber it.
 *
 * EXPECTED:
 * two-canvas: Y
 *)
FROM Canvas2D IMPORT Instance, Create, Free, FormatReady;
FROM StrIO IMPORT WriteString, WriteLn;

VAR a, b: Instance;
BEGIN
  a := Create();
  b := Create();
  WriteString("two-canvas: ");
  IF FormatReady(a) AND FormatReady(b) THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;
  Free(a); Free(b)
END T90262BCanvasConstruct.
