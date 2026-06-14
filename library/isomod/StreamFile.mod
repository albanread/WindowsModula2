(* Copyright (c) xTech 1993,94. All Rights Reserved. *)
(* Ported to NewM2 2026-05-15 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - XDS backs StreamFile with `xDevData` records owning a file handle
       and a buffer.  NewM2 stashes a small `State` record in the
       DeviceTable's `cd` (DeviceData) slot, holding the opaque file
       handle returned by NM2File plus a 1-byte look-ahead.
     - The "stream" model: a single direction (read XOR write) chosen
       at Open time.  Both directions in one channel = use SeqFile.
     - Text vs raw is just a passthrough flag here — the runtime reads
       bytes either way; ChanConsts.textFlag / rawFlag is recorded in
       `flags` so `IsTermFile`-style queries work but the byte stream
       isn't transformed.
*)
IMPLEMENTATION MODULE StreamFile;

IMPORT SYSTEM, IOChan, IOLink, IOConsts, ChanConsts, Storage, NM2File;

TYPE
  StatePtr = POINTER TO State;
  State = RECORD
    handle:   CARDINAL64;
    nameBuf:  ARRAY [0..255] OF CHAR;  (* keep the path around for GetName *)
    havePeek: BOOLEAN;
    peekCh:   CHAR;
  END;

VAR did: IOLink.DeviceId;

(*----------------------------------------------------------------*)

PROCEDURE stateOf(x: IOLink.DeviceTablePtr): StatePtr;
BEGIN
  RETURN SYSTEM.CAST(StatePtr, x^.cd);
END stateOf;

PROCEDURE refillPeek(s: StatePtr): BOOLEAN;
  VAR n: CARDINAL64;
BEGIN
  IF s^.havePeek THEN RETURN TRUE END;
  n := NM2File.ReadText(s^.handle, SYSTEM.ADR(s^.peekCh), 1);
  IF n = 0 THEN RETURN FALSE END;
  s^.havePeek := TRUE;
  RETURN TRUE;
END refillPeek;

PROCEDURE doLook(x: IOLink.DeviceTablePtr; VAR ch: CHAR;
                 VAR res: IOConsts.ReadResults);
  VAR s: StatePtr;
BEGIN
  s := stateOf(x);
  IF refillPeek(s) THEN
    ch := s^.peekCh;
    res := IOConsts.allRight;
  ELSE
    ch := 0C;
    res := IOConsts.endOfInput;
  END;
  x^.result := res;
END doLook;

PROCEDURE doSkip(x: IOLink.DeviceTablePtr);
  VAR s: StatePtr; ch: CHAR;
BEGIN
  s := stateOf(x);
  IF s^.havePeek THEN
    s^.havePeek := FALSE;
    x^.result := IOConsts.allRight;
  ELSE
    (* Read-and-discard one byte. *)
    IF NM2File.ReadText(s^.handle, SYSTEM.ADR(ch), 1) > 0 THEN
      x^.result := IOConsts.allRight;
    ELSE
      x^.result := IOConsts.endOfInput;
    END;
  END;
END doSkip;

PROCEDURE doSkipLook(x: IOLink.DeviceTablePtr; VAR ch: CHAR;
                     VAR res: IOConsts.ReadResults);
BEGIN
  doSkip(x);
  doLook(x, ch, res);
END doSkipLook;

PROCEDURE doTextRead(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                     max: CARDINAL; VAR locs: CARDINAL);
  TYPE BufPtr = POINTER TO ARRAY [0..MAX(CARDINAL) - 1] OF CHAR;
  VAR s: StatePtr; p: BufPtr; i: CARDINAL; n: CARDINAL64;
BEGIN
  s := stateOf(x);
  p := SYSTEM.CAST(BufPtr, a);
  i := 0;
  IF s^.havePeek & (max > 0) THEN
    p^[0] := s^.peekCh;
    s^.havePeek := FALSE;
    i := 1;
  END;
  IF i < max THEN
    n := NM2File.ReadText(s^.handle, SYSTEM.ADR(p^[i]), VAL(CARDINAL64, max - i));
    i := i + VAL(CARDINAL, n);
  END;
  locs := i;
  IF i = 0 THEN
    x^.result := IOConsts.endOfInput;
  ELSE
    x^.result := IOConsts.allRight;
  END;
END doTextRead;

PROCEDURE doTextWrite(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                      n: CARDINAL);
  VAR s: StatePtr; wrote: CARDINAL64;
BEGIN
  s := stateOf(x);
  wrote := NM2File.WriteText(s^.handle, a, VAL(CARDINAL64, n));
  IF wrote = VAL(CARDINAL64, n) THEN
    x^.result := IOConsts.allRight;
  END;
END doTextWrite;

(* Raw I/O moves bytes verbatim — `max`/`n` are byte (LOC) counts, not
   UTF-16 cells — so it must use NM2File.Read/Write, not the text path's
   UTF-16<->UTF-8 conversion (which mis-sizes and corrupts raw data). *)
PROCEDURE doRawRead(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                    max: CARDINAL; VAR locs: CARDINAL);
  VAR s: StatePtr; n: CARDINAL64;
BEGIN
  s := stateOf(x);
  n := NM2File.Read(s^.handle, a, VAL(CARDINAL64, max));
  locs := VAL(CARDINAL, n);
  IF locs = 0 THEN
    x^.result := IOConsts.endOfInput;
  ELSE
    x^.result := IOConsts.allRight;
  END;
END doRawRead;

PROCEDURE doRawWrite(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                     n: CARDINAL);
  VAR s: StatePtr; wrote: CARDINAL64;
BEGIN
  s := stateOf(x);
  wrote := NM2File.Write(s^.handle, a, VAL(CARDINAL64, n));
  IF wrote = VAL(CARDINAL64, n) THEN
    x^.result := IOConsts.allRight;
  END;
END doRawWrite;

PROCEDURE doLnWrite(x: IOLink.DeviceTablePtr);
  VAR nl: ARRAY [0..0] OF CHAR;
BEGIN
  nl[0] := 12C;  (* LF *)
  doTextWrite(x, SYSTEM.ADR(nl), 1);
END doLnWrite;

PROCEDURE doReset(x: IOLink.DeviceTablePtr);
  VAR s: StatePtr;
BEGIN
  s := stateOf(x);
  s^.havePeek := FALSE;
  IF NM2File.Seek(s^.handle, 0) = 0 THEN
    x^.result := IOConsts.allRight;
  END;
END doReset;

PROCEDURE doFlush(x: IOLink.DeviceTablePtr);
  VAR s: StatePtr;
BEGIN
  s := stateOf(x);
  NM2File.Flush(s^.handle);
END doFlush;

PROCEDURE doGetName(x: IOLink.DeviceTablePtr; VAR s: ARRAY OF CHAR);
  VAR st: StatePtr; i: CARDINAL;
BEGIN
  st := stateOf(x);
  i := 0;
  WHILE (i <= HIGH(s)) & (i <= 255) & (st^.nameBuf[i] # 0C) DO
    s[i] := st^.nameBuf[i];
    INC(i);
  END;
  IF i <= HIGH(s) THEN s[i] := 0C END;
END doGetName;

PROCEDURE doFree(x: IOLink.DeviceTablePtr);
  VAR s: StatePtr; a: SYSTEM.ADDRESS;
BEGIN
  s := stateOf(x);
  IF s = NIL THEN RETURN END;
  IF s^.handle # 0 THEN
    NM2File.Flush(s^.handle);
    NM2File.Close(s^.handle);
    s^.handle := 0;
  END;
  a := SYSTEM.CAST(SYSTEM.ADDRESS, s);
  Storage.DEALLOCATE(a, SYSTEM.TSIZE(State));
  x^.cd := NIL;
END doFree;

(*----------------------------------------------------------------*)

PROCEDURE wire(x: IOLink.DeviceTablePtr; flags: FlagSet);
BEGIN
  x^.flags        := flags;
  x^.doLook       := doLook;
  x^.doSkip       := doSkip;
  x^.doSkipLook   := doSkipLook;
  x^.doLnWrite    := doLnWrite;
  x^.doTextRead   := doTextRead;
  x^.doTextWrite  := doTextWrite;
  x^.doRawRead    := doRawRead;
  x^.doRawWrite   := doRawWrite;
  x^.doGetName    := doGetName;
  x^.doReset      := doReset;
  x^.doFlush      := doFlush;
  x^.doFree       := doFree;
END wire;

PROCEDURE buildFlagBits(flags: FlagSet): CARDINAL64;
  VAR bits: CARDINAL64;
BEGIN
  bits := 0;
  IF ChanConsts.readFlag  IN flags THEN bits := bits + NM2File.ReadFlag  END;
  IF ChanConsts.writeFlag IN flags THEN bits := bits + NM2File.WriteFlag END;
  IF ChanConsts.oldFlag   IN flags THEN bits := bits + NM2File.OldFlag   END;
  (* No newFlag in ChanConsts (StreamFile's old/!old toggles create); the
     runtime treats absence of old + write as create-without-truncate.  *)
  RETURN bits;
END buildFlagBits;

PROCEDURE copyName(VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(dst)) & (i <= HIGH(src)) & (src[i] # 0C) DO
    dst[i] := src[i];
    INC(i);
  END;
  IF i <= HIGH(dst) THEN dst[i] := 0C END;
END copyName;

PROCEDURE Open(VAR cid: ChanId; name: ARRAY OF CHAR;
               flags: FlagSet; VAR res: OpenResults);
  VAR x: IOLink.DeviceTablePtr;
      s: StatePtr;
      a: SYSTEM.ADDRESS;
      h: CARDINAL64;
BEGIN
  IOLink.MakeChan(did, cid);
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x = NIL THEN
    res := ChanConsts.noRoomOnDevice;
    RETURN;
  END;
  h := NM2File.Open(SYSTEM.ADR(name), buildFlagBits(flags));
  IF h = 0 THEN
    res := ChanConsts.noSuchFile;
    RETURN;
  END;
  Storage.ALLOCATE(a, SYSTEM.TSIZE(State));
  s := SYSTEM.CAST(StatePtr, a);
  IF s = NIL THEN
    NM2File.Close(h);
    res := ChanConsts.noRoomOnDevice;
    RETURN;
  END;
  s^.handle   := h;
  s^.havePeek := FALSE;
  s^.peekCh   := 0C;
  copyName(s^.nameBuf, name);
  x^.cd := SYSTEM.CAST(SYSTEM.ADDRESS, s);
  wire(x, flags);
  res := ChanConsts.opened;
END Open;

PROCEDURE IsStreamFile(cid: ChanId): BOOLEAN;
  VAR x: IOLink.DeviceTablePtr;
BEGIN
  IF cid = NIL THEN RETURN FALSE END;
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  RETURN x^.did = did;
END IsStreamFile;

PROCEDURE Close(VAR cid: ChanId);
  VAR x: IOLink.DeviceTablePtr;
BEGIN
  IF cid = NIL THEN RETURN END;
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x^.did = did THEN doFree(x) END;
  cid := IOChan.InvalidChan();
END Close;

BEGIN
  IOLink.AllocateDeviceId(did);
END StreamFile.
