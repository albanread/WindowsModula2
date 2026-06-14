MODULE T50010GcAlloc;
(*
 * Group 50 — GC / memory
 * Test: allocate 100 records via NEW; GC does not crash.
 *       We verify the last serial is correct (99 * 3 = 297).
 *
 * EXPECTED:
 * 297
 *)
IMPORT STextIO, SWholeIO;

TYPE
  Item = RECORD
    serial : INTEGER;
  END;
  ItemPtr = POINTER TO Item;

VAR p : ItemPtr;
    i : INTEGER;

BEGIN
  i := 0;
  WHILE i < 100 DO
    NEW(p);
    p^.serial := i * 3;
    i := i + 1;
  END;
  (* p still points to the last allocation *)
  SWholeIO.WriteInt(p^.serial, 0);
  STextIO.WriteLn;
END T50010GcAlloc.
