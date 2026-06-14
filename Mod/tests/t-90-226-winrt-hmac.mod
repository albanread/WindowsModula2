MODULE T90226WinrtHmac;
(*
 * Group 90 — M2WINRT: HMAC-SHA256 over Windows CNG. Known-answer is
 * RFC 4231 test case 1 (key = 0x0b x20, data = "Hi There"); Verify confirms a
 * good tag and rejects a tampered one (constant-time compare via MemUtils).
 *
 * EXPECTED:
 * b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7
 * verify-good: Y
 * verify-tampered: N
 *)
FROM SYSTEM IMPORT ADR;
FROM HMAC IMPORT HmacSHA256, Verify, HmacSHA256Bytes;
FROM Hash IMPORT HexDigest;
FROM StrIO IMPORT WriteString, WriteLn;

VAR key: ARRAY [0..19] OF BYTE; data: ARRAY [0..7] OF BYTE;
    mac: ARRAY [0..31] OF BYTE; hex: ARRAY [0..79] OF CHAR; i: CARDINAL; ok: BOOLEAN;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

BEGIN
  FOR i := 0 TO 19 DO key[i] := VAL(BYTE, 0BH) END;
  data[0]:=VAL(BYTE,72); data[1]:=VAL(BYTE,105); data[2]:=VAL(BYTE,32); data[3]:=VAL(BYTE,84);
  data[4]:=VAL(BYTE,104); data[5]:=VAL(BYTE,101); data[6]:=VAL(BYTE,114); data[7]:=VAL(BYTE,101);
  ok := HmacSHA256(ADR(key), 20, ADR(data), 8, mac);
  HexDigest(mac, HmacSHA256Bytes, hex); WriteString(hex); WriteLn;
  WriteString("verify-good: "); YN(Verify(ADR(key), 20, ADR(data), 8, ADR(mac), 32)); WriteLn;
  mac[0] := VAL(BYTE, ORD(mac[0]) BXOR 1);
  WriteString("verify-tampered: "); YN(Verify(ADR(key), 20, ADR(data), 8, ADR(mac), 32)); WriteLn
END T90226WinrtHmac.
