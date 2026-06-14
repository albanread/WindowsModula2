MODULE T70050ProcOpenArray;
(*
 * Group 70 — Exceptions
 * Test: a procedure with EXCEPT whose protected region uses an open-array
 *       parameter (HIGH + indexing) and a VAR out-parameter, both shared with
 *       the outlined protected function through the exception frame; the
 *       handler writes the VAR out-parameter.
 *
 * EXPECTED:
 * 131
 * 9999
 *)
IMPORT STextIO, SWholeIO, NM2RT;
VAR src: NM2RT.ExceptionSource;
    r: CARDINAL;

PROCEDURE SumOrFlag(data: ARRAY OF CHAR; VAR result: CARDINAL);
VAR i: CARDINAL;
BEGIN
  result := 0;
  i := 0;
  WHILE i <= HIGH(data) DO
    result := result + ORD(data[i]);
    INC(i);
  END;
  IF result > 1000 THEN
    NM2RT.Raise(src, 1, "toobig");
  END;
EXCEPT
  result := 9999;
END SumOrFlag;

BEGIN
  src := NM2RT.AllocateExceptionSource();
  SumOrFlag("AB", r);
  SWholeIO.WriteCard(r, 0);
  STextIO.WriteLn;
  SumOrFlag("AAAAAAAAAAAAAAAAAAAA", r);
  SWholeIO.WriteCard(r, 0);
  STextIO.WriteLn;
END T70050ProcOpenArray.
