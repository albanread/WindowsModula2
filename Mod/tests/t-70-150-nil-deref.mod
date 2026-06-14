MODULE t70150;
IMPORT STextIO, M2EXCEPTION;
TYPE NodePtr = POINTER TO Node;
     Node = RECORD value : INTEGER; END;
VAR p : NodePtr; x : INTEGER;
BEGIN
  p := NIL; x := 0;
  x := p^.value            (* NIL dereference -> invalidLocation *)
EXCEPT
  IF M2EXCEPTION.IsM2Exception() AND
     (M2EXCEPTION.M2Exception() = M2EXCEPTION.invalidLocation) THEN
    STextIO.WriteString("nilderef")
  ELSE
    STextIO.WriteString("other")
  END;
  STextIO.WriteLn
END t70150.
