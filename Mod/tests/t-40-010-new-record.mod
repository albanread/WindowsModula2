MODULE T40010NewRecord;
(*
 * Group 40 — Records / pointers / NEW
 * Test: NEW allocates a record; field writes and reads are correct.
 *
 * EXPECTED:
 * 99
 * 198
 *)
IMPORT STextIO, SWholeIO;

TYPE
  Node = RECORD
    value  : INTEGER;
    serial : INTEGER;
  END;
  NodePtr = POINTER TO Node;

VAR p : NodePtr;

BEGIN
  NEW(p);
  p^.value  := 99;
  p^.serial := p^.value * 2;
  SWholeIO.WriteInt(p^.value, 0);
  STextIO.WriteLn;
  SWholeIO.WriteInt(p^.serial, 0);
  STextIO.WriteLn;
END T40010NewRecord.
