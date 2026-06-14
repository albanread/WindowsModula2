MODULE T30040StateHelper;

IMPORT STextIO, SWholeIO;

PROCEDURE EchoValues(srcInt : INTEGER; srcCard : CARDINAL; srcChar : CHAR; srcFlag : BOOLEAN);
BEGIN
  SWholeIO.WriteInt(srcInt, 0);
  STextIO.WriteLn;
  SWholeIO.WriteCard(srcCard, 0);
  STextIO.WriteLn;
  STextIO.WriteChar(srcChar);
  STextIO.WriteLn;
  IF srcFlag THEN
    SWholeIO.WriteInt(1, 0)
  ELSE
    SWholeIO.WriteInt(0, 0)
  END;
  STextIO.WriteLn;
END EchoValues;

BEGIN
END T30040StateHelper.