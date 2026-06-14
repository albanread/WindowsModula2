MODULE T90228WinrtSymCrypt;
(*
 * Group 90 — M2WINRT: SymCrypt, AES-256-GCM authenticated encryption
 * (AEAD) over Windows CNG (BCryptEncrypt/Decrypt with a GCM cipher-mode-info
 * struct). Functional proof: encrypt produces ciphertext != plaintext;
 * decrypt round-trips exactly; and the 128-bit tag makes decryption FAIL CLOSED
 * when either the ciphertext OR the associated data is tampered.
 *
 * EXPECTED:
 * encrypt: Y
 * ct=pt (should be N): N
 * decrypt: Y
 * roundtrip match: Y
 * tampered ct decrypt (should be N): N
 * tampered aad decrypt (should be N): N
 *)
FROM SYSTEM IMPORT ADR;
FROM SymCrypt IMPORT Encrypt, Decrypt;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR key: ARRAY [0..31] OF BYTE; nonce: ARRAY [0..11] OF BYTE;
    pt, ct, dec: ARRAY [0..31] OF BYTE; tag: ARRAY [0..15] OF BYTE;
    aad: ARRAY [0..3] OF BYTE; i: CARDINAL; ok, match: BOOLEAN;
BEGIN
  FOR i := 0 TO 31 DO key[i] := VAL(BYTE, i) END;
  FOR i := 0 TO 11 DO nonce[i] := VAL(BYTE, 100 + i) END;
  FOR i := 0 TO 31 DO pt[i] := VAL(BYTE, 65 + i) END;
  FOR i := 0 TO 3 DO aad[i] := VAL(BYTE, 200 + i) END;

  ok := Encrypt(ADR(key), ADR(nonce), ADR(aad), 4, ADR(pt), 32, ADR(ct), ADR(tag));
  WriteString("encrypt: "); YN(ok); WriteLn;
  match := TRUE; FOR i := 0 TO 31 DO IF ct[i] # pt[i] THEN match := FALSE END END;
  WriteString("ct=pt (should be N): "); YN(match); WriteLn;

  ok := Decrypt(ADR(key), ADR(nonce), ADR(aad), 4, ADR(ct), 32, ADR(tag), ADR(dec));
  WriteString("decrypt: "); YN(ok); WriteLn;
  match := TRUE; FOR i := 0 TO 31 DO IF dec[i] # pt[i] THEN match := FALSE END END;
  WriteString("roundtrip match: "); YN(match); WriteLn;

  ct[0] := VAL(BYTE, ORD(ct[0]) BXOR 1);
  ok := Decrypt(ADR(key), ADR(nonce), ADR(aad), 4, ADR(ct), 32, ADR(tag), ADR(dec));
  WriteString("tampered ct decrypt (should be N): "); YN(ok); WriteLn;
  ct[0] := VAL(BYTE, ORD(ct[0]) BXOR 1);

  aad[0] := VAL(BYTE, ORD(aad[0]) BXOR 1);
  ok := Decrypt(ADR(key), ADR(nonce), ADR(aad), 4, ADR(ct), 32, ADR(tag), ADR(dec));
  WriteString("tampered aad decrypt (should be N): "); YN(ok); WriteLn
END T90228WinrtSymCrypt.
