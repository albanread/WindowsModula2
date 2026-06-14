IMPLEMENTATION MODULE FpuIO;

IMPORT SRealIO, SLongIO, SWholeIO;
IMPORT RealStr, LongStr, WholeStr;
FROM ConvTypes IMPORT ConvResults;

(* --- REAL ------------------------------------------------------------- *)

PROCEDURE ReadReal (VAR x: REAL);
BEGIN
  SRealIO.ReadReal(x)
END ReadReal;

PROCEDURE WriteReal (x: REAL; TotalWidth, FractionWidth: CARDINAL);
BEGIN
  SRealIO.WriteFixed(x, INTEGER(FractionWidth), TotalWidth)
END WriteReal;

PROCEDURE RealToStr (x: REAL; TotalWidth, FractionWidth: CARDINAL; VAR str: ARRAY OF CHAR);
BEGIN
  RealStr.RealToFixed(x, INTEGER(FractionWidth), str)
END RealToStr;

PROCEDURE StrToReal (str: ARRAY OF CHAR; VAR x: REAL);
VAR
  res: ConvResults;
BEGIN
  RealStr.StrToReal(str, x, res)
END StrToReal;

(* --- LONGREAL --------------------------------------------------------- *)

PROCEDURE ReadLongReal (VAR x: LONGREAL);
BEGIN
  SLongIO.ReadReal(x)
END ReadLongReal;

PROCEDURE WriteLongReal (x: LONGREAL; TotalWidth, FractionWidth: CARDINAL);
BEGIN
  SLongIO.WriteFixed(x, INTEGER(FractionWidth), TotalWidth)
END WriteLongReal;

PROCEDURE LongRealToStr (x: LONGREAL; TotalWidth, FractionWidth: CARDINAL; VAR str: ARRAY OF CHAR);
BEGIN
  LongStr.RealToFixed(x, INTEGER(FractionWidth), str)
END LongRealToStr;

PROCEDURE StrToLongReal (str: ARRAY OF CHAR; VAR x: LONGREAL);
VAR
  res: ConvResults;
BEGIN
  LongStr.StrToReal(str, x, res)
END StrToLongReal;

(* --- LONGINT ---------------------------------------------------------- *)

PROCEDURE WriteLongInt (x: LONGINT; TotalWidth: CARDINAL);
BEGIN
  SWholeIO.WriteInt(x, TotalWidth)
END WriteLongInt;

PROCEDURE LongIntToStr (x: LONGINT; TotalWidth: CARDINAL; VAR str: ARRAY OF CHAR);
BEGIN
  WholeStr.IntToStr(x, str)
END LongIntToStr;

PROCEDURE StrToLongInt (str: ARRAY OF CHAR; VAR x: LONGINT);
VAR
  res: ConvResults;
BEGIN
  WholeStr.StrToInt(str, x, res)
END StrToLongInt;

END FpuIO.
