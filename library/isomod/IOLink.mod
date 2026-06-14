(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-14 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - Replaced `<* IF NOT STORAGE THEN *> FROM Storage IMPORT ALLOCATE,
       DEALLOCATE; <* END *>` with an unconditional import — NewM2's
       Storage module is part of our isodef tree and is always available.
     - Dropped XDS `<* IF EXCEPTIONS *> ... <* ELSE XRaise *> <* END *>`
       branches; kept the EXCEPTIONS arm only (XRaise is XDS-internal).
     - Dropped the constant-parameter modifier (`name-: ARRAY OF CHAR`
       → plain `name: ARRAY OF CHAR`). NewM2 doesn't yet implement that
       extension; for these read-only callsites the difference is moot.
     - Inlined the `WITH inv DO ... END` initialiser as explicit
       `inv.field := ...` writes (sema-level WITH field injection
       isn't wired yet).
     - Dropped the WOFF301 pragma chevrons around the stub procs —
       not relevant outside XDS.
     - PROCEDURE forwards-aren't allowed before BEGIN with our sema, so
       the default stubs (look/skip/...) precede the proc init block as
       in the XDS source — order preserved.
*)
IMPLEMENTATION MODULE IOLink;

IMPORT SYSTEM, IOChan, IOConsts, ChanConsts, Strings;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
IMPORT EXCEPTIONS;

VAR source: EXCEPTIONS.ExceptionSource;

TYPE
  DeviceId = POINTER TO RECORD dummy: INTEGER END;

VAR
  inv: DeviceTable;

PROCEDURE raise(e: IOChan.ChanExceptions; name: ARRAY OF CHAR);
  VAR s: ARRAY [0..128] OF CHAR;
BEGIN
  CASE e OF
    | IOChan.wrongDevice     : s := "IOException.wrongDevice"
    | IOChan.notAvailable    : s := "IOException.notAvailable"
    | IOChan.skipAtEnd       : s := "IOException.skipAtEnd"
    | IOChan.softDeviceError : s := "IOException.softDeviceError"
    | IOChan.hardDeviceError : s := "IOException.hardDeviceError"
    | IOChan.textParseError  : s := "IOException.textParseError"
    | IOChan.notAChannel     : s := "IOException.notAChannel"
  END;
  IF name[0] # 0C THEN
    Strings.Append(" ", s);
    Strings.Append(name, s);
  END;
  EXCEPTIONS.RAISE(source, ORD(e), s);
END raise;

PROCEDURE AllocateDeviceId(VAR did: DeviceId);
BEGIN
  NEW(did);
END AllocateDeviceId;

PROCEDURE MakeChan(did: DeviceId; VAR cid: IOChan.ChanId);
  VAR x: DeviceTablePtr;
BEGIN
  NEW(x);
  IF x = NIL THEN
    cid := IOChan.InvalidChan();
  ELSE
    x^ := inv;
    x^.did := did;
    cid := SYSTEM.CAST(IOChan.ChanId, x);
    x^.cid := cid;
  END;
END MakeChan;

PROCEDURE UnMakeChan(did: DeviceId; VAR cid: IOChan.ChanId);
  VAR x: DeviceTablePtr;
BEGIN
  x := SYSTEM.CAST(DeviceTablePtr, cid);
  IF (x = NIL) OR (did # x^.did) THEN
    raise(IOChan.wrongDevice, "IOLink.UnMakeChan");
    RETURN;
  END;
  DISPOSE(x);
  cid := IOChan.InvalidChan();
END UnMakeChan;

PROCEDURE DeviceTablePtrValue(cid: IOChan.ChanId; did: DeviceId;
                              x: DevExceptionRange; s: ARRAY OF CHAR): DeviceTablePtr;
  VAR dt: DeviceTablePtr;
BEGIN
  dt := SYSTEM.CAST(DeviceTablePtr, cid);
  IF (dt = NIL) OR (did # dt^.did) THEN
    raise(IOChan.wrongDevice, "IOLink.DeviceTablePtrValue");
    RETURN NIL;
  END;
  RETURN dt;
END DeviceTablePtrValue;

PROCEDURE IsDevice(cid: IOChan.ChanId; did: DeviceId): BOOLEAN;
  VAR x: DeviceTablePtr;
BEGIN
  x := SYSTEM.CAST(DeviceTablePtr, cid);
  RETURN (x # NIL) & (did = x^.did);
END IsDevice;

PROCEDURE RAISEdevException(cid: IOChan.ChanId; did: DeviceId;
                            e: DevExceptionRange; s: ARRAY OF CHAR);
  VAR x: DeviceTablePtr;
BEGIN
  x := SYSTEM.CAST(DeviceTablePtr, cid);
  IF (x = NIL) OR (did # x^.did) THEN
    raise(IOChan.wrongDevice, "IOLink.RAISEdevException");
    RETURN;
  END;
  raise(e, s);
END RAISEdevException;

PROCEDURE IOException(): IOChan.ChanExceptions;
BEGIN
  IF EXCEPTIONS.IsCurrentSource(source) THEN
    RETURN VAL(IOChan.ChanExceptions, EXCEPTIONS.CurrentNumber(source));
  ELSE
    HALT;
  END;
END IOException;

PROCEDURE IsIOException(): BOOLEAN;
BEGIN
  RETURN EXCEPTIONS.IsCurrentSource(source);
END IsIOException;

(* -- Default "notAvailable" stubs installed in the prototype device
      table. Every fresh DeviceTablePtr starts pointing at these;
      device modules overwrite the slots they actually implement. *)

PROCEDURE look(x: DeviceTablePtr; VAR c: CHAR; VAR r: IOConsts.ReadResults);
BEGIN
  raise(IOChan.notAvailable, "Look");
END look;

PROCEDURE skip(x: DeviceTablePtr);
BEGIN
  raise(IOChan.notAvailable, "Skip");
END skip;

PROCEDURE read(x: DeviceTablePtr; a: SYSTEM.ADDRESS; max: CARDINAL; VAR n: CARDINAL);
BEGIN
  raise(IOChan.notAvailable, "Read");
END read;

PROCEDURE write(x: DeviceTablePtr; a: SYSTEM.ADDRESS; max: CARDINAL);
BEGIN
  raise(IOChan.notAvailable, "Write");
END write;

PROCEDURE name(x: DeviceTablePtr; VAR s: ARRAY OF CHAR);
BEGIN
  s[0] := 0C;
END name;

PROCEDURE dummy(x: DeviceTablePtr);
BEGIN
END dummy;

BEGIN
  inv.cd := NIL;
  NEW(inv.did);
  inv.cid := NIL;
  inv.result := IOConsts.notKnown;
  inv.errNum := 0;
  inv.flags := ChanConsts.FlagSet{};
  inv.doLook := look;
  inv.doSkip := skip;
  inv.doSkipLook := look;
  inv.doTextRead := read;
  inv.doTextWrite := write;
  inv.doLnWrite := skip;
  inv.doRawRead := read;
  inv.doRawWrite := write;
  inv.doGetName := name;
  inv.doReset := dummy;
  inv.doFlush := dummy;
  inv.doFree := dummy;
  EXCEPTIONS.AllocateSource(source);
END IOLink.
