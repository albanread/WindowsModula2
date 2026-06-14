MODULE t70110;
IMPORT STextIO, WholeStr;
VAR a : ARRAY [0..2] OF CARDINAL; i : CARDINAL; o : ARRAY [0..15] OF CHAR;
BEGIN
  a[0] := 10; a[1] := 20; a[2] := 30;
  WholeStr.CardToStr(a[1], o); STextIO.WriteString(o);   (* 20, in bounds *)
  i := 5;
  WholeStr.CardToStr(a[i], o); STextIO.WriteString(o)    (* raises indexException *)
EXCEPT
  STextIO.WriteString(" OOB")
END t70110.
