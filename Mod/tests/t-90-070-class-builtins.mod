MODULE t90070;
IMPORT STextIO, SWholeIO;
CLASS Node;
  VAR v : INTEGER;
  PROCEDURE Me() : Node;
  BEGIN RETURN SELF END Me;
END Node;
VAR n, m : Node;
BEGIN
  NEW(n); n.v := 42;
  m := n.Me();
  SWholeIO.WriteInt(m.v, 0); STextIO.WriteLn;
  n := EMPTY;
  IF n = EMPTY THEN STextIO.WriteString("empty") ELSE STextIO.WriteString("not") END;
  STextIO.WriteLn;
  DESTROY(m); STextIO.WriteString("freed"); STextIO.WriteLn
END t90070.
