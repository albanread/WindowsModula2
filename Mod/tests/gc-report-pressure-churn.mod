MODULE GCReportPressureChurn;
(*
 * Allocate enough temporary records to cross a low pressure threshold and let
 * the runtime trigger collections during allocation, then dump the metrics.
 *)
IMPORT SYSTEM;

TYPE
  Item = RECORD
    serial : INTEGER;
    pad0   : INTEGER;
    pad1   : INTEGER;
    pad2   : INTEGER;
    pad3   : INTEGER;
    pad4   : INTEGER;
  END;
  ItemPtr = POINTER TO Item;

VAR
  p : ItemPtr;
  i : INTEGER;

BEGIN
  i := 0;
  WHILE i < 8192 DO
    NEW(p);
    p^.serial := i;
    p^.pad0 := i + 1;
    p^.pad1 := i + 2;
    p^.pad2 := i + 3;
    p^.pad3 := i + 4;
    p^.pad4 := i + 5;
    i := i + 1;
  END;
  p := NIL;
  SYSTEM.GCREPORT;
END GCReportPressureChurn.