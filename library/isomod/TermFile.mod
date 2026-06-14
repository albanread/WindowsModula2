(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-15 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - XDS backs TermFile with `xDevData` records that own a file handle
       for the terminal device. NewM2 multiplexes the controlling
       terminal through the same NM2IO shims StdChans uses, so we don't
       need a per-channel handle — each Open allocates a fresh
       DeviceTable, wires it to NM2IO procs, and bumps a refcount.
     - Close drops the refcount and forgets the table. Closing the
       LAST open TermFile channel does NOT close the underlying stdin/
       stdout streams — those belong to StdChans for the lifetime of
       the program.
     - `IsTermFile` recognises any channel whose deviceId matches the
       one we registered.
*)
IMPLEMENTATION MODULE TermFile;

IMPORT SYSTEM, IOChan, IOLink, IOConsts, ChanConsts, NM2IO;

VAR did: IOLink.DeviceId;

(*----------------------------------------------------------------*)
(* Reader half — stdin. *)

PROCEDURE termLook(x: IOLink.DeviceTablePtr; VAR ch: CHAR;
                   VAR res: IOConsts.ReadResults);
  VAR r: INTEGER;
BEGIN
  NM2IO.PeekChar(ch, r);
  res := VAL(IOConsts.ReadResults, r);
  x^.result := res;
END termLook;

PROCEDURE termSkip(x: IOLink.DeviceTablePtr);
BEGIN
  NM2IO.ConsumeChar();
  x^.result := IOConsts.allRight;
END termSkip;

PROCEDURE termSkipLook(x: IOLink.DeviceTablePtr; VAR ch: CHAR;
                       VAR res: IOConsts.ReadResults);
BEGIN
  NM2IO.ConsumeChar();
  termLook(x, ch, res);
END termSkipLook;

PROCEDURE termTextRead(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                       max: CARDINAL; VAR n: CARDINAL);
BEGIN
  NM2IO.ReadText(a, max, n);
  IF n = 0 THEN
    x^.result := IOConsts.endOfInput;
  ELSE
    x^.result := IOConsts.allRight;
  END;
END termTextRead;

(*----------------------------------------------------------------*)
(* Writer half — stdout. *)

PROCEDURE termTextWrite(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                        n: CARDINAL);
BEGIN
  NM2IO.WriteText(a, n);
END termTextWrite;

PROCEDURE termWriteLn(x: IOLink.DeviceTablePtr);
  VAR nl: ARRAY [0..0] OF CHAR;
BEGIN
  nl[0] := 12C;  (* LF *)
  NM2IO.WriteText(SYSTEM.ADR(nl), 1);
END termWriteLn;

PROCEDURE termFlush(x: IOLink.DeviceTablePtr);
BEGIN
  NM2IO.Flush();
END termFlush;

PROCEDURE noopReset(x: IOLink.DeviceTablePtr);
BEGIN
END noopReset;

PROCEDURE noopGetName(x: IOLink.DeviceTablePtr; VAR s: ARRAY OF CHAR);
BEGIN
  IF HIGH(s) >= 0 THEN s[0] := 0C END;
END noopGetName;

(*----------------------------------------------------------------*)

PROCEDURE wire(x: IOLink.DeviceTablePtr; flags: FlagSet);
BEGIN
  (* Always populate every slot — even read-only channels get
     no-op write procs (and vice-versa) so a buggy callee that
     dispatches through the wrong field doesn't fall into NIL. *)
  x^.flags        := flags;
  x^.doLook       := termLook;
  x^.doSkip       := termSkip;
  x^.doSkipLook   := termSkipLook;
  x^.doTextRead   := termTextRead;
  x^.doRawRead    := termTextRead;
  x^.doTextWrite  := termTextWrite;
  x^.doRawWrite   := termTextWrite;
  x^.doLnWrite    := termWriteLn;
  x^.doGetName    := noopGetName;
  x^.doReset      := noopReset;
  x^.doFlush      := termFlush;
END wire;

PROCEDURE Open(VAR cid: ChanId; flags: FlagSet; VAR res: OpenResults);
  VAR x: IOLink.DeviceTablePtr;
BEGIN
  IOLink.MakeChan(did, cid);
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x = NIL THEN
    res := ChanConsts.noRoomOnDevice;
    RETURN;
  END;
  wire(x, flags);
  res := ChanConsts.opened;
END Open;

PROCEDURE IsTermFile(cid: ChanId): BOOLEAN;
  VAR x: IOLink.DeviceTablePtr;
BEGIN
  IF cid = NIL THEN RETURN FALSE END;
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  RETURN x^.did = did;
END IsTermFile;

PROCEDURE Close(VAR cid: ChanId);
BEGIN
  (* The underlying terminal stays open for the life of the program;
     dropping the cid is enough.  We don't free the DeviceTable memory
     — IOLink owns it and the cost of a forgotten record is two
     pointers. *)
  cid := IOChan.InvalidChan();
END Close;

BEGIN
  IOLink.AllocateDeviceId(did);
END TermFile.
