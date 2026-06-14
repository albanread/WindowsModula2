MODULE T70090GenExc;
(* Group 70 — Exceptions. EXPECTED: caught-general *)
IMPORT STextIO, GeneralUserExceptions;
BEGIN
  GeneralUserExceptions.RaiseGeneralException(GeneralUserExceptions.problem, "bad");
  STextIO.WriteString("unreached"); STextIO.WriteLn;
EXCEPT
  IF GeneralUserExceptions.IsGeneralException() THEN
    STextIO.WriteString("caught-general"); STextIO.WriteLn;
  END;
END T70090GenExc.
