MODULE T30020Helper;

IMPORT SWholeIO, STextIO;

CONST
  Base = 17;

PROCEDURE WriteValue(n : INTEGER);
BEGIN
  SWholeIO.WriteInt(n, 0);
  STextIO.WriteLn;
END WriteValue;

BEGIN
END T30020Helper.