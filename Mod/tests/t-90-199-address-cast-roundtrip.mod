MODULE T90199AddressCastRoundtrip;
(*
 * Group 90 — SYSTEM casts
 * Test: ADDRESS/CAST conversions between integer and pointer must not crash
 *       codegen — `ADDRESS(0)` (int -> ptr), `CAST(CARDINAL, addr)` (ptr ->
 *       int), and a pointer-typed value flowing into a pointer cast all lower
 *       cleanly.
 *
 * EXPECTED:
 * nonzero
 * nil
 *)
FROM SYSTEM IMPORT ADDRESS, CAST, ADR;
FROM StrIO IMPORT WriteString, WriteLn;

VAR a: ADDRESS; c: CARDINAL; x: CARDINAL;
BEGIN
  x := 7;
  a := ADR(x);
  c := CAST(CARDINAL, a);              (* pointer -> integer *)
  IF c # 0 THEN WriteString("nonzero") ELSE WriteString("zero") END;
  WriteLn;
  a := ADDRESS(0);                     (* integer 0 -> pointer (NIL) *)
  IF a = NIL THEN WriteString("nil") ELSE WriteString("notnil") END;
  WriteLn
END T90199AddressCastRoundtrip.
