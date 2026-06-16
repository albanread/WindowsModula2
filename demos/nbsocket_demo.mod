MODULE NbSocketDemo;
(*
 * Non-blocking socket test: a non-blocking listener reports "would block" with
 * no pending connection, then a poll-until-ready accept once a client connects.
 *   build: newm2 build demos/nbsocket_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM System_Threading IMPORT Sleep;
FROM WIN32 IMPORT DWORD;
IMPORT Socket;

VAR pass, fail: CARDINAL;

PROCEDURE CheckB (label: ARRAY OF CHAR; got, want: BOOLEAN);
BEGIN
  WriteString(label); WriteString(" = ");
  IF got THEN WriteString("TRUE") ELSE WriteString("FALSE") END;
  IF got = want THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL]"); INC(fail) END;
  WriteLn
END CheckB;

VAR
  srv, cli, client: Socket.Socket;
  ok: BOOLEAN; i: CARDINAL;

BEGIN
  pass := 0; fail := 0;
  WriteString("=== non-blocking sockets ==="); WriteLn;

  ok := Socket.Startup(); CheckB("startup        ", ok, TRUE);
  ok := Socket.Listen(54330, 4, srv); CheckB("listen         ", ok, TRUE);
  ok := Socket.SetBlocking(srv, FALSE); CheckB("set non-block  ", ok, TRUE);

  (* nothing pending: accept fails with WouldBlock, not a real error *)
  ok := Socket.Accept(srv, cli);
  CheckB("accept empty   ", ok, FALSE);
  CheckB("would block    ", Socket.WouldBlock(), TRUE);

  (* connect a client (blocking); the loopback handshake queues it on srv *)
  ok := Socket.Connect("127.0.0.1", 54330, client); CheckB("connect        ", ok, TRUE);

  (* poll the non-blocking accept until the connection appears *)
  i := 0; ok := FALSE;
  WHILE (i < 200) AND (NOT ok) DO
    ok := Socket.Accept(srv, cli);
    IF NOT ok THEN Sleep(VAL(DWORD, 5)) END;
    INC(i)
  END;
  CheckB("accept polled  ", ok, TRUE);

  Socket.Close(cli); Socket.Close(client); Socket.Close(srv);
  Socket.Shutdown;

  WriteLn;
  WriteString("PASS="); WriteCard(pass, 1);
  WriteString("  FAIL="); WriteCard(fail, 1); WriteLn
END NbSocketDemo.
