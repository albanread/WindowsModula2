MODULE T80010ChanIO;
(* Group 80 — ISO channel I/O through the device-dispatch stack:
   TextIO/WholeIO over StdChans.OutChan(). *)
IMPORT TextIO, WholeIO, StdChans, IOChan;
VAR out: IOChan.ChanId;
BEGIN
  out := StdChans.OutChan();
  TextIO.WriteString(out, "hello"); TextIO.WriteLn(out);
  WholeIO.WriteCard(out, 1234, 6); TextIO.WriteLn(out);
  WholeIO.WriteInt(out, -42, 0); TextIO.WriteLn(out);
END T80010ChanIO.
