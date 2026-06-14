MODULE t70120;
IMPORT STextIO, M2EXCEPTION;
VAR a : ARRAY [0..2] OF CARDINAL; i, x : CARDINAL;
BEGIN
  a[0] := 1; i := 9;
  x := a[i]
EXCEPT
  IF M2EXCEPTION.IsM2Exception() THEN
    IF M2EXCEPTION.M2Exception() = M2EXCEPTION.indexException THEN
      STextIO.WriteString("index")
    ELSE
      STextIO.WriteString("other-m2")
    END
  ELSE
    STextIO.WriteString("not-m2")
  END;
  STextIO.WriteLn
END t70120.
