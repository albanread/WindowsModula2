MODULE t90282;
(* GUARD: a base-class arm (matches any subtype) used as a catch-all after a
   specific arm (first-match-wins), and a nested GUARD inside an arm body. *)
IMPORT STextIO;
FROM SWholeIO IMPORT WriteInt;

ABSTRACT CLASS Node;
  ABSTRACT PROCEDURE Id() : INTEGER;
END Node;

CLASS Leaf;
  INHERIT Node;
  OVERRIDE PROCEDURE Id() : INTEGER;
  BEGIN RETURN 7 END Id;
END Leaf;

CLASS Branch;
  INHERIT Node;
  VAR n : INTEGER;
  OVERRIDE PROCEDURE Id() : INTEGER;
  BEGIN RETURN n END Id;
END Branch;

VAR lf : Leaf; br : Branch;

PROCEDURE Visit (x : Node);
BEGIN
  GUARD x AS
    b : Branch DO
      STextIO.WriteString("branch ");
      GUARD x AS                       (* nested GUARD via the base-class arm *)
        nn : Node DO WriteInt(b.n, 0)
      END;
      STextIO.WriteLn
  | a : Node DO                        (* base-class catch-all (matches Leaf) *)
      STextIO.WriteString("node "); WriteInt(a.Id(), 0); STextIO.WriteLn
  END
END Visit;

BEGIN
  NEW(lf);
  NEW(br); br.n := 42;
  Visit(br);    (* branch 42 *)
  Visit(lf)     (* node 7 *)
END t90282.
