(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-14 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Trivial wrapper: delegates to IOChan.ReadResult. *)
IMPLEMENTATION MODULE IOResult;

IMPORT IOConsts, IOChan;

PROCEDURE ReadResult(cid: IOChan.ChanId): ReadResults;
BEGIN
  RETURN IOChan.ReadResult(cid)
END ReadResult;

END IOResult.
