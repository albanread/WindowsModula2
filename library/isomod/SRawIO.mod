(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-14 from XDS 2.60 lib/src/isoimp. Apache-2.0. *)
IMPLEMENTATION MODULE SRawIO;

IMPORT SYSTEM, StdChans, RawIO;

PROCEDURE Read(VAR to: ARRAY OF SYSTEM.LOC);
BEGIN
  RawIO.Read(StdChans.InChan(), to);
END Read;

PROCEDURE Write(from: ARRAY OF SYSTEM.LOC);
BEGIN
  RawIO.Write(StdChans.OutChan(), from);
END Write;

END SRawIO.
