IMPLEMENTATION MODULE StrLib;

IMPORT Strings;

PROCEDURE StrEqual (a, b: ARRAY OF CHAR) : BOOLEAN;
BEGIN
  RETURN Strings.Equal(a, b)
END StrEqual;

PROCEDURE StrLen (s: ARRAY OF CHAR) : CARDINAL;
BEGIN
  RETURN Strings.Length(s)
END StrLen;

PROCEDURE StrCopy (src: ARRAY OF CHAR; VAR dest: ARRAY OF CHAR);
BEGIN
  Strings.Assign(src, dest)
END StrCopy;

END StrLib.
