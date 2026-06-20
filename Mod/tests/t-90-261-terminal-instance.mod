MODULE T90261TerminalInstance;
(*
 * Group 90 — PaneShell S1: the text-grid surface (Terminal) is instanceable.
 * Two independent Terminal instances of different sizes hold DISTINCT cell
 * content at the same time (the "two of the same surface can't coexist"
 * obstacle, removed), read back per-instance with CellCharOf regardless of
 * which is current. Per-instance state is heap-allocated, so the module still
 * loads under JIT. The eagerly-created default (singleton) instance is left
 * untouched by writes routed to the explicit instances.
 *
 * EXPECTED:
 * a00: A
 * b00: B
 * acols: 20
 * bcols: 40
 * defok: Y
 *)
FROM Terminal IMPORT Instance, Create, Use, Free, CellCharOf, GotoXY, Write,
  Cols, CellChar;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR a, b: Instance; s: ARRAY [0..1] OF CHAR;
BEGIN
  a := Create(20, 5);
  b := Create(40, 8);

  Use(a); GotoXY(0, 0); Write("Alpha");
  Use(b); GotoXY(0, 0); Write("Bravo");

  s[1] := 0C;
  s[0] := CellCharOf(a, 0, 0); WriteString("a00: "); WriteString(s); WriteLn;
  s[0] := CellCharOf(b, 0, 0); WriteString("b00: "); WriteString(s); WriteLn;

  Use(a); WriteString("acols: "); WriteCard(Cols(), 1); WriteLn;
  Use(b); WriteString("bcols: "); WriteCard(Cols(), 1); WriteLn;

  Use(NIL);                        (* the default instance, never written to here *)
  WriteString("defok: ");
  IF CellChar(0, 0) = ' ' THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;

  Free(a); Free(b)
END T90261TerminalInstance.
