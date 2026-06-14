MODULE T80030RealIO;
(* Group 80 — ISO RealIO over a channel: fixed-point real output with field
   widths, through StdChans + the XReal formatting engine. *)
IMPORT RealIO, StdChans, IOChan, TextIO;
VAR out: IOChan.ChanId;
BEGIN
  out := StdChans.OutChan();
  RealIO.WriteFixed(out, 3.14159, 2, 8); TextIO.WriteLn(out);
  RealIO.WriteFixed(out, 0.5, 3, 6);     TextIO.WriteLn(out);
  RealIO.WriteFixed(out, 100.0, 1, 0);   TextIO.WriteLn(out);
END T80030RealIO.
