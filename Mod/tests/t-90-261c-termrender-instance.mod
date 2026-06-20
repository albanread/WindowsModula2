MODULE T90261CTermRenderInstance;
(*
 * Group 90 — PaneShell S1: TermRender is instanceable to the construction
 * level. Two renderer instances each create their own DirectWrite text format
 * (headless: shared factory + per-instance format — D2D HwndRenderTarget /
 * Attach / Paint need a real window and are exercised by the manual AOT demo).
 * Coexistence proven by per-instance FormatReady read-back. Back-compat of the
 * singleton path is gated by t-90-246.
 *
 * EXPECTED:
 * two-formats: Y
 *)
FROM TermRender IMPORT Instance, Create, Free, FormatReady;
FROM StrIO IMPORT WriteString, WriteLn;

VAR a, b: Instance;
BEGIN
  a := Create("Consolas",      VAL(SHORTREAL, 16.0));
  b := Create("Cascadia Mono", VAL(SHORTREAL, 14.0));
  WriteString("two-formats: ");
  IF FormatReady(a) AND FormatReady(b) THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;
  Free(a); Free(b)
END T90261CTermRenderInstance.
