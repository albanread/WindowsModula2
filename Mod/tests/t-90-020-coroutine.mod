MODULE t90020;
IMPORT STextIO, SWholeIO;
FROM SYSTEM IMPORT NEWPROCESS, TRANSFER, ADDRESS, ADR, SIZE;

VAR main, worker : ADDRESS;
    ws : ARRAY [0..4095] OF BYTE;
    count : INTEGER;

PROCEDURE Worker;
BEGIN
  LOOP
    STextIO.WriteString("worker ");
    SWholeIO.WriteInt(count, 0);
    STextIO.WriteLn;
    TRANSFER(worker, main)
  END
END Worker;

BEGIN
  count := 0;
  NEWPROCESS(Worker, ADR(ws), SIZE(ws), worker);
  count := 1; TRANSFER(main, worker);
  count := 2; TRANSFER(main, worker);
  count := 3; TRANSFER(main, worker);
  STextIO.WriteString("done"); STextIO.WriteLn
END t90020.
