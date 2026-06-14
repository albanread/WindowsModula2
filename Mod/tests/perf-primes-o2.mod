MODULE PerfPrimesO2;
IMPORT STextIO, SWholeIO;

VAR
  outer     : INTEGER;
  candidate : INTEGER;
  divisor   : INTEGER;
  count     : INTEGER;
  sum       : INTEGER;
  isPrime   : BOOLEAN;

BEGIN
  outer := 0;
  sum := 0;
  WHILE outer < 15000 DO
    candidate := 2;
    count := 0;
    WHILE candidate <= 2000 DO
      isPrime := TRUE;
      divisor := 2;
      WHILE divisor * divisor <= candidate DO
        IF candidate MOD divisor = 0 THEN
          isPrime := FALSE;
          divisor := candidate;
        ELSE
          divisor := divisor + 1;
        END;
      END;
      IF isPrime THEN
        count := count + 1;
      END;
      candidate := candidate + 1;
    END;
    sum := sum + count;
    IF sum >= 1000000000 THEN
      sum := sum - 1000000000;
    END;
    outer := outer + 1;
  END;
  SWholeIO.WriteInt(sum, 0);
  STextIO.WriteLn;
END PerfPrimesO2.