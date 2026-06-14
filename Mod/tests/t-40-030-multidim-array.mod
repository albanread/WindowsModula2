MODULE t40030;
IMPORT STextIO, WholeStr;
VAR m: ARRAY [0..2], [0..3] OF CARDINAL;
    nz: ARRAY [1..3] OF CARDINAL;
    i, j: CARDINAL; o: ARRAY [0..15] OF CHAR;
PROCEDURE pn(x: CARDINAL);
BEGIN WholeStr.CardToStr(x, o); STextIO.WriteString(o); STextIO.WriteString(" ") END pn;
BEGIN
  FOR i := 0 TO 2 DO FOR j := 0 TO 3 DO m[i,j] := i*10 + j END END;
  pn(m[0,0]); pn(m[1,2]); pn(m[2,3]); STextIO.WriteLn;
  nz[1] := 100; nz[2] := 200; nz[3] := 300;
  pn(nz[1]); pn(nz[2]); pn(nz[3]); STextIO.WriteLn;
END t40030.
