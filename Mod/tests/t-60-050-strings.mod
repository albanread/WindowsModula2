MODULE T60050Strings;
(*
 * Group 60 — ISO library
 * Test: thin Strings implementation over open-array CHAR primitives.
 *
 * EXPECTED:
 * 5
 * eq
 * ne
 * world
 * 5
 * foobar
 * HELLO
 * abcd
 * less
 *)
IMPORT STextIO, SWholeIO;
IMPORT Strings;

VAR buf: ARRAY [0..63] OF CHAR;

PROCEDURE Yes (b: BOOLEAN);
BEGIN
  IF b THEN
    STextIO.WriteString("eq");
  ELSE
    STextIO.WriteString("ne");
  END;
  STextIO.WriteLn;
END Yes;

BEGIN
  SWholeIO.WriteCard(Strings.Length("hello"), 0);
  STextIO.WriteLn;

  Yes(Strings.Equal("abc", "abc"));
  Yes(Strings.Equal("abc", "abd"));

  Strings.Assign("world", buf);
  STextIO.WriteString(buf);
  STextIO.WriteLn;
  SWholeIO.WriteCard(Strings.Length(buf), 0);
  STextIO.WriteLn;

  Strings.Concat("foo", "bar", buf);
  STextIO.WriteString(buf);
  STextIO.WriteLn;

  Strings.Assign("hello", buf);
  Strings.Capitalize(buf);
  STextIO.WriteString(buf);
  STextIO.WriteLn;

  Strings.Assign("ab", buf);
  Strings.Append("cd", buf);
  STextIO.WriteString(buf);
  STextIO.WriteLn;

  IF Strings.Compare("apple", "banana") = Strings.less THEN
    STextIO.WriteString("less");
  ELSE
    STextIO.WriteString("notless");
  END;
  STextIO.WriteLn;
END T60050Strings.
