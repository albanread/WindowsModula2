(* Copyright (c) xTech 1993,94. All Rights Reserved. *)
(* Ported to NewM2 2026-05-15 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - Replaced XDS `X2C.X2C_argv` / `X2C_argc` (a C-style argv array
       indexed in M2 code through SYSTEM.CAST) with the NewM2 runtime
       shims `NM2ProgramArgs.Count` / `Copy`. The runtime owns the arg
       list as a Vec<String> and the driver populates it before
       invoking the entry body.
     - Argument 0 is the program (file) name by convention; user
       arguments start at index 1, which is where `ArgChan` initially
       points.
     - The XDS source iterated through `ptr^[pos]` and tracked
       `(arg, pos, len)` as module state. We keep the same model —
       just the source of `ptr^` is a runtime-filled local buffer
       instead of an embedded argv pointer. ARG_BUF holds at most
       1023 chars of the current argument; longer args are truncated.
*)
IMPLEMENTATION MODULE ProgramArgs;

IMPORT SYSTEM, IOChan, IOLink, IOConsts, ChanConsts, CharClass, NM2ProgramArgs;

CONST argBufHigh = 1023;

TYPE Object = IOLink.DeviceTablePtr;

VAR
  did:    IOLink.DeviceId;
  cid:    ChanId;
  arg:    CARDINAL;          (* index of the argument currently exposed *)
  pos:    CARDINAL;          (* byte offset within argBuf *)
  len:    CARDINAL;          (* number of bytes in argBuf *)
  argc:   CARDINAL;          (* total args; cached at init *)
  argBuf: ARRAY [0..argBufHigh] OF CHAR;
  inited: BOOLEAN;

(*----------------------------------------------------------------*)
(* Open mode device-table procs — used while there's still an arg
   to read. After the last arg they're swapped for the read-closed
   stubs further down. *)

PROCEDURE doLookOpen(x: Object; VAR ch: CHAR; VAR res: IOConsts.ReadResults);
BEGIN
  res := IOConsts.allRight;
  IF pos > len THEN
    IF arg + 1 >= argc THEN
      res := IOConsts.endOfInput;
    ELSE
      INC(arg);
      len := NM2ProgramArgs.Copy(arg, SYSTEM.ADR(argBuf), argBufHigh + 1);
      pos := 0;
      ch := argBuf[pos];
    END;
  ELSIF pos = len THEN
    ch := ' ';
  ELSE
    ch := argBuf[pos];
  END;
  x^.result := res;
END doLookOpen;

PROCEDURE doRead(x: Object; VAR ch: CHAR; VAR res: IOConsts.ReadResults);
BEGIN
  doLookOpen(x, ch, res);
  IF res = IOConsts.allRight THEN INC(pos) END;
END doRead;

PROCEDURE doSkipOpen(x: Object);
  VAR ch: CHAR; res: IOConsts.ReadResults;
BEGIN
  doRead(x, ch, res);
  IF res = IOConsts.allRight THEN
    x^.result := IOConsts.allRight;
  ELSE
    IOLink.RAISEdevException(cid, did, IOChan.skipAtEnd, "ProgramArgs.Skip");
  END;
END doSkipOpen;

PROCEDURE doSkipLookOpen(x: Object; VAR ch: CHAR; VAR res: IOConsts.ReadResults);
BEGIN
  doSkipOpen(x);
  doLookOpen(x, ch, res);
END doSkipLookOpen;

PROCEDURE doTextRead(x: Object; a: SYSTEM.ADDRESS; n: CARDINAL; VAR locs: CARDINAL);
  TYPE BufPtr = POINTER TO ARRAY [0..MAX(CARDINAL) - 1] OF CHAR;
  VAR p: BufPtr; i: CARDINAL; res: IOConsts.ReadResults;
BEGIN
  p := SYSTEM.CAST(BufPtr, a);
  i := 0;
  LOOP
    IF i >= n THEN EXIT END;
    doRead(x, p^[i], res);
    IF res # IOConsts.allRight THEN EXIT END;
    INC(i);
  END;
  locs := i;
  IF (n > 0) & (i = 0) THEN
    x^.result := IOConsts.endOfInput;
  ELSE
    x^.result := IOConsts.allRight;
  END;
END doTextRead;

(*----------------------------------------------------------------*)
(* Closed mode — after NextArg moves past the last arg, the device
   table is swapped to these stubs which raise notAvailable. *)

PROCEDURE doLookClosed(x: Object; VAR c: CHAR; VAR r: IOConsts.ReadResults);
BEGIN
  IOLink.RAISEdevException(x^.cid, x^.did, IOChan.notAvailable,
                           "ProgramArgs.Look");
END doLookClosed;

PROCEDURE doSkipClosed(x: Object);
BEGIN
  IOLink.RAISEdevException(x^.cid, x^.did, IOChan.notAvailable,
                           "ProgramArgs.Skip");
END doSkipClosed;

PROCEDURE doSkipLookClosed(x: Object; VAR c: CHAR; VAR r: IOConsts.ReadResults);
BEGIN
  IOLink.RAISEdevException(x^.cid, x^.did, IOChan.notAvailable,
                           "ProgramArgs.SkipLook");
END doSkipLookClosed;

PROCEDURE doTextReadClosed(x: Object; a: SYSTEM.ADDRESS; max: CARDINAL;
                           VAR n: CARDINAL);
BEGIN
  IOLink.RAISEdevException(x^.cid, x^.did, IOChan.notAvailable,
                           "ProgramArgs.TextRead");
END doTextReadClosed;

(*----------------------------------------------------------------*)

PROCEDURE wireOpen(x: Object);
BEGIN
  (* `ChanConsts.read + ChanConsts.text` would be the idiomatic way to
     express this, but sema doesn't yet accept set-union of cross-module
     CONST sets at assignment sites. Use the singleton-list literal
     instead — same value. *)
  x^.flags     := ChanConsts.FlagSet{ChanConsts.readFlag, ChanConsts.textFlag};
  x^.doLook    := doLookOpen;
  x^.doSkip    := doSkipOpen;
  x^.doSkipLook := doSkipLookOpen;
  x^.doTextRead := doTextRead;
END wireOpen;

PROCEDURE wireClosed(x: Object);
BEGIN
  EXCL(x^.flags, ChanConsts.readFlag);
  x^.result    := IOConsts.endOfInput;
  x^.doLook    := doLookClosed;
  x^.doSkip    := doSkipClosed;
  x^.doSkipLook := doSkipLookClosed;
  x^.doTextRead := doTextReadClosed;
END wireClosed;

PROCEDURE init;
  VAR x: Object;
BEGIN
  IF inited THEN RETURN END;
  inited := TRUE;
  argc := NM2ProgramArgs.Count();
  arg := 1;
  pos := 0; len := 0;
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF arg < argc THEN
    len := NM2ProgramArgs.Copy(arg, SYSTEM.ADR(argBuf), argBufHigh + 1);
    pos := 0;
    wireOpen(x);
  ELSE
    wireClosed(x);
  END;
END init;

(*----------------------------------------------------------------*)

PROCEDURE ArgChan(): ChanId;
BEGIN
  init();
  RETURN cid;
END ArgChan;

PROCEDURE IsArgPresent(): BOOLEAN;
  VAR x: Object; ch: CHAR; res: IOConsts.ReadResults;
BEGIN
  init();
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  doLookOpen(x, ch, res);
  WHILE (res = IOConsts.allRight) & CharClass.IsWhiteSpace(ch) DO
    doSkipOpen(x);
    doLookOpen(x, ch, res);
  END;
  RETURN res = IOConsts.allRight;
END IsArgPresent;

PROCEDURE NextArg;
  VAR x: Object;
BEGIN
  init();
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF arg + 1 >= argc THEN
    wireClosed(x);
  ELSE
    INC(arg);
    len := NM2ProgramArgs.Copy(arg, SYSTEM.ADR(argBuf), argBufHigh + 1);
    pos := 0;
  END;
END NextArg;

BEGIN
  inited := FALSE;
  arg := 0; pos := 0; len := 0;
  IOLink.AllocateDeviceId(did);
  IOLink.MakeChan(did, cid);
END ProgramArgs.
