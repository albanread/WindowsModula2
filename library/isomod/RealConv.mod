(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-13 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - Flattened `<* IF EXCEPTIONS THEN ... %ELSE XRaise %END *>` chains
       to the EXCEPTIONS branch. XRaise removed entirely.
     - Dropped `<*+ m2extensions *>` pragma.
     - **Upstream bug fixed**: XDS RealConv.mod's `raise` raised the
       string "LongConv.Exception" (copy-paste from LongConv). Corrected
       to "RealConv.Exception" in the EXCEPTIONS branch we keep. The
       XRaise branch had the same bug; that branch is gone.
     - `chk` retains the `IF str[0]='?' THEN HALT END` guard. The `?`
       marker is the upstream's buffer-too-small sentinel; XReal does
       not actually emit `?` in the current port, so the guard never
       fires today, but we keep it as a defensive cross-check in case
       a future XReal change reintroduces the convention.
*)
IMPLEMENTATION MODULE RealConv; (* Andrew Cadach Aug 1993 *)

(* low-level float/string conversions *)

IMPORT RealStr, ConvTypes;
IMPORT EXCEPTIONS;

VAR source: EXCEPTIONS.ExceptionSource;

CONST
  ok   = ConvTypes.valid;
  inv  = ConvTypes.invalid;
  pad  = ConvTypes.padding;
  term = ConvTypes.terminator;

TYPE
  float  = REAL;
  string = ARRAY [0..127] OF CHAR;
  Class  = ConvTypes.ScanClass;
  State  = ConvTypes.ScanState;
  result = ConvTypes.ConvResults;

PROCEDURE raise;
BEGIN
  EXCEPTIONS.RAISE(source, 0, "RealConv.Exception");
END raise;

PROCEDURE WE (ch: CHAR; VAR class: Class; VAR next: State);
BEGIN
  class := ok;
  IF (ch >= '0') AND (ch <= '9') THEN next := WE
  ELSE class := term
  END;
END WE;

PROCEDURE SE (ch: CHAR; VAR class: Class; VAR next: State);
BEGIN
  class := ok;
  IF (ch >= '0') AND (ch <= '9') THEN next := WE
  ELSE class := inv; next := SE
  END;
END SE;

PROCEDURE E (ch: CHAR; VAR class: Class; VAR next: State);
BEGIN
  class := ok;
  IF (ch = '-') OR (ch = '+') THEN next := SE
  ELSIF (ch >= '0') AND (ch <= '9') THEN next := WE
  ELSE class := inv; next := E
  END;
END E;

PROCEDURE F (ch: CHAR; VAR class: Class; VAR next: State);
BEGIN
  class := ok;
  IF (ch >= '0') AND (ch <= '9') THEN next := F
  ELSIF ch = 'E' THEN next := E
  ELSE class := term
  END;
END F;

PROCEDURE P (ch: CHAR; VAR class: Class; VAR next: State);
BEGIN
  class := ok;
  IF (ch >= '0') AND (ch <= '9') THEN next := P
  ELSIF ch = '.' THEN next := F
  ELSIF ch = 'E' THEN next := E
  ELSE class := term
  END;
END P;

PROCEDURE RS (ch: CHAR; VAR class: Class; VAR next: State);
BEGIN
  class := inv; next := RS;
  IF (ch >= '0') AND (ch <= '9') THEN
    class := ok; next := P;
  END
END RS;

PROCEDURE ScanReal (ch: CHAR; VAR class: Class; VAR next: State);
BEGIN
  class := ok;
  IF ch = ' ' THEN class := pad; next := ScanReal;
  ELSIF (ch = '-') OR (ch = '+') THEN next := RS
  ELSIF (ch >= '0') AND (ch <= '9') THEN next := P
  ELSE class := inv; next := ScanReal
  END
END ScanReal;

PROCEDURE FormatReal (str: ARRAY OF CHAR): ConvResults;
  VAR res: result; real: float;
BEGIN
  RealStr.StrToReal(str, real, res);
  RETURN res;
END FormatReal;

PROCEDURE ValueReal (str: ARRAY OF CHAR): float;
  VAR res: result; real: float;
BEGIN
  RealStr.StrToReal(str, real, res);
  IF (res # ConvTypes.strAllRight) AND (res # ConvTypes.strOutOfRange) THEN raise END;
  RETURN real;
END ValueReal;

PROCEDURE chk (VAR str: ARRAY OF CHAR): CARDINAL;
BEGIN
  IF str[0] = '?' THEN HALT END;
  RETURN LENGTH(str);
END chk;

PROCEDURE LengthFloatReal (real: float; sigFigs: CARDINAL): CARDINAL;
  VAR str: string;
BEGIN
  RealStr.RealToFloat(real, sigFigs, str);
  RETURN chk(str);
END LengthFloatReal;

PROCEDURE LengthEngReal (real: float; sigFigs: CARDINAL): CARDINAL;
  VAR str: string;
BEGIN
  RealStr.RealToEng(real, sigFigs, str);
  RETURN chk(str);
END LengthEngReal;

PROCEDURE LengthFixedReal (real: float; place: INTEGER): CARDINAL;
  VAR str: string;
BEGIN
  RealStr.RealToFixed(real, place, str);
  RETURN chk(str);
END LengthFixedReal;

PROCEDURE IsRConvException (): BOOLEAN;
BEGIN
  RETURN EXCEPTIONS.IsCurrentSource(source)
END IsRConvException;

BEGIN
  EXCEPTIONS.AllocateSource(source);
END RealConv.
