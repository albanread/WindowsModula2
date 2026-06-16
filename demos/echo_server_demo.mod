MODULE EchoServerDemo;
(*
 * An asynchronous TCP echo server on IOCP + fibers (SocketServer). A client
 * thread does a few connect/send/recv round-trips while the main thread runs the
 * server's completion loop, then signals it to stop.
 *   build: newm2 build demos/echo_server_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM System_Threading IMPORT Sleep;
FROM WIN32 IMPORT DWORD;
IMPORT SocketServer, Socket, Threads;

VAR gPass, gFail, gPort: CARDINAL;

(* the server handler: echo everything until the peer closes. Runs in a fiber;
   Recv/Send are async under the hood but read like blocking calls. *)
PROCEDURE EchoHandler (c: SocketServer.Conn);
  VAR buf: ARRAY [0..4095] OF BYTE; n: CARDINAL;
BEGIN
  LOOP
    IF NOT SocketServer.Recv(c, ADR(buf), 4096, n) THEN RETURN END;
    IF n = 0 THEN RETURN END;                       (* peer closed *)
    IF NOT SocketServer.Send(c, ADR(buf), n) THEN RETURN END
  END
END EchoHandler;

(* one client round-trip: connect, send msg, recv the echo, verify, close *)
PROCEDURE RoundTrip (msg: ARRAY OF CHAR): BOOLEAN;
  VAR s: Socket.Socket; sb, rb: ARRAY [0..255] OF BYTE; len, got, i: CARDINAL; ok, eq: BOOLEAN;
BEGIN
  len := 0;
  WHILE (len <= HIGH(msg)) AND (msg[len] # 0C) DO sb[len] := VAL(BYTE, ORD(msg[len]) BAND 0FFH); INC(len) END;
  ok := FALSE; i := 0;
  WHILE (NOT ok) AND (i < 100) DO                    (* retry until the server is listening *)
    ok := Socket.Connect("127.0.0.1", gPort, s);
    IF NOT ok THEN Sleep(VAL(DWORD, 20)) END; INC(i)
  END;
  IF NOT ok THEN RETURN FALSE END;
  IF NOT Socket.SendAll(s, ADR(sb), len) THEN Socket.Close(s); RETURN FALSE END;
  IF NOT Socket.Recv(s, ADR(rb), 256, got) THEN Socket.Close(s); RETURN FALSE END;
  Socket.Close(s);
  IF got # len THEN RETURN FALSE END;
  eq := TRUE; i := 0;
  WHILE (i < len) AND eq DO IF rb[i] # sb[i] THEN eq := FALSE END; INC(i) END;
  RETURN eq
END RoundTrip;

PROCEDURE Tally (label: ARRAY OF CHAR; ok: BOOLEAN);
BEGIN
  WriteString(label); IF ok THEN WriteString("   [PASS]"); INC(gPass) ELSE WriteString("   [FAIL]"); INC(gFail) END; WriteLn
END Tally;

(* the client runs on its own thread (the main thread runs the server loop) *)
PROCEDURE Client (param: ADDRESS): CARDINAL;
BEGIN
  Tally("echo HELLO          ", RoundTrip("HELLO"));
  Tally("echo ASYNC ON WINDOWS", RoundTrip("ASYNC ON WINDOWS"));
  Tally("echo IOCP + FIBERS   ", RoundTrip("IOCP + FIBERS"));
  SocketServer.Stop;                                 (* make Run return *)
  RETURN 0
END Client;

VAR th: Threads.Thread; ok: BOOLEAN;

BEGIN
  gPass := 0; gFail := 0; gPort := 54340;
  WriteString("=== async TCP echo server: IOCP + fibers ==="); WriteLn;
  ok := Socket.Startup();
  th := Threads.Spawn(Client, NIL);
  ok := SocketServer.Run(gPort, EchoHandler);        (* blocks until Client calls Stop *)
  Tally("server ran          ", ok);
  ok := Threads.Join(th, 5000); Threads.CloseThread(th);
  Socket.Shutdown;
  WriteLn;
  WriteString("PASS="); WriteCard(gPass, 1); WriteString("  FAIL="); WriteCard(gFail, 1); WriteLn
END EchoServerDemo.
