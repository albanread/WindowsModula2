MODULE PipeServerTest;
(* Standalone PipeServer probe: listen on \\.\pipe\fastpanes, echo each request,
   print what arrived. Isolates PipeServer from the IDE/message-loop. *)
FROM PipeServer IMPORT Start, Poll, Reply;
FROM System_Threading IMPORT Sleep;
FROM STextIO IMPORT WriteString, WriteLn;

VAR cmd: ARRAY [0..4095] OF CHAR; reply: ARRAY [0..4159] OF CHAR;
    i, p, n: CARDINAL;

BEGIN
  IF NOT Start("fastpanes") THEN WriteString("start failed"); WriteLn; HALT END;
  WriteString("listening on fastpanes ..."); WriteLn;
  n := 0;
  LOOP
    IF Poll(cmd) THEN
      WriteString("got["); WriteString(cmd); WriteString("]"); WriteLn;
      p := 0;
      reply[0] := 'e'; reply[1] := 'c'; reply[2] := 'h'; reply[3] := 'o'; reply[4] := ':'; p := 5;
      i := 0; WHILE (cmd[i] # 0C) AND (p < 4159) DO reply[p] := cmd[i]; INC(p); INC(i) END;
      reply[p] := 0C;
      Reply(reply);
      INC(n); IF n >= 30 THEN EXIT END
    END;
    Sleep(50)
  END
END PipeServerTest.
