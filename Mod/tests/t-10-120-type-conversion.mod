MODULE T10120TypeConversion;
(*
 * Group 10 — Arithmetic
 * Test: scalar value conversions `T(x)` lower as casts, not as a call to a
 *       non-existent function `@T`. Covers INTEGER/CARDINAL/CHAR and the
 *       ADDRESS family (ADDRESS(0) = NIL).
 *
 * EXPECTED:
 * 300
 * 10
 * 66
 * isnil
 *)
FROM SYSTEM IMPORT ADDRESS;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard, WriteInt;

VAR
  i: INTEGER;
  c: CARDINAL;
  ch: CHAR;
  p: ADDRESS;

BEGIN
  c := 300;
  WriteInt(INTEGER(c), 0); WriteLn;        (* 300 *)
  i := -3;
  WriteCard(CARDINAL(i + 13), 0); WriteLn; (* 10 *)
  ch := "B";
  WriteCard(INTEGER(ch), 0); WriteLn;      (* 66 *)
  p := ADDRESS(0);
  IF p = NIL THEN WriteString("isnil") END; WriteLn
END T10120TypeConversion.
