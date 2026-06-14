IMPLEMENTATION MODULE TimeFunc;

FROM SysClock IMPORT Month, Day, Hour, Min, Sec, Fraction, UTCDiff;

CONST
  Epoch1970 = 135140;   (* = DMYtoJulian(1, 1, 1970), days from the 1600 base *)

(* Day number from a Gregorian date, base 1600 (all operands non-negative). *)
PROCEDURE DMYtoJulian (d, mo, y: CARDINAL): CARDINAL;
  VAR month, year: CARDINAL;
BEGIN
  IF (y = 1600) AND (mo < 3) THEN
    IF mo = 1 THEN RETURN d - 1 ELSE RETURN d + 30 END
  END;
  month := mo; year := y;
  IF month > 2 THEN
    month := month - 3
  ELSE
    month := month + 9; year := year - 1
  END;
  year := year - 1600;
  RETURN ((year DIV 100) * 146097) DIV 4
       + ((year MOD 100) * 1461) DIV 4
       + ((153 * month) + 2) DIV 5
       + d + 59
END DMYtoJulian;

PROCEDURE GetDayOfWeek (dt: DateTime): DayOfWeek;
  VAR j: CARDINAL;
BEGIN
  j := DMYtoJulian(VAL(CARDINAL, dt.day), VAL(CARDINAL, dt.month), dt.year);
  RETURN VAL(DayOfWeek, (j + 6) MOD 7)   (* Julian day 0 is a Saturday (ORD 6) *)
END GetDayOfWeek;

PROCEDURE Cmp (l, r: CARDINAL): INTEGER;
BEGIN
  IF l < r THEN RETURN -1 ELSIF l > r THEN RETURN 1 ELSE RETURN 0 END
END Cmp;

PROCEDURE CompareTime (left, right: DateTime): INTEGER;
  VAR c: INTEGER;
BEGIN
  c := Cmp(left.year, right.year);                                   IF c # 0 THEN RETURN c END;
  c := Cmp(VAL(CARDINAL, left.month), VAL(CARDINAL, right.month));   IF c # 0 THEN RETURN c END;
  c := Cmp(VAL(CARDINAL, left.day), VAL(CARDINAL, right.day));       IF c # 0 THEN RETURN c END;
  c := Cmp(VAL(CARDINAL, left.hour), VAL(CARDINAL, right.hour));     IF c # 0 THEN RETURN c END;
  c := Cmp(VAL(CARDINAL, left.minute), VAL(CARDINAL, right.minute)); IF c # 0 THEN RETURN c END;
  c := Cmp(VAL(CARDINAL, left.second), VAL(CARDINAL, right.second)); IF c # 0 THEN RETURN c END;
  RETURN Cmp(VAL(CARDINAL, left.fractions), VAL(CARDINAL, right.fractions))
END CompareTime;

PROCEDURE DateTimeEqual (left, right: DateTime): BOOLEAN;
BEGIN RETURN CompareTime(left, right) = 0 END DateTimeEqual;

PROCEDURE DateTimeGreater (left, right: DateTime): BOOLEAN;
BEGIN RETURN CompareTime(left, right) > 0 END DateTimeGreater;

PROCEDURE DateTimeToC (dt: DateTime; VAR cdt: CARDINAL);
  VAR days: CARDINAL;
BEGIN
  days := DMYtoJulian(VAL(CARDINAL, dt.day), VAL(CARDINAL, dt.month), dt.year) - Epoch1970;
  cdt := (days * 86400
          + VAL(CARDINAL, dt.hour) * 3600
          + VAL(CARDINAL, dt.minute) * 60
          + VAL(CARDINAL, dt.second)) BAND 0FFFFFFFFH
END DateTimeToC;

PROCEDURE CToDateTime (cdt: CARDINAL; VAR dt: DateTime);
  VAR days, sod, z, era, doe, yoe, doy, mp, y, m, d: CARDINAL;
BEGIN
  cdt := cdt BAND 0FFFFFFFFH;
  days := cdt DIV 86400; sod := cdt MOD 86400;
  (* civil-from-days (Hinnant); days >= 0 so every step stays non-negative *)
  z := days + 719468;
  era := z DIV 146097; doe := z - era * 146097;
  yoe := (doe - doe DIV 1460 + doe DIV 36524 - doe DIV 146096) DIV 365;
  y := yoe + era * 400;
  doy := doe - (365 * yoe + yoe DIV 4 - yoe DIV 100);
  mp := (5 * doy + 2) DIV 153;
  d := doy - (153 * mp + 2) DIV 5 + 1;
  IF mp < 10 THEN m := mp + 3 ELSE m := mp - 9 END;
  IF m <= 2 THEN y := y + 1 END;
  dt.year := y;
  dt.month := VAL(Month, m);
  dt.day := VAL(Day, d);
  dt.hour := VAL(Hour, sod DIV 3600);
  dt.minute := VAL(Min, (sod MOD 3600) DIV 60);
  dt.second := VAL(Sec, sod MOD 60);
  dt.fractions := VAL(Fraction, 0);
  dt.zone := VAL(UTCDiff, 0);
  dt.SummerTimeFlag := FALSE
END CToDateTime;

PROCEDURE DateTimeToDos (dt: DateTime; VAR date, time: CARDINAL);
BEGIN
  date := ((((dt.year - 1980) BAND 7FH) SHL 9)
           BOR (VAL(CARDINAL, dt.month) SHL 5)
           BOR VAL(CARDINAL, dt.day)) BAND 0FFFFH;
  time := ((VAL(CARDINAL, dt.hour) SHL 11)
           BOR (VAL(CARDINAL, dt.minute) SHL 5)
           BOR (VAL(CARDINAL, dt.second) DIV 2)) BAND 0FFFFH
END DateTimeToDos;

PROCEDURE DosToDateTime (date, time: CARDINAL; VAR dt: DateTime);
BEGIN
  dt.year := ((date SHR 9) BAND 7FH) + 1980;
  dt.month := VAL(Month, (date SHR 5) BAND 0FH);
  dt.day := VAL(Day, date BAND 1FH);
  dt.hour := VAL(Hour, (time SHR 11) BAND 1FH);
  dt.minute := VAL(Min, (time SHR 5) BAND 3FH);
  dt.second := VAL(Sec, (time BAND 1FH) * 2);
  dt.fractions := VAL(Fraction, 0);
  dt.zone := VAL(UTCDiff, 0);
  dt.SummerTimeFlag := FALSE
END DosToDateTime;

END TimeFunc.
