MODULE T90238M2HeapNew;
(*
 * Group 90 — M2WINRT runtime: NEW/DISPOSE routed through the self-hosted M2
 * Heap (compiled with --m2-heap; the harness uses run_test_m2heap). Allocating
 * with the NEW builtin must be serviced by the M2 Heap engine — Heap.BytesInUse
 * moves up on NEW and back on DISPOSE — the object is usable, and the heap stays
 * structurally valid. Without --m2-heap, NEW would use the Rust nm2_alloc and
 * Heap.BytesInUse would stay 0.
 *
 * EXPECTED:
 * new uses m2 heap: Y
 * usable: Y
 * disposed: Y
 * valid: Y
 *)
FROM Heap IMPORT BytesInUse, Validate;
FROM StrIO IMPORT WriteString, WriteLn;

TYPE
  Rec  = RECORD a, b, c: CARDINAL END;
  PRec = POINTER TO Rec;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR p: PRec; before, during: CARDINAL;
BEGIN
  before := BytesInUse();
  NEW(p);
  during := BytesInUse();
  p^.a := 111; p^.b := 222; p^.c := 333;
  WriteString("new uses m2 heap: "); YN(during > before); WriteLn;
  WriteString("usable: "); YN((p^.a = 111) AND (p^.c = 333)); WriteLn;
  DISPOSE(p);
  WriteString("disposed: "); YN(BytesInUse() = before); WriteLn;
  WriteString("valid: "); YN(Validate()); WriteLn
END T90238M2HeapNew.
