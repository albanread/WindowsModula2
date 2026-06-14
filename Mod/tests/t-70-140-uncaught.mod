MODULE t7140;

FROM TextIO IMPORT WriteString, WriteLn;
IMPORT StdChans;

VAR a: ARRAY [0..3] OF INTEGER;
    i, x: INTEGER;

BEGIN
  WriteString(StdChans.StdOutChan(), "before");
  WriteLn(StdChans.StdOutChan());
  i := 9;
  x := a[i];           (* uncaught indexException *)
  WriteString(StdChans.StdOutChan(), "after");
  WriteLn(StdChans.StdOutChan());
END t7140.
