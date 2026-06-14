MODULE PerfFactorialO2;
IMPORT STextIO, SWholeIO;

VAR
  outer : INTEGER;
  i     : INTEGER;
  fact  : INTEGER;
  sum   : INTEGER;

BEGIN
  outer := 0;
  sum := 0;
  WHILE outer < 21000000 DO
    fact := 1;
    i := 1;
    WHILE i <= 12 DO
      fact := fact * i;
      sum := sum + fact;
      IF sum >= 1000000000 THEN
        sum := sum - 1000000000;
      END;
      i := i + 1;
    END;
    outer := outer + 1;
  END;
  SWholeIO.WriteInt(sum, 0);
  STextIO.WriteLn;
END PerfFactorialO2.