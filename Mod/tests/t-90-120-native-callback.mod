MODULE t90120;
(* Native callback proof. An M2 procedure variable lowers to a raw
   C function pointer, so an M2 procedure can be handed to any C API expecting a
   callback. NM2RT.SortInts (the runtime) sorts an INTEGER array in place,
   calling back into the M2 comparator for every comparison — the runtime drives
   M2 code through a function pointer, the dual of the COM-server proof (where an
   external client drove M2 through a vtable). *)
IMPORT STextIO, SWholeIO, NM2RT;
FROM SYSTEM IMPORT ADR;

VAR data : ARRAY [0..4] OF INTEGER;
    i    : CARDINAL;

PROCEDURE Ascending(a, b: INTEGER): INTEGER;
BEGIN
  RETURN a - b
END Ascending;

PROCEDURE Descending(a, b: INTEGER): INTEGER;
BEGIN
  RETURN b - a
END Descending;

PROCEDURE Fill;
BEGIN
  data[0] := 5; data[1] := 2; data[2] := 8; data[3] := 1; data[4] := 4
END Fill;

PROCEDURE Show;
BEGIN
  FOR i := 0 TO 4 DO SWholeIO.WriteInt(data[i], 0); STextIO.WriteString(" ") END;
  STextIO.WriteLn
END Show;

BEGIN
  Fill;
  NM2RT.SortInts(ADR(data), 5, Ascending);    (* runtime calls Ascending back *)
  Show;                                        (* 1 2 4 5 8 *)
  NM2RT.SortInts(ADR(data), 5, Descending);    (* runtime calls Descending back *)
  Show                                         (* 8 5 4 2 1 *)
END t90120.
