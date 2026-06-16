MODULE ConcurrentServerDemo;
(*
 * The async showcase: ONE server thread (IOCP + fibers) serving MANY simultaneous
 * connections. 8 client threads connect at the same instant and each does a
 * 4 KB echo round-trip; the single-threaded server multiplexes all 8 as fibers.
 *   build: newm2 build demos/concurrent_server_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM System_Threading IMPORT Sleep;
FROM WIN32 IMPORT DWORD;
IMPORT SocketServer, Socket, Threads;

CONST NClients = 8; MsgLen = 4096;

VAR
  gPort, gRemaining: CARDINAL;
  gLock: Threads.Lock;
  gResult: ARRAY [0..NClients-1] OF BOOLEAN;
  gReady: BOOLEAN;

PROCEDURE EchoHandler (c: SocketServer.Conn);
  VAR buf: ARRAY [0..MsgLen-1] OF BYTE; n: CARDINAL;
BEGIN
  LOOP
    IF NOT SocketServer.Recv(c, ADR(buf), MsgLen, n) THEN RETURN END;
    IF n = 0 THEN RETURN END;
    IF NOT SocketServer.Send(c, ADR(buf), n) THEN RETURN END
  END
END EchoHandler;

(* send MsgLen bytes all equal to `fill`, read the echo back, verify integrity *)
PROCEDURE EchoRoundTrip (fill: CARDINAL): BOOLEAN;
  VAR s: Socket.Socket; sb, rb: ARRAY [0..MsgLen-1] OF BYTE; i: CARDINAL; ok, eq: BOOLEAN;
BEGIN
  i := 0; WHILE i < MsgLen DO sb[i] := VAL(BYTE, fill BAND 0FFH); INC(i) END;
  ok := FALSE; i := 0;
  WHILE (NOT ok) AND (i < 150) DO
    ok := Socket.Connect("127.0.0.1", gPort, s);
    IF NOT ok THEN Sleep(VAL(DWORD, 20)) END; INC(i)
  END;
  IF NOT ok THEN RETURN FALSE END;
  IF NOT Socket.SendAll(s, ADR(sb), MsgLen) THEN Socket.Close(s); RETURN FALSE END;
  (* TCP is a stream — RecvAll reads back exactly MsgLen bytes however it fragments *)
  IF NOT Socket.RecvAll(s, ADR(rb), MsgLen) THEN Socket.Close(s); RETURN FALSE END;
  Socket.Close(s);
  eq := TRUE; i := 0;
  WHILE (i < MsgLen) AND eq DO IF (ORD(rb[i]) BAND 0FFH) # (fill BAND 0FFH) THEN eq := FALSE END; INC(i) END;
  RETURN eq
END EchoRoundTrip;

PROCEDURE Client (param: ADDRESS): CARDINAL;
  VAR id: CARDINAL; last: BOOLEAN;
BEGIN
  id := CAST(CARDINAL, param);
  WHILE NOT gReady DO Sleep(VAL(DWORD, 5)) END;       (* all clients start together *)
  gResult[id] := EchoRoundTrip(id + 1);               (* each client uses a distinct fill byte *)
  Threads.Acquire(gLock);
  DEC(gRemaining); last := gRemaining = 0;
  Threads.Release(gLock);
  IF last THEN SocketServer.Stop END;                 (* the last one home stops the server *)
  RETURN 0
END Client;

VAR
  th: ARRAY [0..NClients-1] OF Threads.Thread;
  i, ok2cnt: CARDINAL; ok: BOOLEAN;

BEGIN
  gPort := 54341; gRemaining := NClients; gReady := FALSE;
  Threads.InitLock(gLock);
  WriteString("=== concurrent async server: "); WriteCard(NClients, 1);
  WriteString(" clients, 1 server thread (IOCP + fibers) ==="); WriteLn;

  ok := Socket.Startup();
  i := 0; WHILE i < NClients DO gResult[i] := FALSE; th[i] := Threads.Spawn(Client, CAST(ADDRESS, i)); INC(i) END;
  gReady := TRUE;                                     (* release all clients at once *)
  ok := SocketServer.Run(gPort, EchoHandler);         (* one thread serves them all *)

  i := 0; WHILE i < NClients DO ok := Threads.Join(th[i], 5000); Threads.CloseThread(th[i]); INC(i) END;
  Socket.Shutdown; Threads.DestroyLock(gLock);

  ok2cnt := 0; i := 0;
  WHILE i < NClients DO
    WriteString("  client "); WriteCard(i, 1); WriteString(": ");
    IF gResult[i] THEN WriteString("OK"); INC(ok2cnt) ELSE WriteString("FAIL") END; WriteLn;
    INC(i)
  END;
  WriteLn;
  WriteString("served "); WriteCard(ok2cnt, 1); WriteString("/"); WriteCard(NClients, 1);
  WriteString(" concurrent connections");
  IF ok2cnt = NClients THEN WriteString("   [PASS]") ELSE WriteString("   [FAIL]") END; WriteLn
END ConcurrentServerDemo.
