MODULE T90263BShaderConstruct;
(*
 * Group 90 — PaneShell S3: ShaderView (Direct3D11) is instanceable. Two
 * renderer instances coexist at the CONSTRUCTION level — distinct, non-NIL,
 * freeable. The device + DXGI swapchain are created in Attach (outputWindow :=
 * hwnd rejects a message-only window), so Attach/Frame/present coexistence is
 * the manual AOT demo (two ShaderViews each presenting to their own real HWND).
 * This headless gate proves the per-instance allocation + teardown; S4's
 * GameViewGpu then owns one ShaderView instance per game.
 *
 * EXPECTED:
 * two-shaders: Y
 * freed: Y
 *)
FROM ShaderView IMPORT Instance, Create, Free;
FROM StrIO IMPORT WriteString, WriteLn;

VAR a, b: Instance;
BEGIN
  a := Create();
  b := Create();
  WriteString("two-shaders: ");
  IF (a # NIL) AND (b # NIL) AND (a # b) THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;
  Free(a); Free(b);
  WriteString("freed: ");
  IF (a = NIL) AND (b = NIL) THEN WriteString("Y") ELSE WriteString("N") END; WriteLn
END T90263BShaderConstruct.
