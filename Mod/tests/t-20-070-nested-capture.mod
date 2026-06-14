MODULE T20070Capture;
(* Group 20 — capturing nested procedure: `put` mutates the enclosing `pos`
   and writes the enclosing VAR-array `dst`. EXPECTED: ***** / 5 *)
IMPORT STextIO, WholeStr;
VAR out: ARRAY [0..31] OF CHAR; s: ARRAY [0..31] OF CHAR; len: CARDINAL;
PROCEDURE build(VAR dst: ARRAY OF CHAR; n: CARDINAL): CARDINAL;
  VAR pos: CARDINAL;
  PROCEDURE put(c: CHAR);
  BEGIN
    IF pos <= HIGH(dst) THEN dst[pos] := c END;
    INC(pos);
  END put;
BEGIN
  pos := 0;
  WHILE n > 0 DO put('*'); DEC(n) END;
  put(0C);
  RETURN pos - 1;
END build;
BEGIN
  len := build(s, 5);
  STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.CardToStr(len, out); STextIO.WriteString(out); STextIO.WriteLn;
END T20070Capture.
