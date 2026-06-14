MODULE t40040;
IMPORT STextIO, WholeStr;
TYPE
  Shape = (circle, rectangle);
  Figure = RECORD
    name : CHAR;
    CASE kind : Shape OF
      circle:    radius : CARDINAL;
    | rectangle: width, height : CARDINAL;
    END;
  END;
VAR f : Figure; o : ARRAY [0..15] OF CHAR;
PROCEDURE pn(x: CARDINAL);
BEGIN WholeStr.CardToStr(x, o); STextIO.WriteString(o); STextIO.WriteString(" ") END pn;
BEGIN
  f.name := 'C'; f.kind := circle; f.radius := 42;
  STextIO.WriteChar(f.name); pn(ORD(f.kind)); pn(f.radius); STextIO.WriteLn;
  f.kind := rectangle; f.width := 10; f.height := 20;
  pn(ORD(f.kind)); pn(f.width); pn(f.height); STextIO.WriteLn;
END t40040.
