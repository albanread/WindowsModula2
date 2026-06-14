MODULE T90225WinrtHash;
(*
 * Group 90 — M2WINRT: Hash, SHA-2 digests over Windows CNG (a thin
 * BCryptHash façade — the OS computes it, not roll-your-own). Known-answer
 * vectors verified against the FIPS-180 standards: SHA-256("abc"), SHA-256(""),
 * SHA-384("abc"), SHA-512("abc").
 *
 * EXPECTED:
 * ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
 * e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
 * cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7
 * ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f
 *)
FROM SYSTEM IMPORT ADR;
FROM Hash IMPORT SHA256, SHA384, SHA512, HexDigest, SHA256Bytes, SHA384Bytes, SHA512Bytes;
FROM StrIO IMPORT WriteString, WriteLn;

VAR abc: ARRAY [0..2] OF BYTE; empty: ARRAY [0..0] OF BYTE;
    d: ARRAY [0..63] OF BYTE; hex: ARRAY [0..159] OF CHAR; ok: BOOLEAN;
BEGIN
  abc[0] := VAL(BYTE, 97); abc[1] := VAL(BYTE, 98); abc[2] := VAL(BYTE, 99);
  ok := SHA256(ADR(abc), 3, d);   HexDigest(d, SHA256Bytes, hex); WriteString(hex); WriteLn;
  ok := SHA256(ADR(empty), 0, d); HexDigest(d, SHA256Bytes, hex); WriteString(hex); WriteLn;
  ok := SHA384(ADR(abc), 3, d);   HexDigest(d, SHA384Bytes, hex); WriteString(hex); WriteLn;
  ok := SHA512(ADR(abc), 3, d);   HexDigest(d, SHA512Bytes, hex); WriteString(hex); WriteLn
END T90225WinrtHash.
