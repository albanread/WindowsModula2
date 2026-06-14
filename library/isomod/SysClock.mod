(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-15 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - Self-hosted: `GetClock` calls the Win32 `GetSystemTime` directly
       (kernel32, UTC) and fills the `DateTime` record itself, in M2 —
       no Rust runtime shim. Filling the record from M2 also drops the
       hand-maintained byte-layout matching the old shim required.
       Win32 SYSTEMTIME carries milliseconds (0..999); DateTime.fractions
       is hundredths of a second (0..99), so we divide by 10. The time is
       UTC, hence zone = 0 and SummerTimeFlag = FALSE.
     - `SetClock` is intentionally a no-op — programs setting the system
       clock are rare, the host OS gates this on privileges anyway, and
       we'd rather not surface a half-working API. `CanSetClock`
       returns FALSE so well-behaved callers gate on it first.
     - The XDS source had a `[UNINTERRUPTIBLE]` pragma on `GetClock`; a
       single GetSystemTime call into a local record is effectively
       atomic for our purposes, so the pragma is dropped.
*)
IMPLEMENTATION MODULE SysClock;

IMPORT SYSTEM;
FROM Foundation IMPORT SYSTEMTIME;
FROM System_SystemInformation IMPORT GetSystemTime;

PROCEDURE CanGetClock(): BOOLEAN;
BEGIN
  RETURN TRUE;
END CanGetClock;

PROCEDURE CanSetClock(): BOOLEAN;
BEGIN
  RETURN FALSE;
END CanSetClock;

PROCEDURE IsValidDateTime(d: DateTime): BOOLEAN;

  CONST m30days = BITSET{4, 6, 9, 11};

  PROCEDURE isLeap(y: CARDINAL): BOOLEAN;
  BEGIN
    RETURN ((y MOD 4 = 0) & (y MOD 100 # 0)) OR (y MOD 400 = 0);
  END isLeap;

BEGIN
  IF (d.day < 1) OR (d.day > 31) THEN RETURN FALSE END;
  IF (d.month < 1) OR (d.month > 12) THEN RETURN FALSE END;
  IF d.year < 1 THEN RETURN FALSE END;
  IF (VAL(CARDINAL, d.month) IN m30days) & (d.day > 30) THEN RETURN FALSE END;
  IF (d.month = 2) & (d.day > 28 + VAL(CARDINAL, ORD(isLeap(d.year)))) THEN RETURN FALSE END;
  IF (d.hour > 23) OR (d.minute > 59) OR (d.second > 59) THEN RETURN FALSE END;
  RETURN TRUE;
END IsValidDateTime;

PROCEDURE GetClock(VAR userData: DateTime);
  VAR st: SYSTEMTIME;
BEGIN
  GetSystemTime(SYSTEM.ADR(st));                  (* Win32, UTC *)
  userData.year      := VAL(CARDINAL, st.wYear);
  userData.month     := VAL(Month,    st.wMonth);
  userData.day       := VAL(Day,      st.wDay);
  userData.hour      := VAL(Hour,     st.wHour);
  userData.minute    := VAL(Min,      st.wMinute);
  userData.second    := VAL(Sec,      st.wSecond);
  userData.fractions := VAL(Fraction, VAL(CARDINAL, st.wMilliseconds) DIV 10);
  userData.zone      := 0;                          (* UTC *)
  userData.SummerTimeFlag := FALSE;
END GetClock;

PROCEDURE SetClock(userData: DateTime);
BEGIN
  (* No-op — see module comment. *)
END SetClock;

END SysClock.
