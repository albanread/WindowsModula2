IMPLEMENTATION MODULE ElapsedTime;

FROM SYSTEM IMPORT ADR;
FROM System_Performance IMPORT QueryPerformanceCounter, QueryPerformanceFrequency;
FROM System_Threading IMPORT Sleep;
FROM WIN32 IMPORT BOOL, DWORD;

VAR
  Freq: INTEGER64;   (* performance-counter ticks per second, queried once at load *)
  gOk:  BOOL;        (* sink for the init query's BOOL result *)

PROCEDURE StartTimer (VAR t: Timer);
  VAR ok: BOOL;
BEGIN
  ok := QueryPerformanceCounter(ADR(t.start))
END StartTimer;

PROCEDURE Ticks (t: Timer): CARDINAL;
  (* non-negative tick delta since the timer origin (counter is monotonic) *)
  VAR now: INTEGER64; ok: BOOL;
BEGIN
  ok := QueryPerformanceCounter(ADR(now));
  RETURN VAL(CARDINAL, now - t.start)
END Ticks;

PROCEDURE ElapsedMillis (t: Timer): CARDINAL;
BEGIN
  RETURN Ticks(t) * 1000 DIV VAL(CARDINAL, Freq)
END ElapsedMillis;

PROCEDURE ElapsedMicros (t: Timer): CARDINAL;
BEGIN
  RETURN Ticks(t) * 1000000 DIV VAL(CARDINAL, Freq)
END ElapsedMicros;

PROCEDURE Delay (millis: CARDINAL);
BEGIN
  Sleep(VAL(DWORD, millis))
END Delay;

BEGIN
  Freq := 1;   (* guard against a divide-by-zero if the query somehow fails *)
  gOk := QueryPerformanceFrequency(ADR(Freq))
END ElapsedTime.
