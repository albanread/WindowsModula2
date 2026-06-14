MODULE t70100;
IMPORT STextIO;
PROCEDURE pick(n: CARDINAL): CHAR;
BEGIN
  CASE n OF 1: RETURN 'A' | 2: RETURN 'B' END   (* no ELSE *)
END pick;
BEGIN
  STextIO.WriteChar(pick(1));
  STextIO.WriteChar(pick(9))                      (* raises caseSelectException *)
EXCEPT
  STextIO.WriteString("X")
END t70100.
