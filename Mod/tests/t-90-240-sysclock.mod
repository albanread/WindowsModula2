MODULE T90240SysClock;
(*
 * Group 90 — runtime self-hosting: ISO SysClock.GetClock now calls the Win32
 * GetSystemTime directly (no Rust nm2_sysclock_now shim) and fills the DateTime
 * record in M2. We can't assert an exact instant, but a freshly-read clock must
 * be a structurally valid DateTime and carry a plausible current year, proving
 * the direct Win32 read works end to end.
 *
 * EXPECTED:
 * valid: Y
 * year ok: Y
 * utc zone: Y
 *)
FROM SysClock IMPORT DateTime, GetClock, IsValidDateTime;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR dt: DateTime;
BEGIN
  GetClock(dt);
  WriteString("valid: "); YN(IsValidDateTime(dt)); WriteLn;
  WriteString("year ok: "); YN((dt.year >= 2020) AND (dt.year <= 2100)); WriteLn;
  WriteString("utc zone: "); YN(dt.zone = 0); WriteLn
END T90240SysClock.
