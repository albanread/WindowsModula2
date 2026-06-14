MODULE T80040FileIO;
(* Group 80 — ISO SeqFile round-trip through the file device + NM2File runtime:
   write text to a file via a channel, close, reopen, read it back.
   EXPECTED: file-roundtrip *)
IMPORT SeqFile, TextIO, STextIO, ChanConsts;
VAR cid: SeqFile.ChanId; res: ChanConsts.OpenResults; buf: ARRAY [0..63] OF CHAR;
BEGIN
  SeqFile.OpenWrite(cid, "t80040rt.tmp", SeqFile.write + SeqFile.text, res);
  IF res = ChanConsts.opened THEN
    TextIO.WriteString(cid, "file-roundtrip");
    SeqFile.Close(cid);
    SeqFile.OpenRead(cid, "t80040rt.tmp", SeqFile.read + SeqFile.text, res);
    IF res = ChanConsts.opened THEN
      TextIO.ReadString(cid, buf);
      SeqFile.Close(cid);
      STextIO.WriteString(buf); STextIO.WriteLn;
    END;
  END;
END T80040FileIO.
