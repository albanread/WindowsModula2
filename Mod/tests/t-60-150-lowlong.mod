MODULE T60150LowLong;
(* Group 60 — ISO LowLong. scale/intpart bit-level long reals. *)
IMPORT STextIO, WholeStr, LowLong;
VAR s: ARRAY [0..31] OF CHAR;
BEGIN
  WholeStr.IntToStr(VAL(INTEGER, TRUNC(LowLong.scale(1.0, 4))), s);
  STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.IntToStr(VAL(INTEGER, TRUNC(LowLong.intpart(9.5))), s);
  STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.IntToStr(LowLong.exponent(1.0), s);
  STextIO.WriteString(s); STextIO.WriteLn;
END T60150LowLong.
