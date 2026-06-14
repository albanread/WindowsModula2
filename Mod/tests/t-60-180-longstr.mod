MODULE T60180LongStr;
(* Group 60 — ISO LongStr (LONGREAL formatting via XReal). *)
IMPORT STextIO, LongStr, ConvTypes;
VAR s: ARRAY [0..63] OF CHAR; r: LONGREAL; res: LongStr.ConvResults;
PROCEDURE fx(x: LONGREAL; place: INTEGER);
BEGIN LongStr.RealToFixed(x, place, s); STextIO.WriteString(s); STextIO.WriteLn; END fx;
BEGIN
  fx(3.14159, 4);
  fx(1000.5, 1);
  LongStr.StrToReal("6.25E-2", r, res);
  IF res = ConvTypes.strAllRight THEN fx(r, 4) ELSE STextIO.WriteString("bad"); STextIO.WriteLn END;
END T60180LongStr.
