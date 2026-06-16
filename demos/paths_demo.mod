MODULE PathsDemo;
(*
 * Exercises PathStr (pure path strings) and DirIter (real directory enumeration).
 *   build: newm2 build demos/paths_demo.mod   then run the .exe from the repo root
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
IMPORT PathStr, DirIter;

VAR pass, fail: CARDINAL;

PROCEDURE StrEqV (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  LOOP
    IF (i > HIGH(a)) OR (a[i] = 0C) THEN RETURN (i > HIGH(b)) OR (b[i] = 0C) END;
    IF (i > HIGH(b)) OR (a[i] # b[i]) THEN RETURN FALSE END;
    INC(i)
  END
END StrEqV;

PROCEDURE Eq (a, b: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN StrEqV(a, b) END Eq;

PROCEDURE CheckS (label: ARRAY OF CHAR; VAR got: ARRAY OF CHAR; want: ARRAY OF CHAR);
BEGIN
  WriteString(label); WriteString(" = '"); WriteString(got); WriteString("'");
  IF StrEqV(got, want) THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want '"); WriteString(want); WriteString("'"); INC(fail) END;
  WriteLn
END CheckS;

PROCEDURE CheckB (label: ARRAY OF CHAR; got, want: BOOLEAN);
BEGIN
  WriteString(label); WriteString(" = ");
  IF got THEN WriteString("TRUE") ELSE WriteString("FALSE") END;
  IF got = want THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL]"); INC(fail) END;
  WriteLn
END CheckB;

VAR
  s, name: ARRAY [0..511] OF CHAR;
  it: DirIter.Iter;
  isDir, foundWrtdef, wrtdefIsDir, anyDot: BOOLEAN;
  size, count: CARDINAL;

BEGIN
  pass := 0; fail := 0;

  WriteString("=== PathStr ==="); WriteLn;
  PathStr.Join("a", "b", s);                 CheckS("join a,b     ", s, "a\b");
  PathStr.Join("a\", "b", s);                CheckS("join a\\,b    ", s, "a\b");
  PathStr.Join("a/", "b", s);                CheckS("join a/,b     ", s, "a/b");
  PathStr.DirName("a\b\c.txt", s);           CheckS("dirname       ", s, "a\b");
  PathStr.BaseName("a\b\c.txt", s);          CheckS("basename      ", s, "c.txt");
  PathStr.Ext("a\b\c.txt", s);               CheckS("ext           ", s, ".txt");
  PathStr.Ext("noext", s);                   CheckS("ext none      ", s, "");
  PathStr.Ext(".gitignore", s);              CheckS("ext hidden    ", s, "");
  PathStr.StripExt("a\b\c.txt", s);          CheckS("stripext      ", s, "a\b\c");
  PathStr.ChangeExt("c.txt", ".md", s);      CheckS("changeext     ", s, "c.md");
  PathStr.ChangeExt("noext", ".md", s);      CheckS("changeext add ", s, "noext.md");
  PathStr.BaseName("justfile", s);           CheckS("basename bare ", s, "justfile");
  PathStr.DirName("justfile", s);            CheckS("dirname bare  ", s, "");
  CheckB("abs drive    ", PathStr.IsAbsolute("C:\proj"), TRUE);
  CheckB("abs rel      ", PathStr.IsAbsolute("src\x"), FALSE);
  CheckB("abs unc      ", PathStr.IsAbsolute("\\srv\share"), TRUE);

  WriteString("=== DirIter (enumerate 'library') ==="); WriteLn;
  IF DirIter.Open("library", it) THEN
    count := 0; foundWrtdef := FALSE; wrtdefIsDir := FALSE; anyDot := FALSE;
    WHILE DirIter.Next(it, name, isDir, size) DO
      INC(count);
      IF Eq(name, "winrtdef") THEN foundWrtdef := TRUE; wrtdefIsDir := isDir END;
      IF Eq(name, ".") OR Eq(name, "..") THEN anyDot := TRUE END
    END;
    DirIter.Close(it);
    CheckB("opened       ", TRUE, TRUE);
    CheckB("count > 5    ", count > 5, TRUE);
    CheckB("found winrtdef", foundWrtdef, TRUE);
    CheckB("winrtdef dir ", wrtdefIsDir, TRUE);
    CheckB("no . / ..    ", anyDot, FALSE)
  ELSE
    CheckB("opened       ", FALSE, TRUE)    (* fail: couldn't open library/ *)
  END;

  WriteLn;
  WriteString("PASS="); WriteCard(pass, 1);
  WriteString("  FAIL="); WriteCard(fail, 1); WriteLn
END PathsDemo.
