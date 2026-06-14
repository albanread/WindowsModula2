MODULE T60090CharClass;
(* Group 60 — ISO library. EXPECTED: TFTTTT *)
IMPORT STextIO, CharClass;
PROCEDURE B(b: BOOLEAN);
BEGIN
  IF b THEN STextIO.WriteString("T"); ELSE STextIO.WriteString("F"); END;
END B;
BEGIN
  B(CharClass.IsNumeric('5'));
  B(CharClass.IsNumeric('x'));
  B(CharClass.IsLetter('A'));
  B(CharClass.IsUpper('A'));
  B(CharClass.IsLower('a'));
  B(CharClass.IsWhiteSpace(' '));
  STextIO.WriteLn;
END T60090CharClass.
