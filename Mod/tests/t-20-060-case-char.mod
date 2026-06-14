MODULE T20060CaseChar;
(* Group 20 — CASE on CHAR (range + list labels) and on an enumeration. *)
IMPORT STextIO;
TYPE Color = (Red, Green, Blue);
PROCEDURE name(col: Color);
BEGIN
  CASE col OF
  | Red:   STextIO.WriteString("R");
  | Green: STextIO.WriteString("G");
  | Blue:  STextIO.WriteString("B");
  END;
END name;
PROCEDURE kind(c: CHAR);
BEGIN
  CASE c OF
  | '0'..'9':            STextIO.WriteString("d");
  | 'a'..'z', 'A'..'Z':  STextIO.WriteString("a");
  ELSE                   STextIO.WriteString(".");
  END;
END kind;
BEGIN
  name(Red); name(Blue); name(Green); STextIO.WriteLn;
  kind('7'); kind('Q'); kind('!'); kind('m'); STextIO.WriteLn;
END T20060CaseChar.
