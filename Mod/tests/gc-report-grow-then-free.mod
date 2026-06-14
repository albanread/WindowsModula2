MODULE GCReportGrowThenFree;
(*
 * Allocate one oversized GC-managed record, drop the pointer, then force a
 * collection so the report shows the large object was reclaimed.
 *)
IMPORT SYSTEM;

TYPE
  HugePtr = POINTER TO Huge;
  Huge = RECORD
    serial : INTEGER;
    payload : ARRAY [0..131071] OF INTEGER;
  END;

VAR
  p : HugePtr;

BEGIN
  NEW(p);
  p^.serial := 67890;
  p^.payload[0] := 3;
  p^.payload[131071] := 4;
  p := NIL;
  SYSTEM.COLLECT;
  SYSTEM.GCREPORT;
END GCReportGrowThenFree.