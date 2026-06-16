IMPLEMENTATION MODULE SocketServer;

(* Single dispatcher fiber + one fiber per connection, all on one thread, driven
   by an IOCP. A connection's pointer is its IOCP completion key, so a completion
   maps straight back to its fiber. Recv/Send issue an overlapped WSARecv/WSASend
   (which, success or pending, posts a completion to the IOCP) and SwitchToFiber
   to the dispatcher; the dispatcher resumes that fiber when the completion pops.
   A separate acceptor thread does blocking accepts and hands new sockets to the
   dispatcher via PostQueuedCompletionStatus(key=KEY_ACCEPT). *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM WIN32 IMPORT HANDLE, DWORD, BOOL;
FROM Networking_WinSock IMPORT closesocket, WSARecv, WSASend, WSAGetLastError;
FROM System_IO IMPORT CreateIoCompletionPort, GetQueuedCompletionStatus, PostQueuedCompletionStatus;
FROM System_Threading IMPORT ConvertThreadToFiber, CreateFiber, SwitchToFiber, DeleteFiber;
FROM Foundation IMPORT CloseHandle;
IMPORT Socket;
IMPORT Threads;

CONST
  KEY_STOP       = 1;
  KEY_ACCEPT     = 2;
  INVALID_HANDLE = 0FFFFFFFFFFFFFFFFH;
  WSA_IO_PENDING = 997;
  INFINITE       = 0FFFFFFFFH;

TYPE
  FiberProc = PROCEDURE (ADDRESS);
  POv = POINTER TO ARRAY [0..31] OF BYTE;
  WsaBuf = RECORD len: DWORD; buf: ADDRESS END;
  Conn = POINTER TO CRec;
  CRec = RECORD
    sock:      ADDRESS;
    fiber:     ADDRESS;
    ov:        ARRAY [0..31] OF BYTE;    (* OVERLAPPED, zeroed before each op *)
    wb:        WsaBuf;
    bytesXfer: CARDINAL;                 (* bytes from the last completion *)
    ioOk:      BOOLEAN;                  (* last completion succeeded *)
    done:      BOOLEAN;                  (* handler has returned *)
    id:        CARDINAL;
    next, prev: Conn;                    (* intrusive live-connection list (for shutdown drain) *)
  END;

VAR
  gIocp:       ADDRESS;
  gListener:   Socket.Socket;
  gDispatcher: ADDRESS;
  gHandler:    Handler;
  gRunning:    BOOLEAN;
  gAcceptor:   Threads.Thread;
  gNextId:     CARDINAL;
  gHead:       Conn;                      (* head of the live-connection list *)
  gLive:       CARDINAL;                  (* number of live connections *)

PROCEDURE Off (a: ADDRESS; n: CARDINAL): ADDRESS;
BEGIN RETURN CAST(ADDRESS, CAST(CARDINAL, a) + n) END Off;

PROCEDURE AC (x: CARDINAL): ADRCARD;     (* a CARDINAL as a completion key *)
BEGIN RETURN CAST(ADRCARD, x) END AC;

PROCEDURE ZeroOv (c: Conn);
  VAR p: POv; i: CARDINAL;
BEGIN
  p := CAST(POv, ADR(c^.ov));
  FOR i := 0 TO 31 DO p^[i] := VAL(BYTE, 0) END
END ZeroOv;

PROCEDURE Id (c: Conn): CARDINAL; BEGIN RETURN c^.id END Id;

(* issue an overlapped op, yield, and report the completion. r is the WSARecv/
   WSASend return; ANY queued completion (success or WSA_IO_PENDING) means we
   wait, an immediate hard error means we don't. *)
PROCEDURE Await (c: Conn; r: INTEGER32; VAR xfer: CARDINAL): BOOLEAN;
BEGIN
  IF (r = 0) OR (VAL(CARDINAL, WSAGetLastError()) = WSA_IO_PENDING) THEN
    SwitchToFiber(gDispatcher);          (* dispatcher resumes us on completion *)
    IF NOT c^.ioOk THEN RETURN FALSE END;
    xfer := c^.bytesXfer; RETURN TRUE
  END;
  RETURN FALSE
END Await;

PROCEDURE Recv (c: Conn; buf: ADDRESS; len: CARDINAL; VAR got: CARDINAL): BOOLEAN;
  VAR r: INTEGER32; bytes, flags: DWORD;
BEGIN
  got := 0; ZeroOv(c);
  c^.wb.len := VAL(DWORD, len); c^.wb.buf := buf;
  flags := VAL(DWORD, 0); bytes := VAL(DWORD, 0);
  r := WSARecv(c^.sock, ADR(c^.wb), VAL(DWORD, 1), ADR(bytes), ADR(flags), ADR(c^.ov), NIL);
  RETURN Await(c, r, got)               (* got=0 on return = peer closed cleanly *)
END Recv;

PROCEDURE Send (c: Conn; buf: ADDRESS; len: CARDINAL): BOOLEAN;
  VAR r: INTEGER32; bytes: DWORD; off, xfer: CARDINAL;
BEGIN
  off := 0;
  WHILE off < len DO
    ZeroOv(c);
    c^.wb.len := VAL(DWORD, len - off); c^.wb.buf := Off(buf, off);
    bytes := VAL(DWORD, 0);
    r := WSASend(c^.sock, ADR(c^.wb), VAL(DWORD, 1), ADR(bytes), VAL(DWORD, 0), ADR(c^.ov), NIL);
    IF NOT Await(c, r, xfer) THEN RETURN FALSE END;
    IF xfer = 0 THEN RETURN FALSE END;
    INC(off, xfer)
  END;
  RETURN TRUE
END Send;

(* TCP is a stream: Recv returns whatever has arrived (maybe a partial read).
   RecvAll loops until exactly `len` bytes are in — for fixed-size / length-
   prefixed framing. FALSE if the peer closes before `len` bytes (or on error). *)
PROCEDURE RecvAll (c: Conn; buf: ADDRESS; len: CARDINAL): BOOLEAN;
  VAR off, got: CARDINAL;
BEGIN
  off := 0;
  WHILE off < len DO
    IF NOT Recv(c, Off(buf, off), len - off, got) THEN RETURN FALSE END;
    IF got = 0 THEN RETURN FALSE END;    (* peer closed before len bytes *)
    INC(off, got)
  END;
  RETURN TRUE
END RecvAll;

(* a connection fiber: run the handler, then close + hand back to the dispatcher *)
PROCEDURE FiberEntry (param: ADDRESS);
  VAR c: Conn; r: INTEGER32;
BEGIN
  c := CAST(Conn, param);
  gHandler(c);
  r := closesocket(c^.sock);
  c^.done := TRUE;
  SwitchToFiber(gDispatcher)             (* suspends here forever; dispatcher deletes us *)
END FiberEntry;

PROCEDURE NewConn (sock: ADDRESS): Conn;
  VAR c: Conn; a: ADDRESS;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(CRec));
  IF a = NIL THEN RETURN NIL END;        (* out of memory: caller drops the socket *)
  c := CAST(Conn, a);
  c^.sock := sock; c^.fiber := NIL; c^.bytesXfer := 0;
  c^.ioOk := FALSE; c^.done := FALSE;
  INC(gNextId); c^.id := gNextId;
  c^.prev := NIL; c^.next := gHead;       (* link into the live list *)
  IF gHead # NIL THEN gHead^.prev := c END;
  gHead := c; INC(gLive);
  RETURN c
END NewConn;

PROCEDURE Cleanup (c: Conn);
  VAR a: ADDRESS;
BEGIN
  IF c^.prev # NIL THEN c^.prev^.next := c^.next ELSE gHead := c^.next END;   (* unlink *)
  IF c^.next # NIL THEN c^.next^.prev := c^.prev END;
  DEC(gLive);
  IF c^.fiber # NIL THEN DeleteFiber(c^.fiber) END;
  a := CAST(ADDRESS, c); DEALLOCATE(a, SIZE(CRec))
END Cleanup;

(* acceptor thread: blocking accept loop, feeding the dispatcher via the IOCP *)
PROCEDURE Acceptor (param: ADDRESS): CARDINAL;
  VAR cli: Socket.Socket; r: BOOL;
BEGIN
  WHILE gRunning DO
    IF Socket.Accept(gListener, cli) THEN
      r := PostQueuedCompletionStatus(gIocp, VAL(DWORD, 0), AC(KEY_ACCEPT), CAST(ADDRESS, cli))
    ELSE
      gRunning := FALSE                  (* listener closed -> stop accepting *)
    END
  END;
  RETURN 0
END Acceptor;

(* resume a connection fiber with a completion result; clean up if it finished *)
PROCEDURE Resume (c: Conn; bytes: DWORD; ok: BOOL);
BEGIN
  c^.bytesXfer := VAL(CARDINAL, bytes); c^.ioOk := ok # 0;
  SwitchToFiber(c^.fiber);
  IF c^.done THEN Cleanup(c) END
END Resume;

PROCEDURE Run (port: CARDINAL; handler: Handler): BOOLEAN;
  VAR fp: FiberProc; bytes: DWORD; key: ADRCARD; ovp: ADDRESS; ok, cb: BOOL;
      c: Conn; r: ADDRESS; r2: INTEGER32; jok: BOOLEAN;
BEGIN
  IF NOT Socket.Startup() THEN RETURN FALSE END;
  gHandler := handler; gRunning := TRUE; gNextId := 0; gHead := NIL; gLive := 0;
  gIocp := CreateIoCompletionPort(CAST(HANDLE, INVALID_HANDLE), CAST(HANDLE, NIL), AC(0), VAL(DWORD, 0));
  IF gIocp = NIL THEN RETURN FALSE END;
  IF NOT Socket.Listen(port, 64, gListener) THEN RETURN FALSE END;
  gDispatcher := ConvertThreadToFiber(NIL);
  gAcceptor := Threads.Spawn(Acceptor, NIL);

  LOOP
    ok := GetQueuedCompletionStatus(gIocp, ADR(bytes), ADR(key), ADR(ovp), VAL(DWORD, INFINITE));
    IF CAST(CARDINAL, key) = KEY_STOP THEN
      (* graceful drain: close every live socket so its pending op completes with
         an error, then dispatch the completions so each fiber unwinds + self-cleans *)
      c := gHead; WHILE c # NIL DO r2 := closesocket(c^.sock); c := c^.next END;
      WHILE gLive > 0 DO
        ok := GetQueuedCompletionStatus(gIocp, ADR(bytes), ADR(key), ADR(ovp), VAL(DWORD, INFINITE));
        IF CAST(CARDINAL, key) = KEY_ACCEPT THEN r2 := closesocket(ovp)     (* arrived mid-shutdown: drop *)
        ELSIF CAST(CARDINAL, key) # KEY_STOP THEN Resume(CAST(Conn, key), bytes, ok) END
      END;
      EXIT
    ELSIF CAST(CARDINAL, key) = KEY_ACCEPT THEN
      c := NewConn(ovp);                 (* the socket we posted *)
      IF c = NIL THEN
        r2 := closesocket(ovp)           (* out of memory: drop the accepted socket *)
      ELSE
        r := CreateIoCompletionPort(c^.sock, gIocp, CAST(ADRCARD, c), VAL(DWORD, 0));
        IF r = NIL THEN
          r2 := closesocket(c^.sock); Cleanup(c)         (* couldn't associate with the IOCP *)
        ELSE
          fp := FiberEntry;
          c^.fiber := CreateFiber(AC(0), CAST(ADDRESS, fp), CAST(ADDRESS, c));
          IF c^.fiber = NIL THEN
            r2 := closesocket(c^.sock); Cleanup(c)       (* fiber creation failed *)
          ELSE
            SwitchToFiber(c^.fiber);
            IF c^.done THEN Cleanup(c) END
          END
        END
      END
    ELSE
      Resume(CAST(Conn, key), bytes, ok)
    END
  END;

  Socket.Close(gListener);               (* unblock the acceptor *)
  jok := Threads.Join(gAcceptor, 2000);
  Threads.CloseThread(gAcceptor);
  cb := CloseHandle(gIocp); gIocp := NIL;
  RETURN TRUE
END Run;

PROCEDURE Stop;
  VAR r: BOOL;
BEGIN
  gRunning := FALSE;
  Socket.Close(gListener);               (* make the acceptor's blocking accept fail *)
  r := PostQueuedCompletionStatus(gIocp, VAL(DWORD, 0), AC(KEY_STOP), NIL)
END Stop;

BEGIN
  gRunning := FALSE; gIocp := NIL; gNextId := 0
END SocketServer.
