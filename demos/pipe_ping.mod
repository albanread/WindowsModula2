MODULE PipePing;
(* Smoke-test the M2 named-pipe client against the resident compiler daemon.
   Run the daemon first:  newm2-driver daemon --library library --pipe newm2test  *)
FROM PipeClient IMPORT Connect, Request, Close;
FROM SYSTEM IMPORT ADDRESS;
FROM STextIO IMPORT WriteString, WriteLn;

VAR h: ADDRESS; reply: ARRAY [0..8191] OF CHAR; ok: BOOLEAN;

PROCEDURE Show (cmd: ARRAY OF CHAR);
BEGIN
  WriteString(cmd); WriteString("  ->  ");
  IF Request(h, cmd, reply) THEN WriteString(reply) ELSE WriteString("<request failed>") END;
  WriteLn
END Show;

BEGIN
  h := Connect("newm2test");
  IF h = NIL THEN
    WriteString("could not connect to the daemon (is it running?)"); WriteLn
  ELSE
    Show("ping");
    Show("version");
    Show("check e:\NewModula2\projects\FastPanesM2\sample.mod");
    Close(h)
  END
END PipePing.
