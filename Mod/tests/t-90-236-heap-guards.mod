MODULE T90236HeapGuards;
(*
 * Group 90 — M2WINRT runtime: heap safety guards.
 *   - An impossibly large request must fail cleanly with p := NIL rather than
 *     wrapping the 16-byte rounding to a tiny block (heap-overflow) or driving
 *     the zeroing loop across all of memory.
 *   - A double-free must be a safe no-op: the second Deallocate must not
 *     re-insert an already-free block onto the free list or underflow the
 *     in-use byte count. The structure must stay valid throughout.
 *
 * EXPECTED:
 * huge nil: Y
 * max nil: Y
 * normal ok: Y
 * after free inuse0: Y
 * double-free safe: Y
 * valid: Y
 *)
FROM SYSTEM IMPORT ADDRESS;
FROM Heap IMPORT Allocate, Deallocate, BytesInUse, Validate;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR p, q: ADDRESS;
BEGIN
  (* overflow guards: both wrap-inducing bands must return NIL *)
  Allocate(p, 0FFFFFFFFFFFFFFF0H);            (* lower band: blockNeed would wrap to 0 *)
  WriteString("huge nil: "); YN(p = NIL); WriteLn;
  Allocate(p, MAX(CARDINAL));                 (* top band: need would collapse below 16 *)
  WriteString("max nil: "); YN(p = NIL); WriteLn;

  (* a normal allocation still works, and frees back to zero in use *)
  Allocate(p, 100);
  WriteString("normal ok: "); YN(p # NIL); WriteLn;
  q := p;                                     (* keep a stale alias for the double-free *)
  Deallocate(p, 100);
  WriteString("after free inuse0: "); YN(BytesInUse() = 0); WriteLn;

  (* double-free through the stale alias must be a no-op *)
  Deallocate(q, 100);
  WriteString("double-free safe: "); YN((BytesInUse() = 0) AND (q = NIL)); WriteLn;
  WriteString("valid: "); YN(Validate()); WriteLn
END T90236HeapGuards.
