MODULE T90170StringArrayAssign;
(*
 * Group 90 — strings / assignment
 * Test: assigning a string literal or string CONST to a fixed ARRAY OF CHAR
 *       copies the characters (NUL-padding when shorter, exact-fit when equal),
 *       rather than storing the source pointer's bits. Indexing then reads the
 *       individual characters back.
 *
 * EXPECTED:
 * ABCD
 * 65 66 67 68
 * xyz
 *)
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

CONST greeting = "xyz";

VAR
  s:     ARRAY [0..9] OF CHAR;   (* room to spare — NUL-padded *)
  exact: ARRAY [0..3] OF CHAR;   (* exact fit — no terminator *)
  g:     ARRAY [0..9] OF CHAR;
  i:     CARDINAL;

BEGIN
  s := "ABCD";
  WriteString(s); WriteLn;                       (* ABCD *)

  exact := "ABCD";
  FOR i := 0 TO 3 DO
    WriteCard(ORD(exact[i]), 0);
    IF i < 3 THEN WriteString(" ") END
  END;
  WriteLn;                                        (* 65 66 67 68 *)

  g := greeting;                                  (* string CONST *)
  WriteString(g); WriteLn                         (* xyz *)
END T90170StringArrayAssign.
