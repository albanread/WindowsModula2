MODULE T50090ByteArrayParam;
(*
 * Group 50 — SYSTEM / low-level
 * Test: a formal parameter of `ARRAY OF SYSTEM.BYTE` accepts an actual of any
 *       type (ISO LOC-view), and HIGH reflects the actual's storage size.
 *
 * EXPECTED:
 * 8
 * 2
 * 8
 *)
FROM SYSTEM IMPORT BYTE;
FROM STextIO IMPORT WriteLn;
FROM SWholeIO IMPORT WriteCard;

PROCEDURE sizeBytes(b: ARRAY OF BYTE);
BEGIN
  WriteCard(HIGH(b) + 1, 0); WriteLn
END sizeBytes;

VAR
  i: INTEGER;
  ch: CHAR;
  c: CARDINAL;

BEGIN
  i := 42; ch := "x"; c := 9;
  sizeBytes(i);    (* INTEGER  = 8 bytes *)
  sizeBytes(ch);   (* CHAR     = 2 bytes (UTF-16 unit) *)
  sizeBytes(c)     (* CARDINAL = 8 bytes *)
END T50090ByteArrayParam.
