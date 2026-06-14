MODULE T60030OpenArray;
(*
 * Group 60 — open-array ABI. HIGH/LEN via the synthesised HIGH companion,
 * and element indexing of an open-array parameter.
 *
 * EXPECTED:
 * 4
 * 4
 * 4
 * 5
 * 15
 *)
IMPORT STextIO, SWholeIO;

PROCEDURE HInt(a : ARRAY OF INTEGER) : INTEGER;
BEGIN
  RETURN HIGH(a)
END HInt;

PROCEDURE HChar(s : ARRAY OF CHAR) : INTEGER;
BEGIN
  RETURN HIGH(s)
END HChar;

PROCEDURE Sum(a : ARRAY OF INTEGER) : INTEGER;
VAR i, s : INTEGER;
BEGIN
  s := 0;
  FOR i := 0 TO HIGH(a) DO
    s := s + a[i]
  END;
  RETURN s
END Sum;

VAR nums : ARRAY [0..4] OF INTEGER;
    i : INTEGER;
BEGIN
  FOR i := 0 TO 4 DO nums[i] := i + 1 END;       (* 1,2,3,4,5 *)
  SWholeIO.WriteInt(HIGH(nums), 0); STextIO.WriteLn;     (* 4 *)
  SWholeIO.WriteInt(HInt(nums), 0); STextIO.WriteLn;     (* 4 *)
  SWholeIO.WriteInt(HChar("hello"), 0); STextIO.WriteLn; (* 4 *)
  SWholeIO.WriteInt(LEN(nums), 0); STextIO.WriteLn;      (* 5 *)
  SWholeIO.WriteInt(Sum(nums), 0); STextIO.WriteLn;      (* 15 *)
END T60030OpenArray.
