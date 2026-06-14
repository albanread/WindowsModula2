IMPLEMENTATION MODULE SymCrypt;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST, SIZE;
FROM Security_Cryptography IMPORT
  BCryptOpenAlgorithmProvider, BCryptCloseAlgorithmProvider, BCryptSetProperty,
  BCryptGenerateSymmetricKey, BCryptDestroyKey, BCryptEncrypt, BCryptDecrypt,
  BCRYPT_ALG_HANDLE, BCRYPT_KEY_HANDLE, BCRYPT_HANDLE,
  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO;
FROM MemUtils IMPORT ZeroMem;
FROM WIN32 IMPORT DWORD;

CONST NUL = CHR(0);

TYPE PByte = POINTER TO BYTE;

PROCEDURE WideBytes (VAR s: ARRAY OF CHAR): CARDINAL;
  (* byte length of a NUL-terminated wide string INCLUDING the terminator *)
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # NUL) DO INC(i) END;
  RETURN (i + 1) * 2
END WideBytes;

(* Shared one-shot GCM core. `decrypt` selects BCryptDecrypt (which verifies the
   tag and fails closed) vs BCryptEncrypt (which writes the tag). *)
PROCEDURE GcmRun (decrypt: BOOLEAN; key, nonce, aad: ADDRESS; aadLen: CARDINAL;
                  inBuf: ADDRESS; inLen: CARDINAL; outBuf, tagPtr: ADDRESS): BOOLEAN;
  VAR hAlg: BCRYPT_ALG_HANDLE; hKey: BCRYPT_KEY_HANDLE; hObj: BCRYPT_HANDLE;
      info: BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO;
      aesStr, chainStr, gcmStr: ARRAY [0 .. 31] OF CHAR;
      status, ignore: INTEGER; result: DWORD; ok: BOOLEAN;
BEGIN
  aesStr := "AES"; chainStr := "ChainingMode"; gcmStr := "ChainingModeGCM";
  hAlg.Value := NIL; hKey.Value := NIL; ok := FALSE;

  IF BCryptOpenAlgorithmProvider(ADR(hAlg), ADR(aesStr), NIL, 0) # 0 THEN
    RETURN FALSE
  END;

  (* select GCM chaining mode (SetProperty takes a BCRYPT_HANDLE) *)
  hObj.Value := hAlg.Value;
  status := BCryptSetProperty(hObj, ADR(chainStr), ADR(gcmStr),
                              VAL(DWORD, WideBytes(gcmStr)), 0);
  IF status = 0 THEN
    status := BCryptGenerateSymmetricKey(hAlg, ADR(hKey), NIL, 0, key,
                                         VAL(DWORD, 32), 0)
  END;

  IF status = 0 THEN
    ZeroMem(ADR(info), SIZE(info));
    info.cbSize        := VAL(DWORD, SIZE(info));
    info.dwInfoVersion := 1;
    info.pbNonce       := CAST(PByte, nonce); info.cbNonce := VAL(DWORD, 12);
    IF aadLen > 0 THEN info.pbAuthData := CAST(PByte, aad) END;
    info.cbAuthData    := VAL(DWORD, aadLen);
    info.pbTag         := CAST(PByte, tagPtr); info.cbTag := VAL(DWORD, 16);
    result := 0;
    IF decrypt THEN
      status := BCryptDecrypt(hKey, CAST(PByte, inBuf), VAL(DWORD, inLen),
                              ADR(info), NIL, 0, CAST(PByte, outBuf),
                              VAL(DWORD, inLen), ADR(result), 0)
    ELSE
      status := BCryptEncrypt(hKey, CAST(PByte, inBuf), VAL(DWORD, inLen),
                              ADR(info), NIL, 0, CAST(PByte, outBuf),
                              VAL(DWORD, inLen), ADR(result), 0)
    END;
    ok := status = 0
  END;

  IF hKey.Value # NIL THEN ignore := BCryptDestroyKey(hKey) END;
  IF hAlg.Value # NIL THEN ignore := BCryptCloseAlgorithmProvider(hAlg, 0) END;
  RETURN ok
END GcmRun;

PROCEDURE Encrypt (key, nonce, aad: ADDRESS; aadLen: CARDINAL;
                   plaintext: ADDRESS; ptLen: CARDINAL;
                   ciphertext, tag: ADDRESS): BOOLEAN;
BEGIN
  RETURN GcmRun(FALSE, key, nonce, aad, aadLen, plaintext, ptLen, ciphertext, tag)
END Encrypt;

PROCEDURE Decrypt (key, nonce, aad: ADDRESS; aadLen: CARDINAL;
                   ciphertext: ADDRESS; ctLen: CARDINAL;
                   tag, plaintext: ADDRESS): BOOLEAN;
BEGIN
  RETURN GcmRun(TRUE, key, nonce, aad, aadLen, ciphertext, ctLen, plaintext, tag)
END Decrypt;

END SymCrypt.
