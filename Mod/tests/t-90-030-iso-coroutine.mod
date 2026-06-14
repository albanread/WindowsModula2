MODULE t90030;
IMPORT STextIO, SWholeIO;
FROM COROUTINES IMPORT NEWCOROUTINE, TRANSFER, CURRENT, COROUTINE;
FROM SYSTEM IMPORT ADR, SIZE;

VAR main, worker : COROUTINE;
    ws : ARRAY [0..8191] OF CHAR;
    n : INTEGER;

PROCEDURE Worker;
BEGIN
  LOOP
    STextIO.WriteString("co ");
    SWholeIO.WriteInt(n, 0);
    STextIO.WriteLn;
    TRANSFER(worker, main)
  END
END Worker;

BEGIN
  main := CURRENT();
  NEWCOROUTINE(Worker, ADR(ws), SIZE(ws), worker);
  n := 1; TRANSFER(main, worker);
  n := 2; TRANSFER(main, worker);
  STextIO.WriteString("end"); STextIO.WriteLn
END t90030.
