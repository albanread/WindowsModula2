MODULE T90249NarrowAcharLiteral;
(*
 * Group 90 — NARROW (8-bit ACHAR) string-literal assignment. A narrow literal
 * `"..."A` (and a narrow string CONST) assigned to an `ARRAY OF ACHAR` must copy
 * the BYTES, not the literal's pointer/descriptor bits. The string->array copy
 * path must cover the narrow (ACHAR) array kind as well as the WIDE (CHAR/UCHAR)
 * one. The NM2Str.WNCopy runtime routine reads the UTF-16 literal and writes
 * each code unit's low byte.
 *
 * EXPECTED:
 * 109 97 105 110 0
 * main
 * 104 105 0
 *)
FROM STextIO IMPORT WriteChar, WriteLn;
FROM SWholeIO IMPORT WriteInt;

CONST Greeting = "hi"A;

VAR
  a: ARRAY [0..15] OF ACHAR;
  b: ARRAY [0..7] OF ACHAR;
  i: CARDINAL;
BEGIN
  a := "main"A;                          (* narrow literal -> ACHAR array *)
  WriteInt(ORD(a[0]), 0); WriteChar(' ');
  WriteInt(ORD(a[1]), 0); WriteChar(' ');
  WriteInt(ORD(a[2]), 0); WriteChar(' ');
  WriteInt(ORD(a[3]), 0); WriteChar(' ');
  WriteInt(ORD(a[4]), 0); WriteLn;        (* the NUL terminator survives *)

  i := 0;                                 (* round-trip the bytes back to chars *)
  WHILE (i <= 15) AND (ORD(a[i]) # 0) DO
    WriteChar(CHR(ORD(a[i]))); INC(i)
  END;
  WriteLn;

  b := Greeting;                          (* narrow string CONST -> ACHAR array *)
  WriteInt(ORD(b[0]), 0); WriteChar(' ');
  WriteInt(ORD(b[1]), 0); WriteChar(' ');
  WriteInt(ORD(b[2]), 0); WriteLn
END T90249NarrowAcharLiteral.
