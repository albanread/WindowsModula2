MODULE t20090;
IMPORT STextIO;
PROCEDURE classify(n: CARDINAL): CHAR;
BEGIN
  CASE n OF
    0..299:   RETURN 'L'
  | 300..999: RETURN 'H'
  | 1000:     RETURN 'M'
  ELSE        RETURN '?'
  END
END classify;
BEGIN
  STextIO.WriteChar(classify(5)); STextIO.WriteChar(classify(280));
  STextIO.WriteChar(classify(800)); STextIO.WriteChar(classify(1000));
  STextIO.WriteChar(classify(2000)); STextIO.WriteLn;
END t20090.
