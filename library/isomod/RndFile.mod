(* Copyright (c) xTech 1993,94. All Rights Reserved. *)
(* Ported to NewM2 2026-05-15 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - Same disk-file backing as StreamFile/SeqFile, plus seek-based
       random access.
     - FilePos is `ARRAY [1..8] OF SYSTEM.LOC` per the def — eight
       bytes that we treat as a little-endian u64 byte offset. Helpers
       fileposToU64 / u64ToFilePos do the conversion.
     - OpenClean truncates; OpenOld preserves existing contents.
*)
IMPLEMENTATION MODULE RndFile;

IMPORT SYSTEM, IOChan, IOLink, IOConsts, ChanConsts, Storage, NM2RT, NM2File;

TYPE
  StatePtr = POINTER TO State;
  State = RECORD
    handle:   CARDINAL64;
    nameBuf:  ARRAY [0..255] OF CHAR;
    havePeek: BOOLEAN;
    peekCh:   CHAR;
  END;

VAR did: IOLink.DeviceId;
    rndExceptionSource: CARDINAL64;

PROCEDURE stateOf(x: IOLink.DeviceTablePtr): StatePtr;
BEGIN
  RETURN SYSTEM.CAST(StatePtr, x^.cd);
END stateOf;

(*----------------------------------------------------------------*)

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

(* Raw I/O moves bytes verbatim (byte/LOC counts, not UTF-16 cells), so it
   must use NM2File.Read/Write, not the text UTF-16<->UTF-8 path. *)
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
  nl[0] := 12C;
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
(* FilePos <-> u64 helpers. Little-endian byte encoding. *)

(* FilePos is 8 bytes — same shape as CARDINAL64. Cast a pointer to
   the array start and read/write it as one 64-bit integer.  This dodges
   per-byte SYSTEM.CAST chains, which sema struggles with when the
   "target type" arg is a pervasive identifier like CARDINAL. *)
TYPE U64Ptr = POINTER TO CARDINAL64;

PROCEDURE fileposToU64(pos: FilePos): CARDINAL64;
  VAR p: U64Ptr;
BEGIN
  p := SYSTEM.CAST(U64Ptr, SYSTEM.ADR(pos));
  RETURN p^;
END fileposToU64;

PROCEDURE u64ToFilepos(v: CARDINAL64): FilePos;
  VAR p: FilePos; q: U64Ptr;
BEGIN
  q := SYSTEM.CAST(U64Ptr, SYSTEM.ADR(p));
  q^ := v;
  RETURN p;
END u64ToFilepos;

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

PROCEDURE buildFlagBits(flags: FlagSet; truncate: BOOLEAN): CARDINAL64;
  VAR bits: CARDINAL64;
BEGIN
  bits := 0;
  IF ChanConsts.readFlag  IN flags THEN bits := bits + NM2File.ReadFlag  END;
  IF ChanConsts.writeFlag IN flags THEN bits := bits + NM2File.WriteFlag END;
  IF ChanConsts.oldFlag   IN flags THEN bits := bits + NM2File.OldFlag   END;
  IF truncate THEN bits := bits + NM2File.NewFlag END;
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

PROCEDURE openCommon(VAR cid: ChanId; name: ARRAY OF CHAR;
                     flags: FlagSet; VAR res: OpenResults;
                     truncate: BOOLEAN);
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
  h := NM2File.Open(SYSTEM.ADR(name),
                    buildFlagBits(flags + FlagSet{ChanConsts.readFlag, ChanConsts.writeFlag},
                                  truncate));
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
  wire(x, flags + FlagSet{ChanConsts.readFlag, ChanConsts.writeFlag});
  res := ChanConsts.opened;
END openCommon;

PROCEDURE OpenOld(VAR cid: ChanId; name: ARRAY OF CHAR;
                  flags: FlagSet; VAR res: OpenResults);
BEGIN
  openCommon(cid, name, flags + FlagSet{ChanConsts.oldFlag}, res, FALSE);
END OpenOld;

PROCEDURE OpenClean(VAR cid: ChanId; name: ARRAY OF CHAR;
                    flags: FlagSet; VAR res: OpenResults);
BEGIN
  openCommon(cid, name, flags, res, TRUE);
END OpenClean;

PROCEDURE IsRndFile(cid: ChanId): BOOLEAN;
  VAR x: IOLink.DeviceTablePtr;
BEGIN
  IF cid = NIL THEN RETURN FALSE END;
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  RETURN x^.did = did;
END IsRndFile;

PROCEDURE IsRndFileException(): BOOLEAN;
BEGIN
  RETURN NM2RT.IsExceptionalExecution() &
         NM2RT.IsCurrentExceptionSource(rndExceptionSource);
END IsRndFileException;

PROCEDURE StartPos(cid: ChanId): FilePos;
BEGIN
  RETURN u64ToFilepos(0);
END StartPos;

PROCEDURE CurrentPos(cid: ChanId): FilePos;
  VAR x: IOLink.DeviceTablePtr; s: StatePtr;
BEGIN
  IF cid = NIL THEN RETURN u64ToFilepos(0) END;
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x^.did # did THEN RETURN u64ToFilepos(0) END;
  s := stateOf(x);
  RETURN u64ToFilepos(NM2File.Tell(s^.handle));
END CurrentPos;

PROCEDURE EndPos(cid: ChanId): FilePos;
  VAR x: IOLink.DeviceTablePtr; s: StatePtr;
BEGIN
  IF cid = NIL THEN RETURN u64ToFilepos(0) END;
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x^.did # did THEN RETURN u64ToFilepos(0) END;
  s := stateOf(x);
  RETURN u64ToFilepos(NM2File.Size(s^.handle));
END EndPos;

PROCEDURE NewPos(cid: ChanId; chunks: INTEGER; chunkSize: CARDINAL;
                 from: FilePos): FilePos;
  VAR base, delta, result: CARDINAL64;
BEGIN
  base := fileposToU64(from);
  IF chunks >= 0 THEN
    delta := VAL(CARDINAL64, chunks) * VAL(CARDINAL64, chunkSize);
    result := base + delta;
  ELSE
    delta := VAL(CARDINAL64, -chunks) * VAL(CARDINAL64, chunkSize);
    IF delta > base THEN
      result := 0;
    ELSE
      result := base - delta;
    END;
  END;
  RETURN u64ToFilepos(result);
END NewPos;

PROCEDURE SetPos(cid: ChanId; pos: FilePos);
  VAR x: IOLink.DeviceTablePtr; s: StatePtr;
BEGIN
  IF cid = NIL THEN RETURN END;
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x^.did # did THEN RETURN END;
  s := stateOf(x);
  s^.havePeek := FALSE;
  IF NM2File.Seek(s^.handle, fileposToU64(pos)) # 0 THEN
    NM2RT.Raise(rndExceptionSource, 1, "RndFile.SetPos: seek failed");
  END;
END SetPos;

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
  rndExceptionSource := NM2RT.AllocateExceptionSource();
END RndFile.
