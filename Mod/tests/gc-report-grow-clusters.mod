MODULE GCReportGrowClusters;
(*
 * Allocate one oversized GC-managed record whose payload exceeds the default
 * cluster size, forcing the allocator to grow the heap for this request.
 *)
IMPORT SYSTEM;

TYPE
  HugePtr = POINTER TO Huge;
  Huge = RECORD
    serial : INTEGER;
    payload : ARRAY [0..132095] OF INTEGER;
  END;

VAR
  p : HugePtr;

BEGIN
  NEW(p);
  p^.serial := 12345;
  p^.payload[0] := 1;
  p^.payload[132095] := 2;
  SYSTEM.GCREPORT;
END GCReportGrowClusters.