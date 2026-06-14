MODULE T90252SystemProcess;
(*
 * Group 90 — PIM coroutines via SYSTEM, using the SYSTEM.PROCESS handle type
 * (not just ADDRESS). NEWPROCESS creates a worker; main ping-pongs control to it
 * with TRANSFER; the worker prints a counter each time it is resumed.
 *
 * EXPECTED:
 * tick 1
 * tick 2
 * done
 *)
FROM SYSTEM IMPORT PROCESS, NEWPROCESS, TRANSFER, ADR, SIZE;
IMPORT STextIO, SWholeIO;
VAR main, worker: PROCESS; ws: ARRAY [0..4095] OF BYTE; n: INTEGER;
PROCEDURE Worker;
BEGIN
  LOOP
    STextIO.WriteString("tick "); SWholeIO.WriteInt(n, 0); STextIO.WriteLn;
    TRANSFER(worker, main)
  END
END Worker;
BEGIN
  n := 0;
  NEWPROCESS(Worker, ADR(ws), SIZE(ws), worker);
  n := 1; TRANSFER(main, worker);
  n := 2; TRANSFER(main, worker);
  STextIO.WriteString("done"); STextIO.WriteLn
END T90252SystemProcess.
