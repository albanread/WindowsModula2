MODULE T40070Res;
IMPORT STextIO;
PROCEDURE Touch;
BEGIN
END Touch;
BEGIN
  STextIO.WriteString("init-res"); STextIO.WriteLn
FINALLY
  STextIO.WriteString("final-res"); STextIO.WriteLn
END T40070Res.
