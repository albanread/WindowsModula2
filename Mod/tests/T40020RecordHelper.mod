MODULE T40020RecordHelper;

IMPORT STextIO, SWholeIO;

TYPE
  Pair = RECORD
    left  : INTEGER;
    right : CARDINAL;
    mark  : CHAR;
  END;
  PairPtr = POINTER TO Pair;

PROCEDURE WriteRecordValues(leftIn : INTEGER; rightIn : CARDINAL; markIn : CHAR);
VAR pair : PairPtr;
BEGIN
  NEW(pair);
  pair^.left := leftIn;
  pair^.right := rightIn;
  pair^.mark := markIn;

  SWholeIO.WriteInt(pair^.left, 0);
  STextIO.WriteLn;
  SWholeIO.WriteCard(pair^.right, 0);
  STextIO.WriteLn;
  STextIO.WriteChar(pair^.mark);
  STextIO.WriteLn;
  SWholeIO.WriteInt(pair^.left + pair^.right, 0);
  STextIO.WriteLn;
END WriteRecordValues;

BEGIN
END T40020RecordHelper.