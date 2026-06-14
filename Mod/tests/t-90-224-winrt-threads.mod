MODULE T90224WinrtThreads;
(*
 * Group 90 — M2WINRT: Threads. Real OS threads running M2 code, with
 * a recursive Win32 CRITICAL_SECTION lock — all via direct Win32 (CreateThread/
 * WaitForSingleObject/InitializeCriticalSection/...). 8 threads each increment a
 * shared counter 50000 times under the lock; correct mutual exclusion (no lost
 * updates) means the total is exactly 8*50000 = 400000, and every Join returns
 * in time. (Feasible because NewM2's default/AOT mode has no GC, so a procedure
 * runs on a thread NewM2 did not create without root registration.)
 *
 * EXPECTED:
 * joined all: Y
 * mutual exclusion (400000): Y
 *)
FROM SYSTEM IMPORT ADDRESS;
FROM Threads IMPORT Lock, Thread, ThreadProc, InitLock, Acquire, Release,
  DestroyLock, Spawn, Join, CloseThread;
FROM StrIO IMPORT WriteString, WriteLn;

CONST NThreads = 8; PerThread = 50000;
VAR gLock: Lock; gCounter: CARDINAL;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

PROCEDURE Worker (param: ADDRESS): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  FOR i := 1 TO PerThread DO
    Acquire(gLock); INC(gCounter); Release(gLock)
  END;
  RETURN 0
END Worker;

VAR threads: ARRAY [0 .. NThreads-1] OF Thread; i: CARDINAL; allJoined: BOOLEAN;
BEGIN
  InitLock(gLock);
  gCounter := 0;
  FOR i := 0 TO NThreads-1 DO threads[i] := Spawn(Worker, NIL) END;
  allJoined := TRUE;
  FOR i := 0 TO NThreads-1 DO
    IF NOT Join(threads[i], 30000) THEN allJoined := FALSE END;
    CloseThread(threads[i])
  END;
  DestroyLock(gLock);
  WriteString("joined all: "); YN(allJoined); WriteLn;
  WriteString("mutual exclusion (400000): "); YN(gCounter = NThreads * PerThread); WriteLn
END T90224WinrtThreads.
