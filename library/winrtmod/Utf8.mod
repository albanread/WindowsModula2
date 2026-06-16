IMPLEMENTATION MODULE Utf8;

(* Standard UTF-8 <-> UTF-16. A high surrogate (D800..DBFF) followed by a low
   surrogate (DC00..DFFF) combines to a code point >= 0x10000; encoding a code
   point >= 0x10000 emits a surrogate pair. Continuation bytes are validated on
   decode. Bytes are 0..255 (BYTE is signed, so reads are masked, writes use
   VAL(BYTE, x BAND 0FFH)). *)

FROM SYSTEM IMPORT BYTE;

PROCEDURE B (x: BYTE): CARDINAL;
BEGIN RETURN ORD(x) BAND 0FFH END B;

PROCEDURE Length (wide: ARRAY OF CHAR): CARDINAL;
  VAR i, cp, lo, n: CARDINAL;
BEGIN
  i := 0; n := 0;
  WHILE (i <= HIGH(wide)) AND (wide[i] # 0C) DO
    cp := ORD(wide[i]); INC(i);
    IF (cp >= 0D800H) AND (cp <= 0DBFFH) AND (i <= HIGH(wide)) AND (wide[i] # 0C) THEN
      lo := ORD(wide[i]);
      IF (lo >= 0DC00H) AND (lo <= 0DFFFH) THEN
        cp := 10000H + ((cp - 0D800H) * 400H) + (lo - 0DC00H); INC(i)
      END
    END;
    IF cp < 80H THEN INC(n)
    ELSIF cp < 800H THEN INC(n, 2)
    ELSIF cp < 10000H THEN INC(n, 3)
    ELSE INC(n, 4) END
  END;
  RETURN n
END Length;

PROCEDURE Encode (wide: ARRAY OF CHAR; VAR utf8: ARRAY OF BYTE; VAR n: CARDINAL): BOOLEAN;
  VAR i, k, cp, lo: CARDINAL;

  PROCEDURE Put (v: CARDINAL): BOOLEAN;
  BEGIN
    IF k > HIGH(utf8) THEN RETURN FALSE END;
    utf8[k] := VAL(BYTE, v BAND 0FFH); INC(k); RETURN TRUE
  END Put;

BEGIN
  i := 0; k := 0;
  WHILE (i <= HIGH(wide)) AND (wide[i] # 0C) DO
    cp := ORD(wide[i]); INC(i);
    IF (cp >= 0D800H) AND (cp <= 0DBFFH) AND (i <= HIGH(wide)) AND (wide[i] # 0C) THEN
      lo := ORD(wide[i]);
      IF (lo >= 0DC00H) AND (lo <= 0DFFFH) THEN
        cp := 10000H + ((cp - 0D800H) * 400H) + (lo - 0DC00H); INC(i)
      END
    END;
    IF cp < 80H THEN
      IF NOT Put(cp) THEN RETURN FALSE END
    ELSIF cp < 800H THEN
      IF NOT Put(0C0H BOR (cp SHR 6)) THEN RETURN FALSE END;
      IF NOT Put(080H BOR (cp BAND 3FH)) THEN RETURN FALSE END
    ELSIF cp < 10000H THEN
      IF NOT Put(0E0H BOR (cp SHR 12)) THEN RETURN FALSE END;
      IF NOT Put(080H BOR ((cp SHR 6) BAND 3FH)) THEN RETURN FALSE END;
      IF NOT Put(080H BOR (cp BAND 3FH)) THEN RETURN FALSE END
    ELSE
      IF NOT Put(0F0H BOR (cp SHR 18)) THEN RETURN FALSE END;
      IF NOT Put(080H BOR ((cp SHR 12) BAND 3FH)) THEN RETURN FALSE END;
      IF NOT Put(080H BOR ((cp SHR 6) BAND 3FH)) THEN RETURN FALSE END;
      IF NOT Put(080H BOR (cp BAND 3FH)) THEN RETURN FALSE END
    END
  END;
  n := k; RETURN TRUE
END Encode;

PROCEDURE Decode (utf8: ARRAY OF BYTE; n: CARDINAL; VAR wide: ARRAY OF CHAR): BOOLEAN;
  VAR i, k, b0, cp, nb, j, cb: CARDINAL;

  PROCEDURE PutU (u: CARDINAL): BOOLEAN;
  BEGIN
    IF k > HIGH(wide) THEN RETURN FALSE END;
    wide[k] := CHR(u); INC(k); RETURN TRUE
  END PutU;

BEGIN
  i := 0; k := 0;
  WHILE i < n DO
    b0 := B(utf8[i]); INC(i);
    IF b0 < 80H THEN cp := b0; nb := 0
    ELSIF (b0 >= 0C0H) AND (b0 < 0E0H) THEN cp := b0 BAND 1FH; nb := 1
    ELSIF (b0 >= 0E0H) AND (b0 < 0F0H) THEN cp := b0 BAND 0FH; nb := 2
    ELSIF (b0 >= 0F0H) AND (b0 < 0F8H) THEN cp := b0 BAND 07H; nb := 3
    ELSE RETURN FALSE
    END;
    j := 0;
    WHILE j < nb DO
      IF i >= n THEN RETURN FALSE END;
      cb := B(utf8[i]);
      IF (cb < 80H) OR (cb >= 0C0H) THEN RETURN FALSE END;
      cp := (cp SHL 6) BOR (cb BAND 3FH); INC(i); INC(j)
    END;
    IF cp <= 0FFFFH THEN
      IF NOT PutU(cp) THEN RETURN FALSE END
    ELSE
      cp := cp - 10000H;
      IF NOT PutU(0D800H + (cp SHR 10)) THEN RETURN FALSE END;
      IF NOT PutU(0DC00H + (cp BAND 3FFH)) THEN RETURN FALSE END
    END
  END;
  IF k > HIGH(wide) THEN RETURN FALSE END;   (* no room for the terminator *)
  wide[k] := 0C;
  RETURN TRUE
END Decode;

END Utf8.
