MODULE T60140LowReal;
(* Group 60 — ISO LowReal. scale/intpart bit-level reals via SYSTEM.CAST. *)
IMPORT STextIO, WholeStr, LowReal;
VAR s: ARRAY [0..31] OF CHAR;
BEGIN
  WholeStr.IntToStr(VAL(INTEGER, TRUNC(LowReal.scale(1.0, 3))), s);
  STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.IntToStr(VAL(INTEGER, TRUNC(LowReal.intpart(3.75))), s);
  STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.IntToStr(LowReal.exponent(1.0), s);
  STextIO.WriteString(s); STextIO.WriteLn;
END T60140LowReal.
