MODULE t90281;
(* GUARD native-class discrimination: dispatch on dynamic type, bind a narrowed
   read-only view per arm (field + method access through it), first-match-wins,
   and the ELSE arm for an unmatched concrete subclass. *)
IMPORT STextIO;
FROM SWholeIO IMPORT WriteInt;

ABSTRACT CLASS Shape;
  ABSTRACT PROCEDURE Area() : INTEGER;
END Shape;

CLASS Circle;
  INHERIT Shape;
  VAR r : INTEGER;
  OVERRIDE PROCEDURE Area() : INTEGER;
  BEGIN RETURN r * r * 3 END Area;
END Circle;

CLASS Square;
  INHERIT Shape;
  VAR side : INTEGER;
  OVERRIDE PROCEDURE Area() : INTEGER;
  BEGIN RETURN side * side END Area;
END Square;

CLASS Triangle;
  INHERIT Shape;
  OVERRIDE PROCEDURE Area() : INTEGER;
  BEGIN RETURN 0 END Area;
END Triangle;

VAR c : Circle; sq : Square; t : Triangle;

PROCEDURE Describe (x : Shape);
BEGIN
  GUARD x AS
    cc : Circle DO
      STextIO.WriteString("circle r="); WriteInt(cc.r, 0);
      STextIO.WriteString(" area="); WriteInt(cc.Area(), 0); STextIO.WriteLn
  | ss : Square DO
      STextIO.WriteString("square s="); WriteInt(ss.side, 0); STextIO.WriteLn
  ELSE
    STextIO.WriteString("unknown"); STextIO.WriteLn
  END
END Describe;

BEGIN
  NEW(c);  c.r := 5;
  NEW(sq); sq.side := 4;
  NEW(t);
  Describe(c);    (* circle r=5 area=75 *)
  Describe(sq);   (* square s=4 *)
  Describe(t)     (* unknown (Triangle not guarded -> ELSE) *)
END t90281.
