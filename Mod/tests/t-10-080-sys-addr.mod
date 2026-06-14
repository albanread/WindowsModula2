MODULE t10080;
IMPORT STextIO, WholeStr, SYSTEM;
VAR arr: ARRAY [0..7] OF CARDINAL; a, b, c: SYSTEM.ADDRESS; o: ARRAY [0..15] OF CHAR;
PROCEDURE pn(x: INTEGER);
BEGIN WholeStr.IntToStr(x, o); STextIO.WriteString(o); STextIO.WriteString(" ") END pn;
BEGIN
  a := SYSTEM.ADR(arr[0]);
  b := SYSTEM.ADDADR(a, 16);   (* a + 16 *)
  c := SYSTEM.SUBADR(b, 4);    (* a + 12 *)
  pn(SYSTEM.DIFADR(b, a));     (* 16 *)
  pn(SYSTEM.DIFADR(c, a));     (* 12 *)
  STextIO.WriteLn;
END t10080.
