IMPLEMENTATION MODULE CryptKey;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM Security_Cryptography IMPORT BCryptDeriveKeyPBKDF2, BCRYPT_ALG_HANDLE;
FROM WIN32 IMPORT DWORD, QWORD;

CONST H_HMAC_SHA256 = 177;   (* BCRYPT_HMAC_SHA256_ALG_HANDLE — PBKDF2's PRF must be HMAC-flagged *)

PROCEDURE DeriveKey (password: ADDRESS; passwordLen: CARDINAL;
                     salt: ADDRESS; saltLen: CARDINAL;
                     iterations: CARDINAL;
                     key: ADDRESS; keyLen: CARDINAL): BOOLEAN;
  VAR prf: BCRYPT_ALG_HANDLE; status: INTEGER;
BEGIN
  IF (keyLen = 0) OR (iterations = 0) THEN RETURN FALSE END;
  prf.Value := CAST(ADDRESS, H_HMAC_SHA256);
  status := BCryptDeriveKeyPBKDF2(prf, password, VAL(DWORD, passwordLen),
                                  salt, VAL(DWORD, saltLen),
                                  VAL(QWORD, iterations),
                                  key, VAL(DWORD, keyLen), 0);
  RETURN status = 0
END DeriveKey;

END CryptKey.
