IMPLEMENTATION MODULE Socket;

(* Thin wrapper over the ws2_32 externs (generated in Networking_WinSock). The
   generated parameter NAMES are mangled but the POSITIONS/types are correct, so
   the externs are called positionally: e.g. connect(name,namelen,arg2) is really
   connect(socket, sockaddr*, len). A SOCKET is an ADDRESS; INVALID_SOCKET is all
   ones. sockaddr_in is built by hand (family, port and addr in network order). *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM WIN32 IMPORT WORD, DWORD, PSTR;
FROM Networking_WinSock IMPORT
  WSAStartup, WSACleanup, WSAGetLastError,
  socket, bind, connect, listen, accept, send, recv, closesocket,
  htons, inet_addr, getaddrinfo, freeaddrinfo;

CONST
  AF_INET      = 2;
  SOCK_STREAM  = 1;
  INADDR_NONE  = 0FFFFFFFFH;
  INVALID_SOCK = 0FFFFFFFFFFFFFFFFH;
  WSAVER       = 0202H;                 (* MAKEWORD(2,2) *)

TYPE
  SockAddr = RECORD
    family: WORD;                       (* offset 0 *)
    port:   WORD;                       (* offset 2, network order *)
    addr:   DWORD;                      (* offset 4, network order *)
    zero:   ARRAY [0..7] OF BYTE;       (* offset 8 *)
  END;
  PAddr  = POINTER TO ADDRESS;
  PDword = POINTER TO DWORD;

(* opaque, oversized: WSAStartup writes the full ~408-byte x64 WSADATA, but the
   generated WSADATA record collapses its inline char arrays to pointers (~40
   bytes). We never read it, so a 512-byte buffer is correct and safe. *)
VAR gWsa: ARRAY [0..511] OF BYTE; gStarted: BOOLEAN;

PROCEDURE Off (a: ADDRESS; n: CARDINAL): ADDRESS;
BEGIN RETURN CAST(ADDRESS, CAST(CARDINAL, a) + n) END Off;

PROCEDURE Bad (s: ADDRESS): BOOLEAN;
BEGIN RETURN CAST(CARDINAL, s) = INVALID_SOCK END Bad;

PROCEDURE Startup (): BOOLEAN;
  VAR r: INTEGER32;
BEGIN
  IF gStarted THEN RETURN TRUE END;
  r := WSAStartup(VAL(WORD, WSAVER), ADR(gWsa));
  IF r = 0 THEN gStarted := TRUE; RETURN TRUE END;
  RETURN FALSE
END Startup;

PROCEDURE Shutdown;
  VAR r: INTEGER32;
BEGIN
  IF gStarted THEN r := WSACleanup(); gStarted := FALSE END
END Shutdown;

PROCEDURE LastError (): CARDINAL;
BEGIN RETURN VAL(CARDINAL, WSAGetLastError()) END LastError;

(* UTF-16 host -> NUL-terminated ANSI bytes (ASCII hosts/IPs) *)
PROCEDURE ToAnsi (host: ARRAY OF CHAR; VAR a: ARRAY OF BYTE);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(host)) AND (host[i] # 0C) AND (i < HIGH(a)) DO
    a[i] := VAL(BYTE, ORD(host[i]) BAND 0FFH); INC(i)
  END;
  a[i] := VAL(BYTE, 0)
END ToAnsi;

(* resolve a host string to a network-order IPv4 address: IP literal first, then DNS *)
PROCEDURE Resolve (host: ARRAY OF CHAR; VAR netAddr: DWORD): BOOLEAN;
  VAR ansi: ARRAY [0..255] OF BYTE; res, ai: ADDRESS; r: INTEGER32;
      pa: PAddr; pd: PDword;
BEGIN
  ToAnsi(host, ansi);
  netAddr := inet_addr(CAST(PSTR, ADR(ansi)));
  IF VAL(CARDINAL, netAddr) # INADDR_NONE THEN RETURN TRUE END;
  res := NIL;
  r := getaddrinfo(CAST(PSTR, ADR(ansi)), NIL, NIL, ADR(res));
  IF (r # 0) OR (res = NIL) THEN RETURN FALSE END;
  pa := CAST(PAddr, Off(res, 32)); ai := pa^;        (* ADDRINFOA.ai_addr -> sockaddr *)
  pd := CAST(PDword, Off(ai, 4)); netAddr := pd^;     (* sockaddr_in.sin_addr *)
  freeaddrinfo(res);
  RETURN TRUE
END Resolve;

PROCEDURE NewTcp (): ADDRESS;
BEGIN RETURN socket(VAL(INTEGER32, AF_INET), VAL(INTEGER32, SOCK_STREAM), VAL(INTEGER32, 0)) END NewTcp;

PROCEDURE FillAddr (VAR sa: SockAddr; netAddr: DWORD; port: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  sa.family := VAL(WORD, AF_INET);
  sa.port := htons(VAL(WORD, port));
  sa.addr := netAddr;
  FOR i := 0 TO 7 DO sa.zero[i] := VAL(BYTE, 0) END
END FillAddr;

PROCEDURE Connect (host: ARRAY OF CHAR; port: CARDINAL; VAR s: Socket): BOOLEAN;
  VAR sa: SockAddr; sk: ADDRESS; a: DWORD; r: INTEGER32;
BEGIN
  s := CAST(ADDRESS, INVALID_SOCK);
  IF NOT Resolve(host, a) THEN RETURN FALSE END;
  sk := NewTcp(); IF Bad(sk) THEN RETURN FALSE END;
  FillAddr(sa, a, port);
  r := connect(sk, ADR(sa), VAL(INTEGER32, SIZE(SockAddr)));
  IF r # 0 THEN r := closesocket(sk); RETURN FALSE END;
  s := sk; RETURN TRUE
END Connect;

PROCEDURE Listen (port, backlog: CARDINAL; VAR s: Socket): BOOLEAN;
  VAR sa: SockAddr; sk: ADDRESS; r: INTEGER32;
BEGIN
  s := CAST(ADDRESS, INVALID_SOCK);
  sk := NewTcp(); IF Bad(sk) THEN RETURN FALSE END;
  FillAddr(sa, VAL(DWORD, 0), port);          (* INADDR_ANY *)
  r := bind(sk, ADR(sa), VAL(INTEGER32, SIZE(SockAddr)));
  IF r # 0 THEN r := closesocket(sk); RETURN FALSE END;
  r := listen(sk, VAL(INTEGER32, backlog));
  IF r # 0 THEN r := closesocket(sk); RETURN FALSE END;
  s := sk; RETURN TRUE
END Listen;

PROCEDURE Accept (server: Socket; VAR client: Socket): BOOLEAN;
  VAR c: ADDRESS;
BEGIN
  client := CAST(ADDRESS, INVALID_SOCK);
  c := accept(server, NIL, NIL);
  IF Bad(c) THEN RETURN FALSE END;
  client := c; RETURN TRUE
END Accept;

PROCEDURE Send (s: Socket; data: ADDRESS; len: CARDINAL; VAR sent: CARDINAL): BOOLEAN;
  VAR r: INTEGER32;
BEGIN
  sent := 0;
  r := send(s, CAST(PSTR, data), VAL(INTEGER32, len), VAL(INTEGER32, 0));
  IF r < 0 THEN RETURN FALSE END;
  sent := VAL(CARDINAL, r); RETURN TRUE
END Send;

PROCEDURE SendAll (s: Socket; data: ADDRESS; len: CARDINAL): BOOLEAN;
  VAR off, sent: CARDINAL;
BEGIN
  off := 0;
  WHILE off < len DO
    IF NOT Send(s, Off(data, off), len - off, sent) THEN RETURN FALSE END;
    IF sent = 0 THEN RETURN FALSE END;
    INC(off, sent)
  END;
  RETURN TRUE
END SendAll;

PROCEDURE Recv (s: Socket; buf: ADDRESS; len: CARDINAL; VAR got: CARDINAL): BOOLEAN;
  VAR r: INTEGER32;
BEGIN
  got := 0;
  r := recv(s, CAST(PSTR, buf), VAL(INTEGER32, len), VAL(INTEGER32, 0));
  IF r < 0 THEN RETURN FALSE END;
  got := VAL(CARDINAL, r); RETURN TRUE
END Recv;

PROCEDURE Close (VAR s: Socket);
  VAR r: INTEGER32;
BEGIN
  IF NOT Bad(s) THEN r := closesocket(s); s := CAST(ADDRESS, INVALID_SOCK) END
END Close;

BEGIN
  gStarted := FALSE
END Socket.
