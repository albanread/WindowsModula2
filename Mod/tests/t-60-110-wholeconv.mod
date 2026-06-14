MODULE T60110WholeConv;
(* Group 60 — ISO library. EXPECTED: 123 / -42 / 4567 / 3 *)
IMPORT STextIO, SWholeIO, WholeConv;
BEGIN
  SWholeIO.WriteInt(WholeConv.ValueInt("123"), 0); STextIO.WriteLn;
  SWholeIO.WriteInt(WholeConv.ValueInt("-42"), 0); STextIO.WriteLn;
  SWholeIO.WriteCard(WholeConv.ValueCard("4567"), 0); STextIO.WriteLn;
  SWholeIO.WriteCard(WholeConv.LengthInt(-42), 0); STextIO.WriteLn;
END T60110WholeConv.
