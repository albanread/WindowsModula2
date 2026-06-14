MODULE T90161AdrString;
(*
 * Group 90 — SYSTEM / codegen
 * Test: ADR of a string literal (a non-lvalue) yields the address of the
 *       interned, null-terminated data.
 *
 * EXPECTED:
 * 11
 *)
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM StrIO IMPORT WriteLn;
FROM SWholeIO IMPORT WriteCard;

PROCEDURE Len (a: ADDRESS): CARDINAL;
VAR
  i: CARDINAL;
  p: POINTER TO CHAR;
BEGIN
  i := 0;
  p := a;
  WHILE p^ # 0C DO
    INC(i);
    INC(p)
  END;
  RETURN i
END Len;

BEGIN
  WriteCard(Len(ADR("hello world")), 0); WriteLn   (* 11 *)
END T90161AdrString.
