MODULE t20080;
IMPORT STextIO, WholeStr;
VAR i, sum: INTEGER; c: CHAR; o: ARRAY [0..15] OF CHAR;
BEGIN
  sum := 0; FOR i := 10 TO 1 BY -1 DO sum := sum + i END;
  WholeStr.IntToStr(sum, o); STextIO.WriteString(o); STextIO.WriteLn;   (* 55 *)
  sum := 0; FOR i := 10 TO 0 BY -2 DO sum := sum + i END;
  WholeStr.IntToStr(sum, o); STextIO.WriteString(o); STextIO.WriteLn;   (* 30 *)
  FOR c := 'A' TO 'E' DO STextIO.WriteChar(c) END; STextIO.WriteLn;     (* ABCDE *)
  sum := 0; FOR i := 1 TO 5 DO sum := sum + i END;
  WholeStr.IntToStr(sum, o); STextIO.WriteString(o); STextIO.WriteLn;   (* 15 *)
END t20080.
