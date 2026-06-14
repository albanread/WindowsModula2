MODULE T90239M2HeapForce;
(*
 * Group 90 — M2WINRT runtime: --m2-heap force-links the Heap module even though
 * this program never IMPORTs it. The codegen rewrites NEW/DISPOSE to call
 * Heap.Alloc/Heap.Free, and the driver pulls Heap into the link automatically.
 * Build a 10-node linked list with NEW (sum 1..10 = 55), then free every node
 * with DISPOSE — all on the self-hosted M2 heap, with no Heap import in sight.
 *
 * EXPECTED:
 * sum: Y
 * freed: Y
 *)
FROM StrIO IMPORT WriteString, WriteLn;

TYPE
  PNode = POINTER TO Node;
  Node  = RECORD val: CARDINAL; next: PNode END;

VAR head, p: PNode; i, sum: CARDINAL;
BEGIN
  head := NIL;
  i := 1;
  WHILE i <= 10 DO
    NEW(p); p^.val := i; p^.next := head; head := p; i := i + 1
  END;

  sum := 0; p := head;
  WHILE p # NIL DO sum := sum + p^.val; p := p^.next END;
  WriteString("sum: "); IF sum = 55 THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;

  WHILE head # NIL DO p := head; head := head^.next; DISPOSE(p) END;
  WriteString("freed: Y"); WriteLn
END T90239M2HeapForce.
