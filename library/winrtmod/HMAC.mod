IMPLEMENTATION MODULE HMAC;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM Security_Cryptography IMPORT BCryptHash, BCRYPT_ALG_HANDLE;
FROM MemUtils IMPORT EqualCT;
FROM WIN32 IMPORT DWORD;

CONST H_HMAC_SHA256 = 177;   (* BCRYPT_HMAC_SHA256_ALG_HANDLE pseudo-handle *)

PROCEDURE HmacSHA256 (key: ADDRESS; keyLen: CARDINAL;
                      data: ADDRESS; dataLen: CARDINAL;
                      VAR mac: ARRAY OF BYTE): BOOLEAN;
  VAR alg: BCRYPT_ALG_HANDLE; status: INTEGER;
BEGIN
  alg.Value := CAST(ADDRESS, H_HMAC_SHA256);
  status := BCryptHash(alg, key, VAL(DWORD, keyLen), data, VAL(DWORD, dataLen),
                       ADR(mac), HmacSHA256Bytes);
  RETURN status = 0
END HmacSHA256;

PROCEDURE Verify (key: ADDRESS; keyLen: CARDINAL;
                  data: ADDRESS; dataLen: CARDINAL;
                  expected: ADDRESS; expectedLen: CARDINAL): BOOLEAN;
  VAR mac: ARRAY [0 .. HmacSHA256Bytes - 1] OF BYTE;
BEGIN
  IF expectedLen # HmacSHA256Bytes THEN RETURN FALSE END;
  IF NOT HmacSHA256(key, keyLen, data, dataLen, mac) THEN RETURN FALSE END;
  RETURN EqualCT(ADR(mac), expected, HmacSHA256Bytes)
END Verify;

END HMAC.
