MODULE T90219WinrtElapsedTime;
(*
 * Group 90 — M2WINRT: ElapsedTime, high-resolution timing via DIRECT
 * Windows QueryPerformanceCounter/Frequency + Sleep from M2 (no Rust shim).
 * Timing is non-deterministic, so the assertions are bulletproof properties:
 * after Delay(50) at least ~10ms is measured (Sleep never returns early), and
 * the microsecond reading is >= the millisecond reading.
 *
 * EXPECTED:
 * slept (>=10ms): Y
 * micros >= millis: Y
 *)
FROM ElapsedTime IMPORT Timer, StartTimer, ElapsedMillis, ElapsedMicros, Delay;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR t: Timer; m, us: CARDINAL;
BEGIN
  StartTimer(t);
  Delay(50);
  m := ElapsedMillis(t);
  us := ElapsedMicros(t);
  WriteString("slept (>=10ms): "); YN(m >= 10); WriteLn;
  WriteString("micros >= millis: "); YN(us >= m); WriteLn
END T90219WinrtElapsedTime.
