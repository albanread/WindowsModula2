IMPLEMENTATION MODULE Hashing;

(* FNV-1a: h := offset; for each byte b: h := (h XOR b) * prime, all in 64-bit
   (CARDINAL multiply wraps mod 2^64, which is exactly the FNV definition). *)

FROM SYSTEM IMPORT ADDRESS, CAST, BYTE;

CONST
  Offset = 0CBF29CE484222325H;   (* 14695981039346656037 *)
  Prime  = 000000100000001B3H;   (* 1099511628211 *)
  MaxIdx = 2147483647;

TYPE PBytes = POINTER TO ARRAY [0..MaxIdx] OF BYTE;

PROCEDURE FNV1a (s: ARRAY OF CHAR): CARDINAL;
  VAR h: CARDINAL; i: CARDINAL; c: CARDINAL;
BEGIN
  h := Offset; i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO
    c := ORD(s[i]);
    h := (h BXOR (c BAND 0FFH)) * Prime;        (* low byte  *)
    h := (h BXOR ((c SHR 8) BAND 0FFH)) * Prime;(* high byte (UTF-16 CHAR) *)
    INC(i)
  END;
  RETURN h
END FNV1a;

PROCEDURE FNV1aBytes (a: ADDRESS; n: CARDINAL): CARDINAL;
  VAR h, i: CARDINAL; p: PBytes;
BEGIN
  h := Offset; p := CAST(PBytes, a); i := 0;
  WHILE i < n DO
    h := (h BXOR (VAL(CARDINAL, p^[i]) BAND 0FFH)) * Prime;
    INC(i)
  END;
  RETURN h
END FNV1aBytes;

END Hashing.
