MODULE T90235HeapTorture;
(*
 * Group 90 — M2WINRT runtime: heap torture test.
 * Drives the self-hosted M2 Heap through a long pseudo-random alloc/free mix
 * (Park-Miller LCG, no overflow) over 64 slots and 4000 rounds. Every live
 * block carries a distinct byte pattern keyed to its size and a per-slot seed;
 * before each free the block is re-checked, so any split/coalesce that
 * corrupts a neighbour shows up as a pattern mismatch. Validate() runs every
 * 200 rounds. At the end every survivor is checked and freed, and the heap
 * must report zero bytes in use and a clean structure.
 *
 * EXPECTED:
 * corrupt: N
 * validfail: N
 * final ok: Y
 * inuse0: Y
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

VAR
  p:   ARRAY [0..63] OF ADDRESS;
  sz:  ARRAY [0..63] OF CARDINAL;
  pat: ARRAY [0..63] OF CARDINAL;
  seed, r, i, idx, size, round: CARDINAL;
  corrupt, validfail, finalok: BOOLEAN;
BEGIN
  i := 0; WHILE i < 64 DO p[i] := NIL; i := i + 1 END;
  seed := 12345;
  corrupt := FALSE; validfail := FALSE;
  round := 0;
  WHILE round < 4000 DO
    seed := (seed * 16807) MOD 2147483647;     (* Park-Miller; stays < 2^31 *)
    r := seed;
    idx := r MOD 64;
    IF p[idx] = NIL THEN
      size := 1 + ((r DIV 64) MOD 1000);
      Allocate(p[idx], size);
      sz[idx] := size; pat[idx] := r BAND 0FFH;
      Fill(p[idx], size, pat[idx])
    ELSE
      IF NOT Check(p[idx], sz[idx], pat[idx]) THEN corrupt := TRUE END;
      Deallocate(p[idx], 0); p[idx] := NIL
    END;
    IF (round MOD 200) = 0 THEN
      IF NOT Validate() THEN validfail := TRUE END
    END;
    round := round + 1
  END;
  WriteString("corrupt: "); YN(corrupt); WriteLn;
  WriteString("validfail: "); YN(validfail); WriteLn;

  (* drain: check then free every survivor *)
  finalok := TRUE; i := 0;
  WHILE i < 64 DO
    IF p[i] # NIL THEN
      IF NOT Check(p[i], sz[i], pat[i]) THEN finalok := FALSE END;
      Deallocate(p[i], 0); p[i] := NIL
    END;
    i := i + 1
  END;
  WriteString("final ok: "); YN(finalok); WriteLn;
  WriteString("inuse0: "); YN(BytesInUse() = 0); WriteLn;
  WriteString("validend: "); YN(Validate()); WriteLn
END T90235HeapTorture.
