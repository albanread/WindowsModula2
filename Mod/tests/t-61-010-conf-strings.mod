MODULE t61010;
(* Conformance: Strings edge cases (Extract/Delete/Insert/Replace/FindNext). *)
IMPORT STextIO, Strings;
VAR d, s : ARRAY [0..31] OF CHAR; found : BOOLEAN; pos : CARDINAL; ok : BOOLEAN;
BEGIN
  ok := TRUE;
  Strings.Extract("hello world", 6, 5, d); IF NOT Strings.Equal(d, "world") THEN ok := FALSE END;
  Strings.Assign("hello", s); Strings.Delete(s, 1, 3); IF NOT Strings.Equal(s, "ho") THEN ok := FALSE END;
  Strings.Assign("abcd", s); Strings.Insert("XY", 2, s); IF NOT Strings.Equal(s, "abXYcd") THEN ok := FALSE END;
  Strings.Assign("abcd", s); Strings.Replace("XY", 1, s); IF NOT Strings.Equal(s, "aXYd") THEN ok := FALSE END;
  Strings.FindNext("lo", "hello world", 0, found, pos); IF (NOT found) OR (pos # 3) THEN ok := FALSE END;
  IF ok THEN STextIO.WriteString("PASS") ELSE STextIO.WriteString("FAIL") END; STextIO.WriteLn
END t61010.
