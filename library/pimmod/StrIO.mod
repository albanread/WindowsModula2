IMPLEMENTATION MODULE StrIO;

IMPORT STextIO;

PROCEDURE WriteString (s: ARRAY OF CHAR);
BEGIN
  STextIO.WriteString(s)
END WriteString;

PROCEDURE WriteLn;
BEGIN
  STextIO.WriteLn
END WriteLn;

PROCEDURE ReadString (VAR s: ARRAY OF CHAR);
BEGIN
  STextIO.ReadString(s)
END ReadString;

END StrIO.
