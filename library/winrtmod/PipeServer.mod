IMPLEMENTATION MODULE PipeServer;

(* Non-blocking via PIPE_NOWAIT: ConnectNamedPipe / ReadFile / WriteFile all return
   immediately. PeekNamedPipe reports bytes available (and a broken pipe) without
   consuming, so a frame is only read once it has fully arrived. A small state
   machine (listening -> reading length -> reading payload -> awaiting reply) is
   advanced one Poll at a time off the host's message loop — never blocking the UI. *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST, BYTE, DWORD, ADRCARD;
FROM Storage_FileSystem IMPORT ReadFile, WriteFile, FlushFileBuffers;
FROM System_Pipes IMPORT CreateNamedPipeW, ConnectNamedPipe, DisconnectNamedPipe, PeekNamedPipe;
FROM Foundation IMPORT CloseHandle, GetLastError;
FROM System_SystemInformation IMPORT GetTickCount;
FROM WIN32 IMPORT BOOL, HANDLE, PWSTR;

CONST
  PIPE_ACCESS_DUPLEX       = 3;
  PIPE_TYPE_BYTE           = 0;
  PIPE_READMODE_BYTE       = 0;
  PIPE_NOWAIT              = 1;
  PIPE_UNLIMITED_INSTANCES = 255;
  ERROR_PIPE_CONNECTED     = 535;
  ERROR_PIPE_LISTENING     = 536;
  BufMax = 65535;
  BS     = 134C;                       (* backslash *)
  INVALID = 0FFFFFFFFFFFFFFFFH;        (* INVALID_HANDLE_VALUE (-1) *)
  FrameTimeout = 5000;                 (* ms: drop a client that stalls mid-frame (no-DoS) *)

  StStopped = 0; StListen = 1; StReadLen = 2; StReadPay = 3; StReply = 4;

VAR
  gPipe:   HANDLE;
  gState:  CARDINAL;
  gPayLen: CARDINAL;
  gStart:  CARDINAL;                    (* GetTickCount when the current frame's read last progressed *)
  gPay:    ARRAY [0..BufMax] OF BYTE;   (* raw request/reply payload bytes *)

(* Unsigned value of a byte. SYSTEM.BYTE is SIGNED here, so VAL(CARDINAL, b)
   sign-extends bytes >= 128 — mask back to 0..255 (else a length byte >= 128 decodes huge). *)
PROCEDURE UB (b: BYTE): CARDINAL; BEGIN RETURN VAL(CARDINAL, b) MOD 256 END UB;

PROCEDURE WriteAll (buf: ADDRESS; n: CARDINAL): BOOLEAN;   (* WriteFile can short-write -> loop *)
  VAR sent, wrote: DWORD; ok: BOOL;
BEGIN
  sent := 0;
  WHILE VAL(CARDINAL, sent) < n DO
    wrote := 0;
    ok := WriteFile(gPipe, CAST(ADDRESS, CAST(ADRCARD, buf) + VAL(ADRCARD, sent)),
                    VAL(DWORD, n - VAL(CARDINAL, sent)), ADR(wrote), NIL);
    IF (ok = 0) OR (wrote = 0) THEN RETURN FALSE END;
    sent := sent + wrote
  END;
  RETURN TRUE
END WriteAll;

PROCEDURE Avail (VAR broken: BOOLEAN): CARDINAL;     (* bytes ready, without consuming; broken iff the client is gone *)
  VAR ok: BOOL; total: DWORD;
BEGIN
  total := 0; broken := FALSE;
  ok := PeekNamedPipe(gPipe, NIL, 0, NIL, ADR(total), NIL);
  IF ok = 0 THEN broken := TRUE; RETURN 0 END;
  RETURN VAL(CARDINAL, total)
END Avail;

PROCEDURE Relisten;                                  (* drop the current client, wait for the next *)
  VAR ok: BOOL;
BEGIN ok := DisconnectNamedPipe(gPipe); gState := StListen END Relisten;

PROCEDURE Start (bareName: ARRAY OF CHAR): BOOLEAN;
  VAR full: ARRAY [0..271] OF CHAR; i, j: CARDINAL; h: HANDLE;
BEGIN
  IF gState # StStopped THEN RETURN TRUE END;
  full[0] := BS; full[1] := BS; full[2] := '.'; full[3] := BS;       (* \\.\pipe\ *)
  full[4] := 'p'; full[5] := 'i'; full[6] := 'p'; full[7] := 'e'; full[8] := BS;
  i := 9; j := 0;
  WHILE (j <= HIGH(bareName)) AND (bareName[j] # 0C) AND (i < 270) DO full[i] := bareName[j]; INC(i); INC(j) END;
  full[i] := 0C;
  h := CreateNamedPipeW(CAST(PWSTR, ADR(full)),
                        PIPE_ACCESS_DUPLEX,
                        PIPE_TYPE_BYTE + PIPE_READMODE_BYTE + PIPE_NOWAIT,
                        PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, NIL);
  IF CAST(CARDINAL, h) = INVALID THEN RETURN FALSE END;
  gPipe := h; gState := StListen; RETURN TRUE
END Start;

PROCEDURE Poll (VAR cmd: ARRAY OF CHAR): BOOLEAN;
  VAR ok: BOOL; got: DWORD; av, i, k, le: CARDINAL; broken: BOOLEAN;
      lenbuf: ARRAY [0..3] OF BYTE;
BEGIN
  IF (gState = StStopped) OR (gState = StReply) THEN RETURN FALSE END;
  IF gState = StListen THEN
    ok := ConnectNamedPipe(gPipe, NIL); le := VAL(CARDINAL, GetLastError());
    IF (ok # 0) OR (le = ERROR_PIPE_CONNECTED) THEN
      gState := StReadLen; gStart := VAL(CARDINAL, GetTickCount())
    ELSIF le = ERROR_PIPE_LISTENING THEN RETURN FALSE        (* no client yet *)
    ELSE Relisten; RETURN FALSE END                          (* client connected+closed (ERROR_NO_DATA etc): reset *)
  END;
  IF VAL(CARDINAL, GetTickCount()) - gStart > FrameTimeout THEN Relisten; RETURN FALSE END;  (* drop a stalled client *)
  av := Avail(broken);
  IF broken THEN Relisten; RETURN FALSE END;
  IF gState = StReadLen THEN
    IF av < 4 THEN RETURN FALSE END;
    got := 0; ok := ReadFile(gPipe, ADR(lenbuf), 4, ADR(got), NIL);
    IF (ok = 0) OR (VAL(CARDINAL, got) # 4) THEN Relisten; RETURN FALSE END;
    gPayLen := UB(lenbuf[0]) + UB(lenbuf[1]) * 256 + UB(lenbuf[2]) * 65536 + UB(lenbuf[3]) * 16777216;
    IF gPayLen > BufMax THEN Relisten; RETURN FALSE END;     (* reject (don't clamp+desync) an over-length frame *)
    gState := StReadPay; gStart := VAL(CARDINAL, GetTickCount());   (* progress: refresh the deadline *)
    av := Avail(broken); IF broken THEN Relisten; RETURN FALSE END
  END;
  IF gState = StReadPay THEN
    IF av < gPayLen THEN RETURN FALSE END;
    IF gPayLen > 0 THEN
      got := 0; ok := ReadFile(gPipe, ADR(gPay), VAL(DWORD, gPayLen), ADR(got), NIL);
      IF (ok = 0) OR (VAL(CARDINAL, got) # gPayLen) THEN Relisten; RETURN FALSE END
    END;
    k := 0; i := 0;                                   (* widen UTF-8 low bytes -> CHAR *)
    WHILE (i < gPayLen) AND (k < HIGH(cmd)) DO cmd[k] := CHR(UB(gPay[i])); INC(k); INC(i) END;
    cmd[k] := 0C;
    gState := StReply;
    RETURN TRUE
  END;
  RETURN FALSE
END Poll;

PROCEDURE Reply (result: ARRAY OF CHAR);
  VAR n, i: CARDINAL; ok: BOOL; wok: BOOLEAN; lenbuf: ARRAY [0..3] OF BYTE;
BEGIN
  IF gState # StReply THEN RETURN END;
  n := 0; WHILE (n <= HIGH(result)) AND (result[n] # 0C) DO INC(n) END;
  IF n > BufMax THEN n := BufMax END;
  lenbuf[0] := VAL(BYTE, n MOD 256);          lenbuf[1] := VAL(BYTE, (n DIV 256) MOD 256);
  lenbuf[2] := VAL(BYTE, (n DIV 65536) MOD 256); lenbuf[3] := VAL(BYTE, (n DIV 16777216) MOD 256);
  i := 0; WHILE i < n DO gPay[i] := VAL(BYTE, ORD(result[i]) MOD 256); INC(i) END;
  wok := WriteAll(ADR(lenbuf), 4);
  IF wok THEN wok := WriteAll(ADR(gPay), n) END;
  ok := FlushFileBuffers(gPipe);   (* block until the client drains the reply — else Disconnect discards it *)
  Relisten
END Reply;

PROCEDURE Stop;
  VAR ok: BOOL;
BEGIN
  IF gState # StStopped THEN ok := CloseHandle(gPipe); gState := StStopped END
END Stop;

BEGIN
  gState := StStopped; gPayLen := 0; gStart := 0;
END PipeServer.
