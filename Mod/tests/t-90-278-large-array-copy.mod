MODULE t90278;
(* Whole-aggregate copy of a >64K-element array (and a large record) must lower to
   memmove, not a by-value aggregate load/store — regression test for the LLVM
   SelectionDAG segfault on large by-value aggregates. *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
TYPE Big = ARRAY [0..65535] OF CHAR;
     Rec = RECORD buf: Big; tag: CARDINAL END;
VAR g, h: Big; p, q: Rec; i: CARDINAL;
BEGIN
  FOR i := 0 TO 65535 DO h[i] := 'x' END;
  h[0] := 'A'; h[65535] := 'Z';
  g := h;                                    (* large ARRAY copy *)
  WriteInt(VAL(INTEGER, ORD(g[0])), 0); WriteLn;       (* 65 *)
  WriteInt(VAL(INTEGER, ORD(g[65535])), 0); WriteLn;   (* 90 *)
  q.buf := h; q.tag := 7;
  p := q;                                    (* large RECORD copy *)
  WriteInt(VAL(INTEGER, ORD(p.buf[65535])), 0); WriteLn;  (* 90 *)
  WriteInt(VAL(INTEGER, p.tag), 0); WriteLn               (* 7 *)
END t90278.
