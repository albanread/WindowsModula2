MODULE Hello;
(* FastPanesM2 sample - edit, then F9 = build, F5 = run *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
VAR i: INTEGER;
BEGIN
  WriteString("Hello from FastPanesM2!"); WriteLn;
  FOR i := 1 TO 5 DO
    WriteString("  count = "); WriteInt(i, 1); WriteLn
  END
END Hello.
