MODULE DrainServerDemo;
(*
 * Tests graceful shutdown WITH an active connection: a client does one round-trip
 * then holds the connection idle (so the server's fiber is suspended in Recv);
 * Stop must then close + unwind that in-flight connection and return — not hang
 * or leak. (If the drain didn't converge, this would time out.)
 *   build: newm2 build demos/drain_server_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM System_Threading IMPORT Sleep;
FROM WIN32 IMPORT DWORD;
IMPORT SocketServer, Socket, Threads;

VAR gPass, gFail, gPort: CARDINAL; gRoundTrip: BOOLEAN;

PROCEDURE EchoHandler (c: SocketServer.Conn);
  VAR buf: ARRAY [0..1023] OF BYTE; n: CARDINAL;
BEGIN
  LOOP
    IF NOT SocketServer.Recv(c, ADR(buf), 1024, n) THEN RETURN END;
    IF n = 0 THEN RETURN END;
    IF NOT SocketServer.Send(c, ADR(buf), n) THEN RETURN END
  END
END EchoHandler;

PROCEDURE Client (param: ADDRESS): CARDINAL;
  VAR s: Socket.Socket; sb, rb: ARRAY [0..63] OF BYTE; got, i: CARDINAL; ok, eq: BOOLEAN;
BEGIN
  sb[0] := VAL(BYTE, 80); sb[1] := VAL(BYTE, 73); sb[2] := VAL(BYTE, 78); sb[3] := VAL(BYTE, 71);   (* "PING" *)
  ok := FALSE; i := 0;
  WHILE (NOT ok) AND (i < 100) DO
    ok := Socket.Connect("127.0.0.1", gPort, s);
    IF NOT ok THEN Sleep(VAL(DWORD, 20)) END; INC(i)
  END;
  IF ok THEN
    IF Socket.SendAll(s, ADR(sb), 4) AND Socket.Recv(s, ADR(rb), 64, got) THEN
      eq := got = 4;
      i := 0; WHILE (i < 4) AND eq DO IF rb[i] # sb[i] THEN eq := FALSE END; INC(i) END;
      gRoundTrip := eq
    END;
    (* hold the connection idle: the server fiber is now suspended in Recv *)
    Sleep(VAL(DWORD, 300));
    SocketServer.Stop;            (* drain must close + unwind this idle connection *)
    Sleep(VAL(DWORD, 100));
    Socket.Close(s)
  END;
  RETURN 0
END Client;

VAR th: Threads.Thread; ok: BOOLEAN;

BEGIN
  gPass := 0; gFail := 0; gPort := 54342; gRoundTrip := FALSE;
  WriteString("=== graceful drain with an active connection ==="); WriteLn;
  ok := Socket.Startup();
  th := Threads.Spawn(Client, NIL);
  ok := SocketServer.Run(gPort, EchoHandler);   (* must RETURN after the drain (no hang) *)
  ok := Threads.Join(th, 5000); Threads.CloseThread(th);
  Socket.Shutdown;

  IF gRoundTrip THEN WriteString("round-trip            [PASS]"); INC(gPass)
  ELSE WriteString("round-trip            [FAIL]"); INC(gFail) END; WriteLn;
  WriteString("server drained + returned   [PASS] (we got here, so Run() returned)"); INC(gPass); WriteLn;
  WriteLn;
  WriteString("PASS="); WriteCard(gPass, 1); WriteString("  FAIL="); WriteCard(gFail, 1); WriteLn
END DrainServerDemo.
