MODULE PerfSieveO2;
IMPORT STextIO, SWholeIO;

TYPE
  FlagArray = ARRAY [0..4095] OF INTEGER;

VAR
  flags  : FlagArray;
  outer  : INTEGER;
  i      : INTEGER;
  j      : INTEGER;
  count  : INTEGER;
  sum    : INTEGER;

BEGIN
  outer := 0;
  sum := 0;
  WHILE outer < 18000 DO
    i := 0;
    WHILE i <= 4095 DO
      flags[i] := 1;
      i := i + 1;
    END;
    flags[0] := 0;
    flags[1] := 0;
    i := 2;
    WHILE i * i <= 4095 DO
      IF flags[i] # 0 THEN
        j := i * i;
        WHILE j <= 4095 DO
          flags[j] := 0;
          j := j + i;
        END;
      END;
      i := i + 1;
    END;
    count := 0;
    i := 2;
    WHILE i <= 4095 DO
      count := count + flags[i];
      i := i + 1;
    END;
    sum := sum + count;
    IF sum >= 1000000000 THEN
      sum := sum - 1000000000;
    END;
    outer := outer + 1;
  END;
  SWholeIO.WriteInt(sum, 0);
  STextIO.WriteLn;
END PerfSieveO2.