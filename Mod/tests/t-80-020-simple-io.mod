MODULE T80020SimpleIO;
(* Group 80 — simple I/O facades (the S-prefixed modules) over the default
   StdChans channels. *)
IMPORT STextIO, SWholeIO;
BEGIN
  STextIO.WriteString("x="); SWholeIO.WriteCard(7, 3); STextIO.WriteLn;
  SWholeIO.WriteInt(-5, 0); STextIO.WriteLn;
END T80020SimpleIO.
