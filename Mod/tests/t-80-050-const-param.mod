MODULE t80010;
IMPORT STextIO, SWholeIO;
PROCEDURE Sum(CONST a : INTEGER; CONST b : INTEGER) : INTEGER;
BEGIN
  RETURN a + b
END Sum;
VAR x : INTEGER;
BEGIN
  x := 10;
  SWholeIO.WriteInt(Sum(x, 5), 0); STextIO.WriteLn;          (* 15 *)
  SWholeIO.WriteInt(Sum(x + 1, x * 2), 0); STextIO.WriteLn   (* 31 *)
END t80010.
