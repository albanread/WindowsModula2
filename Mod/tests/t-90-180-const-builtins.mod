MODULE T90180ConstBuiltins;
(*
 * Group 90 — constant folding
 * Test: ODD / CAP / LENGTH fold in constant expressions, and `+` concatenates
 *       string constants (multi-character literals). Each CONST below would be
 *       rejected as "not constant" before these were foldable.
 *
 * EXPECTED:
 * 1 0
 * 90
 * 11
 *)
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

CONST
  oddYes = ODD(7);
  oddNo  = ODD(8);
  capZ   = CAP("z");
  greeting = "Hello" + ", " + "world";   (* 12 chars *)
  glen   = LENGTH(greeting) - 1;          (* 11 *)

BEGIN
  IF oddYes THEN WriteCard(1, 0) ELSE WriteCard(0, 0) END; WriteString(" ");
  IF oddNo THEN WriteCard(1, 0) ELSE WriteCard(0, 0) END; WriteLn;   (* 1 0 *)
  WriteCard(ORD(capZ), 0); WriteLn;                                  (* 90 = 'Z' *)
  WriteCard(glen, 0); WriteLn                                        (* 11 *)
END T90180ConstBuiltins.
