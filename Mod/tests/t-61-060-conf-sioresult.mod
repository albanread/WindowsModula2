MODULE t61060;
(* Conformance: SIOResult resolves its def-only IOConsts import. *)
IMPORT STextIO, SIOResult, IOConsts;
VAR r : SIOResult.ReadResults;
BEGIN
  r := SIOResult.ReadResult();
  IF r = IOConsts.notKnown THEN STextIO.WriteString("notKnown") ELSE STextIO.WriteString("other") END;
  STextIO.WriteLn
END t61060.
