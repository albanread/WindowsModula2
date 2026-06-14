MODULE T60160SysClock;
(* Group 60 — ISO SysClock. IsValidDateTime drives the nested isLeap helper.
   EXPECTED: y / n / n / y / n / valid *)
IMPORT STextIO, SysClock;
VAR dt: SysClock.DateTime;
PROCEDURE show(b: BOOLEAN);
BEGIN
  IF b THEN STextIO.WriteString("y") ELSE STextIO.WriteString("n") END;
  STextIO.WriteLn;
END show;
PROCEDURE setDate(y, mo, d: CARDINAL);
BEGIN
  dt.year := y; dt.month := mo; dt.day := d;
  dt.hour := 0; dt.minute := 0; dt.second := 0;
  dt.fractions := 0; dt.zone := 0; dt.SummerTimeFlag := FALSE;
END setDate;
BEGIN
  setDate(2024, 2, 29); show(SysClock.IsValidDateTime(dt));
  setDate(2023, 2, 29); show(SysClock.IsValidDateTime(dt));
  setDate(2023, 13, 1); show(SysClock.IsValidDateTime(dt));
  setDate(2000, 2, 29); show(SysClock.IsValidDateTime(dt));
  setDate(1900, 2, 29); show(SysClock.IsValidDateTime(dt));
  SysClock.GetClock(dt);
  IF SysClock.IsValidDateTime(dt) THEN STextIO.WriteString("valid") ELSE STextIO.WriteString("bad") END;
  STextIO.WriteLn;
END T60160SysClock.
