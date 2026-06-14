(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-14 from XDS 2.60 lib/src/isoimp. Apache-2.0. *)
IMPLEMENTATION MODULE SIOResult;

IMPORT IOChan, StdChans;

PROCEDURE ReadResult(): ReadResults;
BEGIN
  RETURN IOChan.ReadResult(StdChans.InChan());
END ReadResult;

END SIOResult.
