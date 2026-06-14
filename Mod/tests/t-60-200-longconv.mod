MODULE T60200LongConv;
(* Group 60 — ISO LongConv: ValueReal (string->LONGREAL) + length query. *)
IMPORT STextIO, WholeStr, LongConv, LongStr;
VAR s: ARRAY [0..63] OF CHAR; out: ARRAY [0..31] OF CHAR; r: LONGREAL;
BEGIN
  r := LongConv.ValueReal("6.25");
  LongStr.RealToFixed(r, 2, s); STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.CardToStr(LongConv.LengthFixedReal(3.14159, 4), out);
  STextIO.WriteString(out); STextIO.WriteLn;
END T60200LongConv.
