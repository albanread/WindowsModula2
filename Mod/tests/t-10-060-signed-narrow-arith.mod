MODULE t10060;
IMPORT STextIO, WholeStr;
VAR n: INTEGER; o: ARRAY [0..15] OF CHAR; e8: INTEGER8;
BEGIN
  e8 := -5; n := e8 + 100;        (* signed widen: 95, not 351 *)
  WholeStr.IntToStr(n, o); STextIO.WriteString(o); STextIO.WriteLn;
  n := -7 REM 3;                  (* signed REM: -1, not 0 *)
  WholeStr.IntToStr(n, o); STextIO.WriteString(o); STextIO.WriteLn;
END t10060.
