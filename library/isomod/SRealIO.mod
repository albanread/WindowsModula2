(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-14 from XDS 2.60 lib/src/isoimp. Apache-2.0. *)
IMPLEMENTATION MODULE SRealIO;

IMPORT RealIO, StdChans;

TYPE float = REAL;

PROCEDURE ReadReal (VAR real: float);
BEGIN
  RealIO.ReadReal (StdChans.InChan(), real);
END ReadReal;

PROCEDURE WriteFloat (real: float; sigFigs: CARDINAL; width: CARDINAL);
BEGIN
  RealIO.WriteFloat (StdChans.OutChan(), real, sigFigs, width);
END WriteFloat;

PROCEDURE WriteEng (real: float; sigFigs: CARDINAL; width: CARDINAL);
BEGIN
  RealIO.WriteEng (StdChans.OutChan(), real, sigFigs, width);
END WriteEng;

PROCEDURE WriteFixed (real: float; place: INTEGER; width: CARDINAL);
BEGIN
  RealIO.WriteFixed (StdChans.OutChan(), real, place, width);
END WriteFixed;

PROCEDURE WriteReal (real: float; width: CARDINAL);
BEGIN
  RealIO.WriteReal (StdChans.OutChan(), real, width);
END WriteReal;

END SRealIO.
