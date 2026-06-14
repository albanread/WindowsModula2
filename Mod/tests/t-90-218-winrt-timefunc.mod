MODULE T90218WinrtTimeFunc;
(*
 * Group 90 — M2WINRT: TimeFunc, proleptic-Gregorian calendar math
 * over SysClock.DateTime. Known-answer (cross-checked against an independent
 * reference): weekdays (Sunday=0..Saturday=6), ANSI-C time_t (the famous
 * 1234567890 = 2009-02-13 23:31:30), DOS/FAT pack+unpack round-trip, and
 * DateTime ordering.
 *
 * EXPECTED:
 * dow 4 6 4 4
 * 0
 * 1000000000
 * 1234567890
 * 1709208000
 * rt 2009-2-13 23:31:30
 * dos 23757 29654
 * undos 2026-6-13 14:30:44
 * cmp -1 1 0
 *)
FROM TimeFunc IMPORT DateTime, GetDayOfWeek, CompareTime,
  DateTimeToC, CToDateTime, DateTimeToDos, DosToDateTime;
FROM SysClock IMPORT Month, Day, Hour, Min, Sec, Fraction, UTCDiff;
FROM NumberIO IMPORT WriteCard, WriteInt;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE Mk (y, mo, d, h, mi, s: CARDINAL): DateTime;
  VAR dt: DateTime;
BEGIN
  dt.year := y; dt.month := VAL(Month, mo); dt.day := VAL(Day, d);
  dt.hour := VAL(Hour, h); dt.minute := VAL(Min, mi); dt.second := VAL(Sec, s);
  dt.fractions := VAL(Fraction, 0); dt.zone := VAL(UTCDiff, 0); dt.SummerTimeFlag := FALSE;
  RETURN dt
END Mk;

PROCEDURE PutDT (dt: DateTime);
BEGIN
  WriteCard(dt.year, 1); WriteString("-"); WriteCard(VAL(CARDINAL, dt.month), 1);
  WriteString("-"); WriteCard(VAL(CARDINAL, dt.day), 1); WriteString(" ");
  WriteCard(VAL(CARDINAL, dt.hour), 1); WriteString(":"); WriteCard(VAL(CARDINAL, dt.minute), 1);
  WriteString(":"); WriteCard(VAL(CARDINAL, dt.second), 1)
END PutDT;

VAR dt: DateTime; c, date, time: CARDINAL;
BEGIN
  WriteString("dow ");
  WriteCard(ORD(GetDayOfWeek(Mk(1970, 1, 1, 0, 0, 0))), 1); WriteString(" ");
  WriteCard(ORD(GetDayOfWeek(Mk(2000, 1, 1, 0, 0, 0))), 1); WriteString(" ");
  WriteCard(ORD(GetDayOfWeek(Mk(2024, 2, 29, 0, 0, 0))), 1); WriteString(" ");
  WriteCard(ORD(GetDayOfWeek(Mk(1776, 7, 4, 0, 0, 0))), 1); WriteLn;

  DateTimeToC(Mk(1970, 1, 1, 0, 0, 0), c);    WriteCard(c, 1); WriteLn;
  DateTimeToC(Mk(2001, 9, 9, 1, 46, 40), c);  WriteCard(c, 1); WriteLn;
  DateTimeToC(Mk(2009, 2, 13, 23, 31, 30), c); WriteCard(c, 1); WriteLn;
  DateTimeToC(Mk(2024, 2, 29, 12, 0, 0), c);  WriteCard(c, 1); WriteLn;

  CToDateTime(1234567890, dt); WriteString("rt "); PutDT(dt); WriteLn;

  DateTimeToDos(Mk(2026, 6, 13, 14, 30, 44), date, time);
  WriteString("dos "); WriteCard(date, 1); WriteString(" "); WriteCard(time, 1); WriteLn;
  DosToDateTime(date, time, dt); WriteString("undos "); PutDT(dt); WriteLn;

  WriteString("cmp ");
  WriteInt(CompareTime(Mk(2000, 1, 1, 0, 0, 0), Mk(2000, 1, 1, 0, 0, 1)), 1); WriteString(" ");
  WriteInt(CompareTime(Mk(2001, 1, 1, 0, 0, 0), Mk(2000, 1, 1, 0, 0, 0)), 1); WriteString(" ");
  WriteInt(CompareTime(Mk(2000, 5, 5, 5, 5, 5), Mk(2000, 5, 5, 5, 5, 5)), 1); WriteLn
END T90218WinrtTimeFunc.
