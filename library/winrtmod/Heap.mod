IMPLEMENTATION MODULE Heap;

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM System_Memory IMPORT VirtualAlloc, VirtualFree;

CONST
  Hdr        = 16;                    (* per-block header: size word + prevSize word *)
  MinBlock   = 32;                    (* Hdr + 16-byte minimum payload (free-list links) *)
  AllocFlag  = 1;
  SizeMask   = 0FFFFFFFFFFFFFFF0H;    (* clears the low-4 flag bits (sizes are 16-granular) *)
  ChunkMeta  = 16;                    (* chunkNext + chunkSize at the chunk head *)
  Sentinel   = 16;                    (* the tail sentinel block *)
  PageMask   = 0FFFFFFFFFFFF0000H;    (* round up to 64 KiB (VirtualAlloc granularity) *)
  PageUp     = 0FFFFH;
  DefaultChunk = 100000H;             (* 1 MiB chunks *)
  MEM_COMMIT_RESERVE = 3000H;
  MEM_RELEASE        = 8000H;
  PAGE_READWRITE     = 4;

TYPE CardPtr = POINTER TO CARDINAL;

VAR
  gFirstChunk: ADDRESS;   (* singly-linked list of OS chunks *)
  gFreeHead:   ADDRESS;   (* doubly-linked (NIL-terminated) free list *)
  gInUse:      CARDINAL;

(* ---- raw word / address helpers ---- *)
PROCEDURE Wget (a: ADDRESS): CARDINAL;
  VAR pc: CardPtr;
BEGIN pc := CAST(CardPtr, a); RETURN pc^ END Wget;
PROCEDURE Wput (a: ADDRESS; v: CARDINAL);
  VAR pc: CardPtr;
BEGIN pc := CAST(CardPtr, a); pc^ := v END Wput;
PROCEDURE Off  (a: ADDRESS; n: CARDINAL): ADDRESS; BEGIN RETURN CAST(ADDRESS, CAST(CARDINAL, a) + n) END Off;
PROCEDURE OffN (a: ADDRESS; n: CARDINAL): ADDRESS; BEGIN RETURN CAST(ADDRESS, CAST(CARDINAL, a) - n) END OffN;

(* ---- block field helpers (b = block start) ---- *)
PROCEDURE BlkSize (b: ADDRESS): CARDINAL;     BEGIN RETURN Wget(b) BAND SizeMask END BlkSize;
PROCEDURE BlkAlloc (b: ADDRESS): BOOLEAN;     BEGIN RETURN (Wget(b) BAND AllocFlag) # 0 END BlkAlloc;
PROCEDURE BlkPrev (b: ADDRESS): CARDINAL;     BEGIN RETURN Wget(Off(b, 8)) END BlkPrev;

PROCEDURE SetHdr (b: ADDRESS; size: CARDINAL; alloc: BOOLEAN; prevSize: CARDINAL);
BEGIN
  IF alloc THEN Wput(b, size BOR AllocFlag) ELSE Wput(b, size) END;
  Wput(Off(b, 8), prevSize)
END SetHdr;

(* ---- free list (links live in the free block's payload: +16 next, +24 prev) ---- *)
PROCEDURE FNext (b: ADDRESS): ADDRESS;        BEGIN RETURN CAST(ADDRESS, Wget(Off(b, 16))) END FNext;
PROCEDURE FPrev (b: ADDRESS): ADDRESS;        BEGIN RETURN CAST(ADDRESS, Wget(Off(b, 24))) END FPrev;
PROCEDURE SetFNext (b, x: ADDRESS);           BEGIN Wput(Off(b, 16), CAST(CARDINAL, x)) END SetFNext;
PROCEDURE SetFPrev (b, x: ADDRESS);           BEGIN Wput(Off(b, 24), CAST(CARDINAL, x)) END SetFPrev;

PROCEDURE InsertFree (b: ADDRESS);
BEGIN
  SetFNext(b, gFreeHead); SetFPrev(b, NIL);
  IF gFreeHead # NIL THEN SetFPrev(gFreeHead, b) END;
  gFreeHead := b
END InsertFree;

PROCEDURE RemoveFree (b: ADDRESS);
BEGIN
  IF FPrev(b) # NIL THEN SetFNext(FPrev(b), FNext(b)) ELSE gFreeHead := FNext(b) END;
  IF FNext(b) # NIL THEN SetFPrev(FNext(b), FPrev(b)) END
END RemoveFree;

PROCEDURE FindFit (need: CARDINAL): ADDRESS;
  VAR b: ADDRESS;
BEGIN
  b := gFreeHead;
  WHILE b # NIL DO
    IF BlkSize(b) >= need THEN RETURN b END;
    b := FNext(b)
  END;
  RETURN NIL
END FindFit;

PROCEDURE RoundUp (n, mask, up: CARDINAL): CARDINAL;
BEGIN RETURN (n + up) BAND mask END RoundUp;

PROCEDURE GrowHeap (needBlock: CARDINAL): BOOLEAN;
  VAR base, firstBlk, sent: ADDRESS; bytes, fbSize: CARDINAL;
BEGIN
  bytes := DefaultChunk;
  IF needBlock + ChunkMeta + Sentinel > bytes THEN
    bytes := RoundUp(needBlock + ChunkMeta + Sentinel, PageMask, PageUp)
  END;
  base := VirtualAlloc(NIL, bytes, MEM_COMMIT_RESERVE, PAGE_READWRITE);
  IF base = NIL THEN RETURN FALSE END;
  Wput(base, CAST(CARDINAL, gFirstChunk));   (* chunkNext *)
  Wput(Off(base, 8), bytes);                 (* chunkSize  *)
  gFirstChunk := base;
  firstBlk := Off(base, ChunkMeta);
  fbSize := bytes - ChunkMeta - Sentinel;
  SetHdr(firstBlk, fbSize, FALSE, 0);        (* one big free block, no predecessor *)
  sent := Off(base, bytes - Sentinel);
  SetHdr(sent, Sentinel, TRUE, fbSize);      (* allocated tail sentinel stops coalescing *)
  InsertFree(firstBlk);
  RETURN TRUE
END GrowHeap;

PROCEDURE Allocate (VAR p: ADDRESS; size: CARDINAL);
  VAR need, blockNeed, bsize, remSize, i: CARDINAL; b, rem, nb: ADDRESS;
BEGIN
  p := NIL;
  (* Reject any request so large that 16-byte rounding (+15) or the +Hdr step
     would wrap a 64-bit CARDINAL — otherwise we would silently hand back a tiny
     block (heap overflow) or drive the zeroing loop across all of memory. These
     are unsigned wrap checks: when no overflow occurs `need` rounds UP so it is
     always >= size, and blockNeed = need + Hdr > need. *)
  need := RoundUp(size, SizeMask, 15);
  IF need < size THEN RETURN END;                (* size + 15 wrapped *)
  IF need < 16 THEN need := 16 END;
  blockNeed := need + Hdr;
  IF blockNeed < need THEN RETURN END;           (* need + Hdr wrapped *)
  b := FindFit(blockNeed);
  IF b = NIL THEN
    IF NOT GrowHeap(blockNeed) THEN RETURN END;
    b := FindFit(blockNeed)
  END;
  IF b = NIL THEN RETURN END;
  RemoveFree(b);
  bsize := BlkSize(b);
  IF bsize >= blockNeed + MinBlock THEN          (* split: keep the residual as a free block *)
    rem := Off(b, blockNeed);
    remSize := bsize - blockNeed;
    Wput(b, blockNeed BOR AllocFlag);            (* b: now blockNeed, allocated (prevSize kept) *)
    SetHdr(rem, remSize, FALSE, blockNeed);
    nb := Off(rem, remSize);
    Wput(Off(nb, 8), remSize);                   (* the block after rem learns its new prevSize *)
    InsertFree(rem)
  ELSE
    Wput(b, bsize BOR AllocFlag)                 (* take the whole block *)
  END;
  gInUse := gInUse + BlkSize(b);
  p := Off(b, Hdr);
  i := 0;                                          (* zero the usable payload *)
  WHILE i < need DO Wput(Off(p, i), 0); i := i + 8 END
END Allocate;

PROCEDURE Deallocate (VAR p: ADDRESS; size: CARDINAL);
  VAR b, nextB, prevB, nb: ADDRESS; ps: CARDINAL;
BEGIN
  IF p = NIL THEN RETURN END;
  b := OffN(p, Hdr);
  (* Double-free / non-allocated block: the alloc flag is already clear, so a
     second free would re-insert a listed block and underflow gInUse. Reject it
     as a safe no-op before touching any accounting or the free list. *)
  IF NOT BlkAlloc(b) THEN p := NIL; RETURN END;
  gInUse := gInUse - BlkSize(b);
  Wput(b, BlkSize(b));                           (* mark free (clear the alloc flag) *)
  nextB := Off(b, BlkSize(b));                   (* coalesce forward (sentinel is allocated -> stops) *)
  IF NOT BlkAlloc(nextB) THEN
    RemoveFree(nextB);
    Wput(b, BlkSize(b) + BlkSize(nextB))
  END;
  ps := BlkPrev(b);                              (* coalesce backward *)
  IF ps # 0 THEN
    prevB := OffN(b, ps);
    IF NOT BlkAlloc(prevB) THEN
      RemoveFree(prevB);
      Wput(prevB, BlkSize(prevB) + BlkSize(b));
      b := prevB
    END
  END;
  nb := Off(b, BlkSize(b));                       (* the following block learns the merged prevSize *)
  Wput(Off(nb, 8), BlkSize(b));
  InsertFree(b);
  p := NIL
END Deallocate;

(* Value-returning entry points NEW/DISPOSE call under --m2-heap. *)
PROCEDURE Alloc (size: CARDINAL): ADDRESS;
  VAR p: ADDRESS;
BEGIN
  Allocate(p, size);
  RETURN p
END Alloc;

PROCEDURE Free (p: ADDRESS);
  VAR q: ADDRESS;
BEGIN
  q := p;
  Deallocate(q, 0)
END Free;

PROCEDURE BytesInUse (): CARDINAL;
BEGIN RETURN gInUse END BytesInUse;

PROCEDURE OnFreeList (b: ADDRESS): BOOLEAN;
  VAR f: ADDRESS;
BEGIN
  f := gFreeHead;
  WHILE f # NIL DO IF f = b THEN RETURN TRUE END; f := FNext(f) END;
  RETURN FALSE
END OnFreeList;

PROCEDURE Validate (): BOOLEAN;
  VAR chunk, b, sent: ADDRESS; cbytes, walked, prev: CARDINAL;
BEGIN
  chunk := gFirstChunk;
  WHILE chunk # NIL DO
    cbytes := Wget(Off(chunk, 8));
    b := Off(chunk, ChunkMeta);
    sent := Off(chunk, cbytes - Sentinel);
    walked := ChunkMeta;
    prev := 0;
    WHILE b # sent DO
      IF BlkSize(b) < MinBlock THEN RETURN FALSE END;          (* every real block >= MinBlock *)
      IF (BlkSize(b) BAND 0FH) # 0 THEN RETURN FALSE END;      (* 16-granular *)
      IF BlkPrev(b) # prev THEN RETURN FALSE END;              (* prevSize chain intact *)
      IF (NOT BlkAlloc(b)) # OnFreeList(b) THEN RETURN FALSE END; (* free <=> on free list *)
      prev := BlkSize(b);
      walked := walked + BlkSize(b);
      b := Off(b, BlkSize(b));
      IF walked > cbytes THEN RETURN FALSE END                 (* ran past the sentinel *)
    END;
    IF NOT BlkAlloc(sent) THEN RETURN FALSE END;               (* sentinel stays allocated *)
    IF BlkPrev(sent) # prev THEN RETURN FALSE END;
    IF walked + Sentinel # cbytes THEN RETURN FALSE END;       (* blocks exactly fill the chunk *)
    chunk := CAST(ADDRESS, Wget(chunk))
  END;
  RETURN TRUE
END Validate;

BEGIN
  gFirstChunk := NIL; gFreeHead := NIL; gInUse := 0
END Heap.
