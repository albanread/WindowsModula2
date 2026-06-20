MODULE T90261BTerminalShim;
(*
 * Group 90 — PaneShell S1, D4 shim-equivalence gate (sprints amendment K).
 * The singleton API is a behavioural shim over the *current* instance, so:
 *  (1) the SAME sequence of singleton ops produces identical cells whether run
 *      on the default instance or on an explicit Create/Use instance (the shim
 *      is a behavioural equivalent, not merely a link); and
 *  (2) interleaving: after Use(x), a singleton write lands in x and leaves the
 *      default untouched (the current-instance routing is correct).
 *
 * EXPECTED:
 * shim-eq: Y
 * landed: Y
 * default-clean: Y
 *)
FROM Terminal IMPORT Instance, Create, Use, Free, Init, GotoXY, Write,
  CellChar, CellCharOf;
FROM StrIO IMPORT WriteString, WriteLn;

VAR x: Instance; d, e: CHAR;
BEGIN
  (* (1) singleton path on the default, then the same ops on an explicit instance *)
  Use(NIL); Init(30, 6); GotoXY(2, 1); Write("Hi");
  d := CellChar(2, 1);                       (* 'H' via the singleton (current = default) *)

  x := Create(30, 6); Use(x); GotoXY(2, 1); Write("Hi");
  e := CellCharOf(x, 2, 1);                  (* 'H' via the explicit instance *)

  WriteString("shim-eq: ");
  IF d = e THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;

  (* (2) interleave: a singleton write after Use(x) lands in x ... *)
  Use(x); GotoXY(0, 0); Write("Z");
  WriteString("landed: ");
  IF CellCharOf(x, 0, 0) = 'Z' THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;

  (* ... and not in the default *)
  Use(NIL);
  WriteString("default-clean: ");
  IF CellChar(0, 0) # 'Z' THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;

  Free(x)
END T90261BTerminalShim.
