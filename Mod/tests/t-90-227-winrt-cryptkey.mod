MODULE T90227WinrtCryptKey;
(*
 * Group 90 — M2WINRT: CryptKey, PBKDF2-HMAC-SHA256 password key
 * derivation over Windows CNG (BCryptDeriveKeyPBKDF2). Known-answer vectors
 * (password="password", salt="salt") verified independently against Python
 * hashlib.pbkdf2_hmac: c=1 and c=4096, 32-byte keys.
 *
 * EXPECTED:
 * 120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b
 * c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a
 *)
FROM SYSTEM IMPORT ADR;
FROM CryptKey IMPORT DeriveKey;
FROM Hash IMPORT HexDigest;
FROM StrIO IMPORT WriteString, WriteLn;

VAR pwd: ARRAY [0..7] OF BYTE; salt: ARRAY [0..3] OF BYTE;
    key: ARRAY [0..31] OF BYTE; hex: ARRAY [0..79] OF CHAR; ok: BOOLEAN;
BEGIN
  pwd[0]:=VAL(BYTE,112); pwd[1]:=VAL(BYTE,97); pwd[2]:=VAL(BYTE,115); pwd[3]:=VAL(BYTE,115);
  pwd[4]:=VAL(BYTE,119); pwd[5]:=VAL(BYTE,111); pwd[6]:=VAL(BYTE,114); pwd[7]:=VAL(BYTE,100); (* "password" *)
  salt[0]:=VAL(BYTE,115); salt[1]:=VAL(BYTE,97); salt[2]:=VAL(BYTE,108); salt[3]:=VAL(BYTE,116); (* "salt" *)
  ok := DeriveKey(ADR(pwd), 8, ADR(salt), 4, 1, ADR(key), 32);
  HexDigest(key, 32, hex); WriteString(hex); WriteLn;
  ok := DeriveKey(ADR(pwd), 8, ADR(salt), 4, 4096, ADR(key), 32);
  HexDigest(key, 32, hex); WriteString(hex); WriteLn
END T90227WinrtCryptKey.
