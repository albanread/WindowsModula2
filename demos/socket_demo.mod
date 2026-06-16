MODULE SocketDemo;
(*
 * Loopback echo test for the Socket module: a server thread accepts one client
 * and echoes one message; the main thread connects, sends "PING", and checks
 * the echo. A real round-trip through Winsock on 127.0.0.1.
 *   build: newm2 build demos/socket_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
IMPORT Socket, Threads;

VAR pass, fail: CARDINAL;

PROCEDURE CheckB (label: ARRAY OF CHAR; got, want: BOOLEAN);
BEGIN
  WriteString(label); WriteString(" = ");
  IF got THEN WriteString("TRUE") ELSE WriteString("FALSE") END;
  IF got = want THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL]"); INC(fail) END;
  WriteLn
END CheckB;

PROCEDURE Check (label: ARRAY OF CHAR; got, want: CARDINAL);
BEGIN
  WriteString(label); WriteString(" = "); WriteCard(got, 1);
  IF got = want THEN WriteString("   [PASS]"); INC(pass)
  ELSE WriteString("   [FAIL] want "); WriteCard(want, 1); INC(fail) END;
  WriteLn
END Check;

(* server thread: accept one client, echo whatever it sends once, close *)
PROCEDURE ServerProc (param: ADDRESS): CARDINAL;
  VAR srv, cli: Socket.Socket; buf: ARRAY [0..255] OF BYTE; got: CARDINAL; ok: BOOLEAN;
BEGIN
  srv := CAST(Socket.Socket, param);
  IF Socket.Accept(srv, cli) THEN
    IF Socket.Recv(cli, ADR(buf), 256, got) AND (got > 0) THEN
      ok := Socket.SendAll(cli, ADR(buf), got)
    END;
    Socket.Close(cli)
  END;
  RETURN 0
END ServerProc;

VAR
  srv, cli: Socket.Socket;
  th: Threads.Thread;
  msg, rbuf: ARRAY [0..255] OF BYTE;
  got, i: CARDINAL;
  ok, eq: BOOLEAN;
  text: ARRAY [0..7] OF CHAR;

BEGIN
  pass := 0; fail := 0;
  WriteString("=== Socket loopback echo ==="); WriteLn;

  ok := Socket.Startup(); CheckB("startup     ", ok, TRUE);

  ok := Socket.Listen(54321, 4, srv); CheckB("listen      ", ok, TRUE);
  th := Threads.Spawn(ServerProc, CAST(ADDRESS, srv));

  ok := Socket.Connect("127.0.0.1", 54321, cli); CheckB("connect     ", ok, TRUE);

  (* send "PING" (4 bytes) *)
  text := "PING";
  i := 0; WHILE i < 4 DO msg[i] := VAL(BYTE, ORD(text[i]) BAND 0FFH); INC(i) END;
  ok := Socket.SendAll(cli, ADR(msg), 4); CheckB("send        ", ok, TRUE);

  ok := Socket.Recv(cli, ADR(rbuf), 256, got); CheckB("recv        ", ok, TRUE);
  Check("echo length ", got, 4);
  eq := got = 4;
  i := 0; WHILE (i < 4) AND eq DO IF rbuf[i] # msg[i] THEN eq := FALSE END; INC(i) END;
  CheckB("echo matches", eq, TRUE);

  Socket.Close(cli);
  ok := Threads.Join(th, 3000); CheckB("server joined", ok, TRUE);
  Threads.CloseThread(th);
  Socket.Close(srv);
  Socket.Shutdown;

  WriteLn;
  WriteString("PASS="); WriteCard(pass, 1);
  WriteString("  FAIL="); WriteCard(fail, 1); WriteLn
END SocketDemo.
