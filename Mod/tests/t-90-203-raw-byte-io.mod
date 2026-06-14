MODULE T90203RawByteIO;
(*
 * Group 90 — ISO channel I/O
 * Test: raw channel I/O moves bytes verbatim. A 4-byte block written with
 *       IOChan.RawWrite and read back with RawRead round-trips exactly,
 *       including a high byte (255) and an embedded NUL. Raw read/write must
 *       move bytes directly, not through the UTF-16 text path.
 *
 * EXPECTED:
 * ok
 *)
FROM StreamFile IMPORT Open, Close;
FROM ChanConsts IMPORT OpenResults, raw, write, read;
FROM IOChan IMPORT ChanId, RawWrite, RawRead;
FROM SYSTEM IMPORT ADR, BYTE;
FROM StrIO IMPORT WriteString, WriteLn;

VAR
  cid: ChanId; res: OpenResults;
  out, inp: ARRAY [0..3] OF BYTE;
  actual, i: CARDINAL; ok: BOOLEAN;
BEGIN
  out[0] := BYTE(1); out[1] := BYTE(254); out[2] := BYTE(0); out[3] := BYTE(255);
  Open(cid, 't90203raw.tmp', write+raw, res);
  IF res # opened THEN WriteString("bad"); WriteLn; HALT END;
  RawWrite(cid, ADR(out), 4); Close(cid);
  Open(cid, 't90203raw.tmp', read+raw, res);
  IF res # opened THEN WriteString("bad"); WriteLn; HALT END;
  RawRead(cid, ADR(inp), 4, actual); Close(cid);
  ok := actual = 4;
  FOR i := 0 TO 3 DO IF inp[i] # out[i] THEN ok := FALSE END END;
  IF ok THEN WriteString("ok") ELSE WriteString("bad") END;
  WriteLn
END T90203RawByteIO.
