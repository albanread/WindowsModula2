MODULE t61070;
(* Conformance: HALT runs finalizers (ISO), and TERMINATION.HasHalted observes it. *)
IMPORT STextIO, TERMINATION;
BEGIN
  STextIO.WriteString("before"); STextIO.WriteLn;
  HALT;
  STextIO.WriteString("after-halt"); STextIO.WriteLn
FINALLY
  IF TERMINATION.HasHalted() THEN STextIO.WriteString("halted") ELSE STextIO.WriteString("normal") END;
  STextIO.WriteLn
END t61070.
