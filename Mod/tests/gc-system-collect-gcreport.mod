MODULE GCSystemCollectGcReport;
(*
 * GC smoke test: invoke the runtime collector explicitly and dump the
 * current GC metrics through SYSTEM.GCREPORT.
 *)
IMPORT SYSTEM;

BEGIN
  SYSTEM.COLLECT;
  SYSTEM.GCREPORT;
END GCSystemCollectGcReport.