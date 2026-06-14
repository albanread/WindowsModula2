IMPLEMENTATION MODULE FIO;

IMPORT STextIO, SWholeIO;

PROCEDURE WriteChar (f: File; ch: CHAR);
BEGIN
  STextIO.WriteChar(ch)
END WriteChar;

PROCEDURE WriteString (f: File; s: ARRAY OF CHAR);
BEGIN
  STextIO.WriteString(s)
END WriteString;

PROCEDURE WriteLine (f: File);
BEGIN
  STextIO.WriteLn
END WriteLine;

PROCEDURE WriteCardinal (f: File; c: CARDINAL);
BEGIN
  SWholeIO.WriteCard(c, 0)
END WriteCardinal;

PROCEDURE FlushBuffer (f: File);
BEGIN
END FlushBuffer;

PROCEDURE Close (f: File);
BEGIN
END Close;

PROCEDURE IsNoError (f: File): BOOLEAN;
BEGIN
  RETURN TRUE
END IsNoError;

PROCEDURE EOF (f: File): BOOLEAN;
BEGIN
  RETURN TRUE
END EOF;

PROCEDURE OpenToWrite (fname: ARRAY OF CHAR): File;
BEGIN
  RETURN StdOut
END OpenToWrite;

PROCEDURE OpenToRead (fname: ARRAY OF CHAR): File;
BEGIN
  RETURN StdIn
END OpenToRead;

BEGIN
  StdIn  := 0;
  StdOut := 1;
  StdErr := 2
END FIO.
