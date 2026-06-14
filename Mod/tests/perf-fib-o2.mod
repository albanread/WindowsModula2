MODULE PerfFibO2;
IMPORT STextIO, SWholeIO;

VAR
  outer : INTEGER;
  i     : INTEGER;
  a     : INTEGER;
  b     : INTEGER;
  next  : INTEGER;
  sum   : INTEGER;

BEGIN
  outer := 0;
  sum := 0;
  WHILE outer < 9600000 DO
    a := 0;
    b := 1;
    i := 0;
    WHILE i < 32 DO
      next := a + b;
      a := b;
      b := next;
      i := i + 1;
    END;
    sum := sum + a;
    IF sum >= 1000000000 THEN
      sum := sum - 1000000000;
    END;
    outer := outer + 1;
  END;
  SWholeIO.WriteInt(sum, 0);
  STextIO.WriteLn;
END PerfFibO2.