MODULE T90264GameViewGpuConstruct;
(*
 * Group 90 — PaneShell S4 (closes P1): GameViewGpu is instanceable. Two GPU
 * game surfaces coexist, and — the load-bearing intra-P1 edge — each owns its
 * OWN distinct ShaderView instance (its GPU device); GameViewGpu has no device
 * of its own. Headless: the CPU model + the owned ShaderView are allocated, but
 * Attach (which Attaches the wrapped ShaderView's device/swapchain) needs a real
 * window, so two-games-presenting is the manual AOT demo.
 *
 * EXPECTED:
 * two-gpu: Y
 * distinct-renderers: Y
 *)
FROM GameViewGpu IMPORT Instance, Create, Free, Renderer;
FROM StrIO IMPORT WriteString, WriteLn;

VAR a, b: Instance;
BEGIN
  a := Create();
  b := Create();
  WriteString("two-gpu: ");
  IF (a # NIL) AND (b # NIL) AND (a # b) THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;
  WriteString("distinct-renderers: ");
  IF (Renderer(a) # NIL) AND (Renderer(b) # NIL) AND (Renderer(a) # Renderer(b))
    THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;
  Free(a); Free(b)
END T90264GameViewGpuConstruct.
