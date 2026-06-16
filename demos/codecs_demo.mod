MODULE CodecsDemo;
(*
 * Exercises Utf8, Base64 and Hex against known test vectors.
 *   build: newm2 build demos/codecs_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM SYSTEM IMPORT BYTE;
IMPORT Utf8, Base64, Hex;

VAR pass, fail: CARDINAL;

PROCEDURE CheckB (label: ARRAY OF CHAR; got, want: BOOLEAN);
BEGIN
  WriteString(label); WriteString(" = ");
  IF got THEN WriteString("TRUE") ELSE WriteString("FALSE") END;
  IF got = want THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL]"); INC(fail) END;
  WriteLn
END CheckB;

PROCEDURE CheckByte (label: ARRAY OF CHAR; got: BYTE; want: CARDINAL);
  VAR g: CARDINAL;
BEGIN
  g := ORD(got) BAND 0FFH;
  WriteString(label); WriteString(" = "); WriteCard(g, 1);
  IF g = want THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteCard(want, 1); INC(fail) END;
  WriteLn
END CheckByte;

PROCEDURE StrEq (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  LOOP
    IF (i > HIGH(a)) OR (a[i] = 0C) THEN RETURN (i > HIGH(b)) OR (b[i] = 0C) END;
    IF (i > HIGH(b)) OR (a[i] # b[i]) THEN RETURN FALSE END;
    INC(i)
  END
END StrEq;

PROCEDURE CheckStr (label: ARRAY OF CHAR; VAR got: ARRAY OF CHAR; want: ARRAY OF CHAR);
BEGIN
  WriteString(label); WriteString(" = "); WriteString(got);
  IF StrEq(got, want) THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteString(want); INC(fail) END;
  WriteLn
END CheckStr;

PROCEDURE AsciiBytes (s: ARRAY OF CHAR; VAR b: ARRAY OF BYTE): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO b[i] := VAL(BYTE, ORD(s[i]) BAND 0FFH); INC(i) END;
  RETURN i
END AsciiBytes;

PROCEDURE BytesEqual (VAR a, b: ARRAY OF BYTE; n: CARDINAL): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE i < n DO IF (ORD(a[i]) BAND 0FFH) # (ORD(b[i]) BAND 0FFH) THEN RETURN FALSE END; INC(i) END;
  RETURN TRUE
END BytesEqual;

PROCEDURE WideEqual (VAR a, b: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN StrEq(a, b) END WideEqual;

VAR
  bytes, out: ARRAY [0..255] OF BYTE;
  text: ARRAY [0..255] OF CHAR;
  w, w2: ARRAY [0..63] OF CHAR;
  tiny1: ARRAY [0..0] OF CHAR;
  tiny2: ARRAY [0..1] OF CHAR;
  tiny4: ARRAY [0..3] OF CHAR;
  tiny5: ARRAY [0..4] OF CHAR;
  m, outn: CARDINAL;
  ok: BOOLEAN;

BEGIN
  pass := 0; fail := 0;

  WriteString("=== Base64 (RFC 4648 vectors) ==="); WriteLn;
  m := AsciiBytes("f", bytes);      ok := Base64.Encode(bytes, m, text); CheckStr("b64 f      ", text, "Zg==");
  m := AsciiBytes("fo", bytes);     ok := Base64.Encode(bytes, m, text); CheckStr("b64 fo     ", text, "Zm8=");
  m := AsciiBytes("foo", bytes);    ok := Base64.Encode(bytes, m, text); CheckStr("b64 foo    ", text, "Zm9v");
  m := AsciiBytes("foobar", bytes); ok := Base64.Encode(bytes, m, text); CheckStr("b64 foobar ", text, "Zm9vYmFy");
  ok := Base64.Decode(text, out, outn);
  CheckB("b64 rt len ", outn = m, TRUE);
  CheckB("b64 rt eq  ", BytesEqual(out, bytes, m), TRUE);

  WriteString("=== Hex ==="); WriteLn;
  bytes[0] := VAL(BYTE, 0DEH); bytes[1] := VAL(BYTE, 0ADH);
  bytes[2] := VAL(BYTE, 0BEH); bytes[3] := VAL(BYTE, 0EFH);
  ok := Hex.Encode(bytes, 4, FALSE, text); CheckStr("hex lower  ", text, "deadbeef");
  ok := Hex.Encode(bytes, 4, TRUE,  text); CheckStr("hex upper  ", text, "DEADBEEF");
  ok := Hex.Decode("deadbeef", out, outn);
  CheckB("hex dec len", outn = 4, TRUE);
  CheckB("hex dec eq ", BytesEqual(out, bytes, 4), TRUE);

  WriteString("=== UTF-8 ==="); WriteLn;
  (* "A" U+0041 -> 0x41 *)
  w[0] := 'A'; w[1] := 0C;
  ok := Utf8.Encode(w, bytes, m); CheckB("A len 1    ", m = 1, TRUE); CheckByte("  A b0     ", bytes[0], 41H);
  CheckB("A length() ", Utf8.Length(w) = 1, TRUE);
  (* "e-acute" U+00E9 -> C3 A9 *)
  w[0] := CHR(0E9H); w[1] := 0C;
  ok := Utf8.Encode(w, bytes, m); CheckB("e9 len 2   ", m = 2, TRUE);
  CheckByte("  e9 b0    ", bytes[0], 0C3H); CheckByte("  e9 b1    ", bytes[1], 0A9H);
  ok := Utf8.Decode(bytes, m, w2); CheckB("e9 round   ", WideEqual(w, w2), TRUE);
  (* euro U+20AC -> E2 82 AC *)
  w[0] := CHR(20ACH); w[1] := 0C;
  ok := Utf8.Encode(w, bytes, m); CheckB("euro len 3 ", m = 3, TRUE);
  CheckByte("  euro b0  ", bytes[0], 0E2H); CheckByte("  euro b1  ", bytes[1], 82H); CheckByte("  euro b2  ", bytes[2], 0ACH);
  ok := Utf8.Decode(bytes, m, w2); CheckB("euro round ", WideEqual(w, w2), TRUE);
  (* G-clef U+1D11E -> surrogate D834 DD1E -> F0 9D 84 9E *)
  w[0] := CHR(0D834H); w[1] := CHR(0DD1EH); w[2] := 0C;
  ok := Utf8.Encode(w, bytes, m); CheckB("clef len 4 ", m = 4, TRUE);
  CheckByte("  clef b0  ", bytes[0], 0F0H); CheckByte("  clef b1  ", bytes[1], 9DH);
  CheckByte("  clef b2  ", bytes[2], 84H);  CheckByte("  clef b3  ", bytes[3], 9EH);
  ok := Utf8.Decode(bytes, m, w2); CheckB("clef round ", WideEqual(w, w2), TRUE);

  WriteString("=== exact-fit terminator (no overrun) ==="); WriteLn;
  m := AsciiBytes("f", bytes);                          (* 1 byte -> "Zg==" (4 chars) *)
  CheckB("b64 fit FALSE ", Base64.Encode(bytes, m, tiny4), FALSE);   (* size 4: no room for NUL *)
  ok := Base64.Encode(bytes, m, tiny5);                              (* size 5: fits *)
  CheckB("b64 +1 TRUE   ", ok, TRUE);
  CheckB("b64 +1 term   ", tiny5[4] = 0C, TRUE);
  bytes[0] := VAL(BYTE, 41H);                           (* 'A' -> 1 UTF-16 unit *)
  CheckB("utf8 fit FALSE", Utf8.Decode(bytes, 1, tiny1), FALSE);     (* size 1: no room for NUL *)
  ok := Utf8.Decode(bytes, 1, tiny2);                                (* size 2: fits *)
  CheckB("utf8 +1 TRUE  ", ok, TRUE);
  CheckB("utf8 +1 term  ", tiny2[1] = 0C, TRUE);

  WriteLn;
  WriteString("PASS="); WriteCard(pass, 1);
  WriteString("  FAIL="); WriteCard(fail, 1); WriteLn
END CodecsDemo.
