MODULE t70130;
IMPORT STextIO, WholeStr, M2EXCEPTION;
VAR a, b, c : INTEGER; o : ARRAY [0..15] OF CHAR;
BEGIN
  a := 10; b := 2;
  c := a DIV b; WholeStr.IntToStr(c, o); STextIO.WriteString(o); STextIO.WriteString(" ");
  b := 0; c := a DIV b;
  STextIO.WriteString("noraise")
EXCEPT
  IF M2EXCEPTION.IsM2Exception() & (M2EXCEPTION.M2Exception() = M2EXCEPTION.wholeDivException) THEN
    STextIO.WriteString("divzero")
  ELSE STextIO.WriteString("other") END
END t70130.
