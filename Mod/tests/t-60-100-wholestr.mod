MODULE T60100WholeStr;
(* Group 60 — ISO library. EXPECTED: -42 / 1000 / 7 *)
IMPORT STextIO, WholeStr;
VAR s: ARRAY [0..31] OF CHAR;
BEGIN
  WholeStr.IntToStr(-42, s); STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.CardToStr(1000, s); STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.CardToStr(7, s); STextIO.WriteString(s); STextIO.WriteLn;
END T60100WholeStr.
