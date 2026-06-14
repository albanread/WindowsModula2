MODULE t90050;
IMPORT STextIO, SWholeIO;

CLASS Counter;
  VAR n : INTEGER;
  PROCEDURE Init(start : INTEGER);
  BEGIN
    n := start              (* bare field = SELF.n *)
  END Init;
  PROCEDURE Bump;
  BEGIN
    SELF.n := SELF.n + 1    (* explicit SELF.field *)
  END Bump;
  PROCEDURE Add(d : INTEGER) : INTEGER;
  BEGIN
    n := n + d;
    RETURN n
  END Add;
END Counter;

VAR c : Counter;

BEGIN
  NEW(c);
  c.Init(10);
  c.Bump; c.Bump; c.Bump;          (* 13 *)
  SWholeIO.WriteInt(c.Add(7), 0);  (* 20, returned *)
  STextIO.WriteLn;
  SWholeIO.WriteInt(c.n, 0);       (* 20, direct field *)
  STextIO.WriteLn
END t90050.
