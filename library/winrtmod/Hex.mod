IMPLEMENTATION MODULE Hex;

FROM SYSTEM IMPORT BYTE;

PROCEDURE B (x: BYTE): CARDINAL;
BEGIN RETURN ORD(x) BAND 0FFH END B;

PROCEDURE Nib (v: CARDINAL; upper: BOOLEAN): CHAR;
BEGIN
  IF v < 10 THEN RETURN CHR(ORD('0') + v)
  ELSIF upper THEN RETURN CHR(ORD('A') + v - 10)
  ELSE RETURN CHR(ORD('a') + v - 10) END
END Nib;

PROCEDURE HexVal (c: CHAR): CARDINAL;       (* 255 = not a hex digit *)
BEGIN
  IF    (c >= '0') AND (c <= '9') THEN RETURN ORD(c) - ORD('0')
  ELSIF (c >= 'a') AND (c <= 'f') THEN RETURN ORD(c) - ORD('a') + 10
  ELSIF (c >= 'A') AND (c <= 'F') THEN RETURN ORD(c) - ORD('A') + 10
  ELSE RETURN 255 END
END HexVal;

PROCEDURE Encode (data: ARRAY OF BYTE; n: CARDINAL; upper: BOOLEAN; VAR text: ARRAY OF CHAR): BOOLEAN;
  VAR i, k, b: CARDINAL;
BEGIN
  i := 0; k := 0;
  WHILE i < n DO
    IF k + 2 > HIGH(text) THEN RETURN FALSE END;   (* two digits + room for terminator *)
    b := B(data[i]);
    text[k] := Nib(b DIV 16, upper); text[k + 1] := Nib(b MOD 16, upper);
    INC(k, 2); INC(i)
  END;
  IF k <= HIGH(text) THEN text[k] := 0C END;
  RETURN TRUE
END Encode;

PROCEDURE Decode (text: ARRAY OF CHAR; VAR data: ARRAY OF BYTE; VAR n: CARDINAL): BOOLEAN;
  VAR i, k, hi, lo: CARDINAL; c: CHAR;
BEGIN
  i := 0; k := 0;
  WHILE (i <= HIGH(text)) AND (text[i] # 0C) DO
    c := text[i];
    IF (c = ' ') OR (c = CHR(9)) OR (c = CHR(10)) OR (c = CHR(13)) THEN
      INC(i)
    ELSE
      hi := HexVal(c); IF hi = 255 THEN RETURN FALSE END; INC(i);
      IF (i > HIGH(text)) OR (text[i] = 0C) THEN RETURN FALSE END;   (* odd digit count *)
      lo := HexVal(text[i]); IF lo = 255 THEN RETURN FALSE END; INC(i);
      IF k > HIGH(data) THEN RETURN FALSE END;
      data[k] := VAL(BYTE, (hi * 16 + lo) BAND 0FFH); INC(k)
    END
  END;
  n := k; RETURN TRUE
END Decode;

END Hex.
