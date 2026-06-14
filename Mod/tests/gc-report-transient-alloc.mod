MODULE GCReportTransientAlloc;
(*
 * Allocate a large number of short-lived records, drop the final pointer,
 * then force a collection and dump the GC metrics.
 *)
IMPORT SYSTEM;

TYPE
  Item = RECORD
    serial : INTEGER;
    pad0   : INTEGER;
    pad1   : INTEGER;
    pad2   : INTEGER;
  END;
  ItemPtr = POINTER TO Item;

VAR
  p : ItemPtr;
  i : INTEGER;

BEGIN
  i := 0;
  WHILE i < 4096 DO
    NEW(p);
    p^.serial := i;
    p^.pad0 := i + 1;
    p^.pad1 := i + 2;
    p^.pad2 := i + 3;
    i := i + 1;
  END;
  p := NIL;
  SYSTEM.COLLECT;
  SYSTEM.GCREPORT;
END GCReportTransientAlloc.