MODULE t40060;
IMPORT STextIO, SWholeIO;

TYPE
  Point = RECORD x, y : INTEGER; END;
  Line  = RECORD a, b : Point; END;

VAR
  p  : Point;
  ln : Line;
  pts : ARRAY [0..2] OF Point;
  i  : INTEGER;

PROCEDURE Show(label : ARRAY OF CHAR; n : INTEGER);
BEGIN
  STextIO.WriteString(label);
  SWholeIO.WriteInt(n, 0);
  STextIO.WriteLn
END Show;

BEGIN
  (* simple record *)
  WITH p DO
    x := 3; y := 4
  END;
  Show("p.x=", p.x);
  Show("p.y=", p.y);

  (* array element as the WITH designator *)
  FOR i := 0 TO 2 DO
    WITH pts[i] DO
      x := i; y := i * 10
    END
  END;
  Show("pts1.y=", pts[1].y);
  Show("pts2.x=", pts[2].x);

  (* nested WITH; inner field 'x' belongs to the inner Point *)
  WITH ln DO
    WITH a DO x := 1; y := 2 END;
    WITH b DO x := 5; y := 6 END
  END;
  Show("ln.a.x=", ln.a.x);
  Show("ln.b.y=", ln.b.y)
END t40060.
