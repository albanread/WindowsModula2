MODULE T90191ForCharStep;
(*
 * Group 90 — FOR loops
 * Test: a FOR loop over CHAR with an ordinal (CHAR) step — `BY CHR(2)` steps
 *       the control variable by 2 each iteration.
 *
 * EXPECTED:
 * ace
 * 13
 *)
FROM StdIO IMPORT Write;
FROM StrIO IMPORT WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR
  ch: CHAR;
  count: CARDINAL;
BEGIN
  FOR ch := 'a' TO 'e' BY CHR(2) DO Write(ch) END;
  WriteLn;
  count := 0;
  FOR ch := 'a' TO 'z' BY CHR(2) DO INC(count) END;
  WriteCard(count, 0); WriteLn
END T90191ForCharStep.
