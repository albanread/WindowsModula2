MODULE GcStress;
(*
 * GC stress test: allocates 1000 heap records to exercise the cluster
 * allocator and mark-sweep collector.  Run with:
 *
 *   newm2 dump-heap Mod\gc_stress.mod
 *)

TYPE
  Node = RECORD
    value  : INTEGER;
    serial : INTEGER;
  END;
  NodePtr = POINTER TO Node;

VAR
  p : NodePtr;
  i : INTEGER;

BEGIN
  i := 0;
  WHILE i < 1000 DO
    NEW(p);
    p^.value  := i;
    p^.serial := i * 2;
    i := i + 1;
  END;
END GcStress.
