MODULE T90234Heap;
(*
 * Group 90 — M2WINRT runtime: the self-hosted Modula-2 heap.
 * Heap is a boundary-tag free-list allocator written entirely in M2; it draws
 * raw zeroed pages from the OS via VirtualAlloc and carves them itself. This
 * test stresses it the way a heap actually gets used and self-verifies:
 *   - 64 live blocks of distinct sizes, each filled with a distinct byte
 *     pattern; all patterns must survive => no two blocks overlap.
 *   - free every other block, then re-allocate them: the survivors' patterns
 *     must still be intact => split/coalesce never corrupt a neighbour.
 *   - free everything => BytesInUse returns to 0.
 *   - a 500 KB allocation then succeeds inside the 1 MB chunk => the freed
 *     blocks coalesced back into contiguous space.
 * Validate() walks the whole structure (sizes, prevSize chain, sentinels,
 * free-list membership) after each phase.
 *
 * EXPECTED:
 * intact: Y
 * valid: Y
 * odds intact: Y
 * valid2: Y
 * refilled intact: Y
 * inuse0: Y
 * valid3: Y
 * bigok: Y
 * bigfill: Y
 * validend: Y
 *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Heap IMPORT Allocate, Deallocate, BytesInUse, Validate;
FROM StrIO IMPORT WriteString, WriteLn;

TYPE BytePtr = POINTER TO ARRAY [0..0FFFFFFH] OF BYTE;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

PROCEDURE Fill (a: ADDRESS; n, seed: CARDINAL);
  VAR bp: BytePtr; i: CARDINAL;
BEGIN
  bp := CAST(BytePtr, a); i := 0;
  WHILE i < n DO bp^[i] := VAL(BYTE, (seed + i) BAND 0FFH); i := i + 1 END
END Fill;

PROCEDURE Check (a: ADDRESS; n, seed: CARDINAL): BOOLEAN;
  VAR bp: BytePtr; i: CARDINAL;
BEGIN
  bp := CAST(BytePtr, a); i := 0;
  WHILE i < n DO
    IF bp^[i] # VAL(BYTE, (seed + i) BAND 0FFH) THEN RETURN FALSE END;
    i := i + 1
  END;
  RETURN TRUE
END Check;

VAR p: ARRAY [0..63] OF ADDRESS; big: ADDRESS; i: CARDINAL; ok: BOOLEAN;
BEGIN
  (* 1. 64 distinct blocks, distinct patterns -> none may overlap *)
  i := 0;
  WHILE i < 64 DO Allocate(p[i], 8 + i*7); Fill(p[i], 8 + i*7, i*5 + 1); i := i + 1 END;
  ok := TRUE; i := 0;
  WHILE i < 64 DO IF NOT Check(p[i], 8 + i*7, i*5 + 1) THEN ok := FALSE END; i := i + 1 END;
  WriteString("intact: "); YN(ok); WriteLn;
  WriteString("valid: "); YN(Validate()); WriteLn;

  (* 2. free even slots; odd slots must stay intact through the coalescing *)
  i := 0; WHILE i < 64 DO Deallocate(p[i], 0); i := i + 2 END;
  ok := TRUE; i := 1;
  WHILE i < 64 DO IF NOT Check(p[i], 8 + i*7, i*5 + 1) THEN ok := FALSE END; i := i + 2 END;
  WriteString("odds intact: "); YN(ok); WriteLn;
  WriteString("valid2: "); YN(Validate()); WriteLn;

  (* 3. re-allocate the even slots; all 64 patterns must be intact *)
  i := 0; WHILE i < 64 DO Allocate(p[i], 8 + i*7); Fill(p[i], 8 + i*7, i*5 + 1); i := i + 2 END;
  ok := TRUE; i := 0;
  WHILE i < 64 DO IF NOT Check(p[i], 8 + i*7, i*5 + 1) THEN ok := FALSE END; i := i + 1 END;
  WriteString("refilled intact: "); YN(ok); WriteLn;

  (* 4. free all -> nothing in use *)
  i := 0; WHILE i < 64 DO Deallocate(p[i], 0); i := i + 1 END;
  WriteString("inuse0: "); YN(BytesInUse() = 0); WriteLn;
  WriteString("valid3: "); YN(Validate()); WriteLn;

  (* 5. a large block now fits only if the freed blocks recoalesced *)
  Allocate(big, 500000);
  WriteString("bigok: "); YN(big # NIL); WriteLn;
  Fill(big, 500000, 7);
  WriteString("bigfill: "); YN(Check(big, 500000, 7)); WriteLn;
  Deallocate(big, 0);
  WriteString("validend: "); YN(Validate()); WriteLn
END T90234Heap.
