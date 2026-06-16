IMPLEMENTATION MODULE Base64;

(* Encode 3 bytes -> 4 sextet chars; the final partial group is padded with '='.
   Decode accumulates 6 bits per char into a bit buffer and emits a byte every
   time 8 bits are available. Alphabet -> char and char -> value go through
   functions (CONST strings are not indexable here). *)

FROM SYSTEM IMPORT BYTE;

PROCEDURE B (x: BYTE): CARDINAL;
BEGIN RETURN ORD(x) BAND 0FFH END B;

PROCEDURE Enc6 (v: CARDINAL): CHAR;
BEGIN
  IF v < 26 THEN RETURN CHR(ORD('A') + v)
  ELSIF v < 52 THEN RETURN CHR(ORD('a') + v - 26)
  ELSIF v < 62 THEN RETURN CHR(ORD('0') + v - 52)
  ELSIF v = 62 THEN RETURN '+'
  ELSE RETURN '/' END
END Enc6;

PROCEDURE Dec6 (c: CHAR): CARDINAL;       (* 255 = not a Base64 char *)
BEGIN
  IF    (c >= 'A') AND (c <= 'Z') THEN RETURN ORD(c) - ORD('A')
  ELSIF (c >= 'a') AND (c <= 'z') THEN RETURN ORD(c) - ORD('a') + 26
  ELSIF (c >= '0') AND (c <= '9') THEN RETURN ORD(c) - ORD('0') + 52
  ELSIF c = '+' THEN RETURN 62
  ELSIF c = '/' THEN RETURN 63
  ELSE RETURN 255 END
END Dec6;

PROCEDURE EncodedLength (n: CARDINAL): CARDINAL;
BEGIN RETURN ((n + 2) DIV 3) * 4 END EncodedLength;

PROCEDURE Encode (data: ARRAY OF BYTE; n: CARDINAL; VAR text: ARRAY OF CHAR): BOOLEAN;
  VAR i, k, b0, b1, b2: CARDINAL;

  PROCEDURE Put (c: CHAR): BOOLEAN;
  BEGIN
    IF k > HIGH(text) THEN RETURN FALSE END;
    text[k] := c; INC(k); RETURN TRUE
  END Put;

BEGIN
  i := 0; k := 0;
  WHILE i < n DO
    b0 := B(data[i]);
    IF i + 1 < n THEN b1 := B(data[i + 1]) ELSE b1 := 0 END;
    IF i + 2 < n THEN b2 := B(data[i + 2]) ELSE b2 := 0 END;
    IF NOT Put(Enc6(b0 SHR 2)) THEN RETURN FALSE END;
    IF NOT Put(Enc6(((b0 BAND 3) SHL 4) BOR (b1 SHR 4))) THEN RETURN FALSE END;
    IF i + 1 < n THEN
      IF NOT Put(Enc6(((b1 BAND 0FH) SHL 2) BOR (b2 SHR 6))) THEN RETURN FALSE END
    ELSE
      IF NOT Put('=') THEN RETURN FALSE END
    END;
    IF i + 2 < n THEN
      IF NOT Put(Enc6(b2 BAND 3FH)) THEN RETURN FALSE END
    ELSE
      IF NOT Put('=') THEN RETURN FALSE END
    END;
    INC(i, 3)
  END;
  IF k > HIGH(text) THEN RETURN FALSE END;   (* no room for the terminator *)
  text[k] := 0C;
  RETURN TRUE
END Encode;

PROCEDURE Decode (text: ARRAY OF CHAR; VAR data: ARRAY OF BYTE; VAR n: CARDINAL): BOOLEAN;
  VAR i, k, acc, bits, v: CARDINAL; c: CHAR; done: BOOLEAN;

  PROCEDURE PutB (b: CARDINAL): BOOLEAN;
  BEGIN
    IF k > HIGH(data) THEN RETURN FALSE END;
    data[k] := VAL(BYTE, b BAND 0FFH); INC(k); RETURN TRUE
  END PutB;

BEGIN
  i := 0; k := 0; acc := 0; bits := 0; done := FALSE;
  WHILE (NOT done) AND (i <= HIGH(text)) AND (text[i] # 0C) DO
    c := text[i]; INC(i);
    IF c = '=' THEN
      done := TRUE
    ELSIF (c = ' ') OR (c = CHR(9)) OR (c = CHR(10)) OR (c = CHR(13)) THEN
      (* skip whitespace *)
    ELSE
      v := Dec6(c);
      IF v = 255 THEN RETURN FALSE END;
      acc := (acc SHL 6) BOR v; INC(bits, 6);
      IF bits >= 8 THEN
        DEC(bits, 8);
        IF NOT PutB((acc SHR bits) BAND 0FFH) THEN RETURN FALSE END
      END
    END
  END;
  n := k; RETURN TRUE
END Decode;

END Base64.
