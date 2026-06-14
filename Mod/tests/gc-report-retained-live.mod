MODULE GCReportRetainedLive;
(*
 * Allocate in two waves, forcing an explicit collection after each wave,
 * so the report shows multiple deterministic collection cycles and reclaimed
 * bytes without depending on module-root registration.
 *)
IMPORT SYSTEM;

TYPE
  Item = RECORD
    serial : INTEGER;
    pad0   : INTEGER;
    pad1   : INTEGER;
    pad2   : INTEGER;
    pad3   : INTEGER;
  END;
  ItemPtr = POINTER TO Item;

VAR
  p : ItemPtr;
  i : INTEGER;

BEGIN
  i := 0;
  WHILE i < 512 DO
    NEW(p);
    p^.serial := i * 7;
    p^.pad0 := i + 1;
    p^.pad1 := i + 2;
    p^.pad2 := i + 3;
    p^.pad3 := i + 4;
    i := i + 1;
  END;
  p := NIL;
  SYSTEM.COLLECT;

  i := 0;
  WHILE i < 512 DO
    NEW(p);
    p^.serial := i * 11;
    p^.pad0 := i + 5;
    p^.pad1 := i + 6;
    p^.pad2 := i + 7;
    p^.pad3 := i + 8;
    i := i + 1;
  END;
  p := NIL;
  SYSTEM.COLLECT;
  SYSTEM.GCREPORT;
END GCReportRetainedLive.