MODULE T90263GameViewInstance;
(*
 * Group 90 — PaneShell S3: the indexed-colour surface (GameView) is
 * instanceable. Two independent indexed framebuffers of different sizes hold
 * DISTINCT content at the same time, read back per-instance with IndexAt —
 * fully headless (CPU buffer, no window). Each instance's index + scaled-RGBA
 * buffers are heap-allocated (the §0.4 mandate), so the module still loads
 * under JIT.
 *
 * EXPECTED:
 * a-dot: 9
 * a-bg: 4
 * b-bg: 7
 * a-width: 64
 *)
FROM GameView IMPORT Instance, Create, Use, Free, IndexAt, Cls, Pset, Width;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR a, b: Instance;
BEGIN
  a := Create(64, 40, 2);
  b := Create(32, 20, 3);

  Use(a); Cls(4); Pset(5, 5, 9);    (* a: index 4 background, index 9 dot at (5,5) *)
  Use(b); Cls(7);                    (* b: index 7 background *)

  WriteString("a-dot: ");   WriteCard(IndexAt(a, 5, 5), 1); WriteLn;   (* 9 *)
  WriteString("a-bg: ");    WriteCard(IndexAt(a, 0, 0), 1); WriteLn;   (* 4 *)
  WriteString("b-bg: ");    WriteCard(IndexAt(b, 0, 0), 1); WriteLn;   (* 7 *)
  Use(a); WriteString("a-width: "); WriteCard(Width(), 1); WriteLn;    (* 64 *)

  Free(a); Free(b)
END T90263GameViewInstance.
