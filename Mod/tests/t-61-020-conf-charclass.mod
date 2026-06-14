MODULE t61020;
(* Conformance: CharClass control/whitespace/boundaries. *)
IMPORT STextIO, CharClass;
VAR ok : BOOLEAN;
BEGIN
  ok := CharClass.IsControl(CHR(9)) AND (NOT CharClass.IsControl("A"))
    AND CharClass.IsWhiteSpace(CHR(9)) AND (NOT CharClass.IsWhiteSpace("x"))
    AND CharClass.IsLetter("Z") AND (NOT CharClass.IsLetter("["))
    AND CharClass.IsNumeric("0") AND (NOT CharClass.IsNumeric(":"));
  IF ok THEN STextIO.WriteString("PASS") ELSE STextIO.WriteString("FAIL") END; STextIO.WriteLn
END t61020.
