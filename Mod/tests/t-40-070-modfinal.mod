MODULE t40070;
IMPORT STextIO;
IMPORT T40070Res;
BEGIN
  T40070Res.Touch;
  STextIO.WriteString("main"); STextIO.WriteLn
FINALLY
  STextIO.WriteString("final-main"); STextIO.WriteLn
END t40070.
