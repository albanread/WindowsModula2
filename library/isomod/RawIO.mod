(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-14 from XDS 2.60 lib/src/isoimp. Apache-2.0. *)
IMPLEMENTATION MODULE RawIO;

IMPORT SYSTEM, IOChan, IOConsts;

PROCEDURE Read(cid: IOChan.ChanId; VAR to: ARRAY OF SYSTEM.LOC);
  VAR n: CARDINAL;
BEGIN
  IOChan.RawRead(cid,SYSTEM.ADR(to),HIGH(to)+1,n);
  IF (n>0) & (n<=HIGH(to)) THEN
    IOChan.SetReadResult(cid,IOConsts.wrongFormat);
  END;
END Read;

PROCEDURE Write(cid: IOChan.ChanId; from: ARRAY OF SYSTEM.LOC);
BEGIN
  IOChan.RawWrite(cid,SYSTEM.ADR(from),HIGH(from)+1);
END Write;

END RawIO.
