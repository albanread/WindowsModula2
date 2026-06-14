IMPLEMENTATION MODULE Hash;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM Security_Cryptography IMPORT BCryptHash, BCRYPT_ALG_HANDLE;
FROM WIN32 IMPORT DWORD;

CONST
  H_SHA256 = 65;   (* BCRYPT_SHA256_ALG_HANDLE pseudo-handles (Win10+) *)
  H_SHA384 = 81;
  H_SHA512 = 97;
  NUL = CHR(0);

PROCEDURE Digest (algHandle: CARDINAL; data: ADDRESS; len: CARDINAL;
                  out: ADDRESS; outLen: CARDINAL): BOOLEAN;
  VAR alg: BCRYPT_ALG_HANDLE; status: INTEGER;
BEGIN
  alg.Value := CAST(ADDRESS, algHandle);   (* the SHA-N CNG pseudo-handle *)
  status := BCryptHash(alg, NIL, 0, data, VAL(DWORD, len), out, VAL(DWORD, outLen));
  RETURN status = 0
END Digest;

PROCEDURE SHA256 (data: ADDRESS; len: CARDINAL; VAR digest: ARRAY OF BYTE): BOOLEAN;
BEGIN RETURN Digest(H_SHA256, data, len, ADR(digest), SHA256Bytes) END SHA256;

PROCEDURE SHA384 (data: ADDRESS; len: CARDINAL; VAR digest: ARRAY OF BYTE): BOOLEAN;
BEGIN RETURN Digest(H_SHA384, data, len, ADR(digest), SHA384Bytes) END SHA384;

PROCEDURE SHA512 (data: ADDRESS; len: CARDINAL; VAR digest: ARRAY OF BYTE): BOOLEAN;
BEGIN RETURN Digest(H_SHA512, data, len, ADR(digest), SHA512Bytes) END SHA512;

PROCEDURE HexDigest (digest: ARRAY OF BYTE; len: CARDINAL; VAR hex: ARRAY OF CHAR);
  VAR i, k, b: CARDINAL;

  PROCEDURE Nib (n: CARDINAL): CHAR;
  BEGIN
    IF n < 10 THEN RETURN CHR(ORD('0') + n) ELSE RETURN CHR(ORD('a') + (n - 10)) END
  END Nib;

BEGIN
  k := 0; i := 0;
  WHILE (i < len) AND (k + 2 <= HIGH(hex)) DO
    b := ORD(digest[i]);
    hex[k] := Nib(b DIV 16); hex[k + 1] := Nib(b MOD 16);
    k := k + 2; INC(i)
  END;
  hex[k] := NUL
END HexDigest;

END Hash.
