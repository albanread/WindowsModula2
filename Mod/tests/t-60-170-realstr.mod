MODULE T60170RealStr;
(* Group 60 — ISO RealStr (via the XReal formatting engine + capturing nested
   procs). RealToFixed / StrToReal round-trip. *)
IMPORT STextIO, RealStr, ConvTypes;
VAR s: ARRAY [0..63] OF CHAR; r: REAL; res: RealStr.ConvResults;
PROCEDURE fx(x: REAL; place: INTEGER);
BEGIN RealStr.RealToFixed(x, place, s); STextIO.WriteString(s); STextIO.WriteLn; END fx;
BEGIN
  fx(3.14159, 2);
  fx(2.5, 1);
  fx(0.125, 3);
  RealStr.StrToReal("12.5E1", r, res);
  IF res = ConvTypes.strAllRight THEN fx(r, 1) ELSE STextIO.WriteString("bad"); STextIO.WriteLn END;
  RealStr.StrToReal("-3.5", r, res);
  fx(r, 1);
END T60170RealStr.
