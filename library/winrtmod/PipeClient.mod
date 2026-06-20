IMPLEMENTATION MODULE PipeClient;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST, BYTE, ADRCARD;
FROM Storage_FileSystem IMPORT CreateFileW, ReadFile, WriteFile;
FROM Foundation IMPORT CloseHandle;
FROM WIN32 IMPORT DWORD, BOOL, HANDLE, PWSTR;

(* Unsigned value of a byte. SYSTEM.BYTE is SIGNED here, so VAL(CARDINAL, b)
   sign-extends bytes >= 128 (0xB9 -> a huge number) — mask back to 0..255. *)
PROCEDURE UB (b: BYTE): CARDINAL; BEGIN RETURN VAL(CARDINAL, b) MOD 256 END UB;

CONST
  GENERIC_READ  = 80000000H;
  GENERIC_WRITE = 40000000H;
  OPEN_EXISTING = 3;
  MaxFrame      = 16777216;        (* 16 MB reply cap *)
  BS            = 134C;            (* backslash (octal 134 = 92) *)

PROCEDURE IsInvalid (h: ADDRESS): BOOLEAN;
BEGIN RETURN CAST(CARDINAL, h) = MAX(CARDINAL) END IsInvalid;   (* INVALID_HANDLE_VALUE = -1 *)

PROCEDURE Connect (bareName: ARRAY OF CHAR): ADDRESS;
  VAR full: ARRAY [0..271] OF CHAR; i, j: CARDINAL; h: HANDLE;
BEGIN
  full[0] := BS; full[1] := BS; full[2] := '.'; full[3] := BS;   (* \\.\pipe\ *)
  full[4] := 'p'; full[5] := 'i'; full[6] := 'p'; full[7] := 'e'; full[8] := BS;
  i := 9; j := 0;
  WHILE (j <= HIGH(bareName)) AND (bareName[j] # 0C) AND (i < 270) DO
    full[i] := bareName[j]; INC(i); INC(j)
  END;
  full[i] := 0C;
  h := CreateFileW(CAST(PWSTR, ADR(full)), GENERIC_READ + GENERIC_WRITE, 0,
                   NIL, OPEN_EXISTING, 0, NIL);
  IF IsInvalid(h) THEN RETURN NIL END;
  RETURN h
END Connect;

(* read exactly n bytes into buf; FALSE on short read / error *)
PROCEDURE ReadAll (h: ADDRESS; buf: ADDRESS; n: CARDINAL): BOOLEAN;
  VAR got, red: DWORD; ok: BOOL;
BEGIN
  got := 0;
  WHILE VAL(CARDINAL, got) < n DO
    red := 0;
    ok := ReadFile(CAST(HANDLE, h),
                   CAST(ADDRESS, CAST(ADRCARD, buf) + VAL(ADRCARD, got)),
                   VAL(DWORD, n - VAL(CARDINAL, got)), ADR(red), NIL);
    IF (ok = 0) OR (red = 0) THEN RETURN FALSE END;
    got := got + red
  END;
  RETURN TRUE
END ReadAll;

PROCEDURE WriteAll (h: ADDRESS; buf: ADDRESS; n: CARDINAL): BOOLEAN;
  VAR sent, wrote: DWORD; ok: BOOL;
BEGIN
  sent := 0;
  WHILE VAL(CARDINAL, sent) < n DO
    wrote := 0;
    ok := WriteFile(CAST(HANDLE, h),
                    CAST(ADDRESS, CAST(ADRCARD, buf) + VAL(ADRCARD, sent)),
                    VAL(DWORD, n - VAL(CARDINAL, sent)), ADR(wrote), NIL);
    IF (ok = 0) OR (wrote = 0) THEN RETURN FALSE END;
    sent := sent + wrote
  END;
  RETURN TRUE
END WriteAll;

PROCEDURE Request (h: ADDRESS; cmd: ARRAY OF CHAR; VAR reply: ARRAY OF CHAR): BOOLEAN;
  VAR n, i, rlen, got, k, chunk: CARDINAL;
      lenbuf: ARRAY [0..3] OF BYTE;
      payload: ARRAY [0..2047] OF BYTE;
      scratch: ARRAY [0..4095] OF BYTE;
BEGIN
  IF h = NIL THEN RETURN FALSE END;
  n := 0; WHILE (n <= HIGH(cmd)) AND (cmd[n] # 0C) DO INC(n) END;
  IF n > 2048 THEN RETURN FALSE END;                 (* command longer than the buffer *)
  lenbuf[0] := VAL(BYTE, n MOD 256);
  lenbuf[1] := VAL(BYTE, (n DIV 256) MOD 256);
  lenbuf[2] := VAL(BYTE, (n DIV 65536) MOD 256);
  lenbuf[3] := VAL(BYTE, (n DIV 16777216) MOD 256);
  IF NOT WriteAll(h, ADR(lenbuf), 4) THEN RETURN FALSE END;
  i := 0; WHILE i < n DO payload[i] := VAL(BYTE, ORD(cmd[i]) MOD 256); INC(i) END;
  IF NOT WriteAll(h, ADR(payload), n) THEN RETURN FALSE END;

  IF NOT ReadAll(h, ADR(lenbuf), 4) THEN RETURN FALSE END;
  rlen := UB(lenbuf[0]) + UB(lenbuf[1]) * 256 + UB(lenbuf[2]) * 65536 + UB(lenbuf[3]) * 16777216;
  IF rlen > MaxFrame THEN RETURN FALSE END;
  got := 0; k := 0;
  WHILE got < rlen DO
    chunk := rlen - got; IF chunk > 4096 THEN chunk := 4096 END;
    IF NOT ReadAll(h, ADR(scratch), chunk) THEN RETURN FALSE END;
    i := 0;
    WHILE i < chunk DO
      IF k < HIGH(reply) THEN reply[k] := CHR(UB(scratch[i])); INC(k) END;
      INC(i)
    END;
    got := got + chunk
  END;
  reply[k] := 0C;
  RETURN TRUE
END Request;

PROCEDURE Ask (bareName, cmd: ARRAY OF CHAR; VAR reply: ARRAY OF CHAR): BOOLEAN;
  VAR h: ADDRESS; ok: BOOLEAN;
BEGIN
  h := Connect(bareName);
  IF h = NIL THEN reply[0] := 0C; RETURN FALSE END;
  ok := Request(h, cmd, reply);
  Close(h);
  RETURN ok
END Ask;

PROCEDURE Close (h: ADDRESS);
  VAR ok: BOOL;
BEGIN
  IF h # NIL THEN ok := CloseHandle(CAST(HANDLE, h)) END
END Close;

END PipeClient.
