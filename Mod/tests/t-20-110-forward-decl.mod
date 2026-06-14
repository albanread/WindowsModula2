MODULE T20110ForwardDecl;
(*
 * Group 20 — Control flow / procedures
 * Test: a `PROCEDURE p ; FORWARD ;` forward declaration (PIM/ISO form, the
 *       directive after the header semicolon) lets two procedures be mutually
 *       recursive regardless of declaration order.
 *
 * EXPECTED:
 * even
 * odd
 *)
FROM STextIO IMPORT WriteString, WriteLn;

PROCEDURE isEven(n: CARDINAL): BOOLEAN; FORWARD;

PROCEDURE isOdd(n: CARDINAL): BOOLEAN;
BEGIN
  IF n = 0 THEN RETURN FALSE ELSE RETURN isEven(n - 1) END
END isOdd;

PROCEDURE isEven(n: CARDINAL): BOOLEAN;
BEGIN
  IF n = 0 THEN RETURN TRUE ELSE RETURN isOdd(n - 1) END
END isEven;

BEGIN
  IF isEven(10) THEN WriteString("even") ELSE WriteString("odd") END; WriteLn;
  IF isEven(7)  THEN WriteString("even") ELSE WriteString("odd") END; WriteLn
END T20110ForwardDecl.
