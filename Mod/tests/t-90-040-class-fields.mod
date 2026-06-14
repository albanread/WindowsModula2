MODULE t90040;
IMPORT STextIO, SWholeIO;

CLASS Point;
  VAR x, y : INTEGER;
END Point;

VAR p, q : Point;

BEGIN
  NEW(p);
  p.x := 30; p.y := 12;
  NEW(q);
  q.x := 100; q.y := 1;
  SWholeIO.WriteInt(p.x + p.y, 0); STextIO.WriteLn;   (* 42 *)
  SWholeIO.WriteInt(q.x + q.y, 0); STextIO.WriteLn;   (* 101 *)
  q := p;                 (* reference assignment: q now aliases p *)
  q.x := 7;
  SWholeIO.WriteInt(p.x, 0); STextIO.WriteLn          (* 7 (aliased) *)
END t90040.
