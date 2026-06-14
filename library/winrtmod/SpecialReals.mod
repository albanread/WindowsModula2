IMPLEMENTATION MODULE SpecialReals;

FROM SYSTEM IMPORT CAST;

CONST
  ExponentMask  = 7FF0000000000000H;   (* the 11 exponent bits (52..62) *)
  FractionMask  = 000FFFFFFFFFFFFFH;   (* the 52 fraction bits (0..51) *)
  QuietMask     = 0008000000000000H;   (* bit 51: quiet flag (QNaN=1, SNaN=0) *)
  MinusZeroBits = 8000000000000000H;   (* sign bit only *)

PROCEDURE Bits (R: REAL): CARDINAL;
BEGIN
  RETURN CAST(CARDINAL, R)
END Bits;

PROCEDURE ExpSaturated (b: CARDINAL): BOOLEAN;
BEGIN
  RETURN (b BAND ExponentMask) = ExponentMask
END ExpSaturated;

PROCEDURE IsFinite (R: REAL): BOOLEAN;
BEGIN
  RETURN NOT ExpSaturated(Bits(R))
END IsFinite;

PROCEDURE IsNaN (R: REAL): BOOLEAN;
  VAR b: CARDINAL;
BEGIN
  b := Bits(R);
  RETURN ExpSaturated(b) AND ((b BAND FractionMask) # 0)
END IsNaN;

PROCEDURE IsQNaN (R: REAL): BOOLEAN;
  VAR b: CARDINAL;
BEGIN
  b := Bits(R);
  RETURN ExpSaturated(b) AND ((b BAND QuietMask) # 0)
END IsQNaN;

PROCEDURE IsSNaN (R: REAL): BOOLEAN;
  VAR b: CARDINAL;
BEGIN
  b := Bits(R);
  RETURN ExpSaturated(b) AND ((b BAND FractionMask) # 0) AND ((b BAND QuietMask) = 0)
END IsSNaN;

PROCEDURE IsInfinity (R: REAL): BOOLEAN;
  VAR b: CARDINAL;
BEGIN
  b := Bits(R);
  RETURN ExpSaturated(b) AND ((b BAND FractionMask) = 0)
END IsInfinity;

PROCEDURE IsPositiveInfinity (R: REAL): BOOLEAN;
BEGIN
  RETURN IsInfinity(R) AND (R > 0.0)
END IsPositiveInfinity;

PROCEDURE IsNegativeInfinity (R: REAL): BOOLEAN;
BEGIN
  RETURN IsInfinity(R) AND (R < 0.0)
END IsNegativeInfinity;

PROCEDURE IsMinusZero (R: REAL): BOOLEAN;
BEGIN
  RETURN Bits(R) = MinusZeroBits
END IsMinusZero;

END SpecialReals.
