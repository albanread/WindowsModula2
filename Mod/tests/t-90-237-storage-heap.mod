MODULE T90237StorageHeap;
(*
 * Group 90 — M2WINRT runtime: ISO Storage is now backed by the self-hosted M2
 * Heap. We allocate through the STANDARD ISO façade (FROM Storage IMPORT
 * ALLOCATE, DEALLOCATE) and confirm the M2 Heap engine actually serviced the
 * request — Heap.BytesInUse moves up on ALLOCATE and back on DEALLOCATE, the
 * memory is zeroed and usable, Available probes through the same heap, and the
 * heap structure stays valid. This is the heap_synthesis layering working end
 * to end: Storage (ISO façade) -> Heap (M2 engine) -> VirtualAlloc.
 *
 * EXPECTED:
 * alloc nonnil: Y
 * heap grew: Y
 * zeroed: Y
 * usable: Y
 * freed nil: Y
 * heap back: Y
 * avail: Y
 * valid: Y
 *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE, Available;
FROM Heap IMPORT BytesInUse, Validate;
FROM StrIO IMPORT WriteString, WriteLn;

TYPE CardPtr = POINTER TO CARDINAL;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR p: ADDRESS; pc: CardPtr; before: CARDINAL;
BEGIN
  before := BytesInUse();
  ALLOCATE(p, 1000);
  WriteString("alloc nonnil: "); YN(p # NIL); WriteLn;
  WriteString("heap grew: "); YN(BytesInUse() > before); WriteLn;   (* the M2 Heap serviced it *)

  pc := CAST(CardPtr, p);
  WriteString("zeroed: "); YN(pc^ = 0); WriteLn;
  pc^ := 12345;
  WriteString("usable: "); YN(pc^ = 12345); WriteLn;

  DEALLOCATE(p, 1000);
  WriteString("freed nil: "); YN(p = NIL); WriteLn;
  WriteString("heap back: "); YN(BytesInUse() = before); WriteLn;

  WriteString("avail: "); YN(Available(4096)); WriteLn;
  WriteString("valid: "); YN(Validate()); WriteLn
END T90237StorageHeap.
