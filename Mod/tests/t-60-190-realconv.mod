MODULE T60190RealConv;
(* Group 60 — ISO RealConv: ValueReal (string->real) + length queries. *)
IMPORT STextIO, WholeStr, RealConv, RealStr;
VAR s: ARRAY [0..63] OF CHAR; out: ARRAY [0..31] OF CHAR; r: REAL;
BEGIN
  r := RealConv.ValueReal("42.5");
  RealStr.RealToFixed(r, 1, s); STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.CardToStr(RealConv.LengthFixedReal(3.14159, 2), out);
  STextIO.WriteString(out); STextIO.WriteLn;
END T60190RealConv.
