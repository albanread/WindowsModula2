MODULE UdpDemo;
(*
 * UDP datagram round-trip: a client sends to a bound server socket, the server
 * echoes back to the reported peer address, the client reads the echo. Also
 * checks SetReuseAddr and the from-host/from-port RecvFrom returns.
 *   build: newm2 build demos/udp_demo.mod   then run the .exe
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteCard;
FROM SYSTEM IMPORT ADR;
IMPORT Socket;

VAR pass, fail: CARDINAL;

PROCEDURE CheckB (label: ARRAY OF CHAR; got, want: BOOLEAN);
BEGIN
  WriteString(label); WriteString(" = "); IF got THEN WriteString("TRUE") ELSE WriteString("FALSE") END;
  IF got = want THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL]"); INC(fail) END; WriteLn
END CheckB;

PROCEDURE Check (label: ARRAY OF CHAR; got, want: CARDINAL);
BEGIN
  WriteString(label); WriteString(" = "); WriteCard(got, 1);
  IF got = want THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL] want "); WriteCard(want, 1); INC(fail) END; WriteLn
END Check;

PROCEDURE StrEqV (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  LOOP
    IF (i > HIGH(a)) OR (a[i] = 0C) THEN RETURN (i > HIGH(b)) OR (b[i] = 0C) END;
    IF (i > HIGH(b)) OR (a[i] # b[i]) THEN RETURN FALSE END; INC(i)
  END
END StrEqV;

PROCEDURE CheckS (label: ARRAY OF CHAR; VAR got: ARRAY OF CHAR; want: ARRAY OF CHAR);
BEGIN
  WriteString(label); WriteString(" = '"); WriteString(got); WriteString("'");
  IF StrEqV(got, want) THEN WriteString("   [PASS]"); INC(pass) ELSE WriteString("   [FAIL] want '"); WriteString(want); WriteString("'"); INC(fail) END; WriteLn
END CheckS;

PROCEDURE BytesEq (VAR a, b: ARRAY OF BYTE; n: CARDINAL): BOOLEAN;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE i < n DO IF (ORD(a[i]) BAND 0FFH) # (ORD(b[i]) BAND 0FFH) THEN RETURN FALSE END; INC(i) END; RETURN TRUE END BytesEq;

VAR
  srv, cli: Socket.Socket;
  msg, rbuf, ebuf: ARRAY [0..255] OF BYTE;
  host: ARRAY [0..63] OF CHAR;
  sent, got, port, i: CARDINAL; ok: BOOLEAN;

BEGIN
  pass := 0; fail := 0;
  WriteString("=== UDP datagrams ==="); WriteLn;
  ok := Socket.Startup(); CheckB("startup       ", ok, TRUE);

  ok := Socket.UdpSocket(srv); CheckB("udp socket    ", ok, TRUE);
  ok := Socket.SetReuseAddr(srv, TRUE); CheckB("reuseaddr     ", ok, TRUE);
  ok := Socket.BindPort(srv, 54350); CheckB("bind 54350    ", ok, TRUE);
  ok := Socket.UdpSocket(cli); CheckB("udp client    ", ok, TRUE);

  msg[0] := VAL(BYTE, 80); msg[1] := VAL(BYTE, 73); msg[2] := VAL(BYTE, 78); msg[3] := VAL(BYTE, 71);  (* "PING" *)
  ok := Socket.SendTo(cli, "127.0.0.1", 54350, ADR(msg), 4, sent);
  CheckB("client sendto ", ok, TRUE); Check("  sent        ", sent, 4);

  (* server reads the datagram + the client's address *)
  ok := Socket.RecvFrom(srv, ADR(rbuf), 256, got, host, port);
  CheckB("server recv   ", ok, TRUE); Check("  got         ", got, 4);
  CheckS("  from host   ", host, "127.0.0.1");
  CheckB("  payload PING", BytesEq(rbuf, msg, 4), TRUE);

  (* server echoes back to that address *)
  ok := Socket.SendTo(srv, host, port, ADR(rbuf), got, sent);
  CheckB("server echo   ", ok, TRUE);

  (* client reads the echo *)
  ok := Socket.RecvFrom(cli, ADR(ebuf), 256, got, host, port);
  CheckB("client recv   ", ok, TRUE); Check("  echo got    ", got, 4);
  CheckB("  echo == PING", BytesEq(ebuf, msg, 4), TRUE);

  Socket.Close(srv); Socket.Close(cli); Socket.Shutdown;
  WriteLn;
  WriteString("PASS="); WriteCard(pass, 1); WriteString("  FAIL="); WriteCard(fail, 1); WriteLn
END UdpDemo.
