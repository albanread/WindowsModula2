IMPLEMENTATION MODULE MemUtils;

FROM SYSTEM IMPORT ADDRESS, CAST;

TYPE
  BytePtr = POINTER TO ARRAY [0 .. MAX(CARDINAL) - 1] OF BYTE;

VAR
  gSink: CARDINAL;   (* anchors SecureZeroMem's wipe against dead-store removal *)

(* ---- shared helpers ---------------------------------------------------- *)

(* Decompose the low `width` bytes of `val` into pat[0..width-1], little-endian. *)
PROCEDURE Decompose (val: CARDINAL; width: CARDINAL; VAR pat: ARRAY OF BYTE);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE i < width DO
    pat[i] := VAL(BYTE, val BAND 0FFH);
    val := val SHR 8;
    INC(i)
  END
END Decompose;

(* Write `count` copies of pat[0..width-1] consecutively from p^[0]. *)
PROCEDURE FillPattern (dest: ADDRESS; count, width: CARDINAL; pat: ARRAY OF BYTE);
  VAR p: BytePtr; i, k, idx: CARDINAL;
BEGIN
  p := CAST(BytePtr, dest);
  idx := 0; i := 0;
  WHILE i < count DO
    k := 0;
    WHILE k < width DO
      p^[idx] := pat[k]; INC(idx); INC(k)
    END;
    INC(i)
  END
END FillPattern;

(* ELEMENT index of first element whose `width` bytes equal pat (eq=TRUE) or
   differ from pat (eq=FALSE). Returns `count` if none (and if count=0). *)
PROCEDURE ScanPattern (dest: ADDRESS; count, width: CARDINAL;
                       pat: ARRAY OF BYTE; eq: BOOLEAN): CARDINAL;
  VAR p: BytePtr; i, k, base: CARDINAL; matches: BOOLEAN;
BEGIN
  p := CAST(BytePtr, dest);
  i := 0;
  WHILE i < count DO
    base := i * width;
    matches := TRUE; k := 0;
    WHILE matches AND (k < width) DO
      IF p^[base + k] # pat[k] THEN matches := FALSE END;
      INC(k)
    END;
    IF matches = eq THEN RETURN i END;
    INC(i)
  END;
  RETURN count
END ScanPattern;

(* ---- Fill -------------------------------------------------------------- *)

PROCEDURE FillMemBYTE (dest: ADDRESS; numBytes: CARDINAL; db: BYTE);
  VAR p: BytePtr; i: CARDINAL;
BEGIN
  p := CAST(BytePtr, dest); i := 0;
  WHILE i < numBytes DO p^[i] := db; INC(i) END
END FillMemBYTE;

PROCEDURE FillMemWORD (dest: ADDRESS; numWords: CARDINAL; dw: CARDINAL);
  VAR pat: ARRAY [0 .. 1] OF BYTE;
BEGIN
  Decompose(dw, 2, pat); FillPattern(dest, numWords, 2, pat)
END FillMemWORD;

PROCEDURE FillMemDWORD (dest: ADDRESS; numDwords: CARDINAL; dd: CARDINAL);
  VAR pat: ARRAY [0 .. 3] OF BYTE;
BEGIN
  Decompose(dd, 4, pat); FillPattern(dest, numDwords, 4, pat)
END FillMemDWORD;

PROCEDURE FillMemQWORD (dest: ADDRESS; numQwords: CARDINAL; dq: CARDINAL);
  VAR pat: ARRAY [0 .. 7] OF BYTE;
BEGIN
  Decompose(dq, 8, pat); FillPattern(dest, numQwords, 8, pat)
END FillMemQWORD;

PROCEDURE ZeroMem (dest: ADDRESS; numBytes: CARDINAL);
BEGIN
  FillMemBYTE(dest, numBytes, VAL(BYTE, 0))
END ZeroMem;

(* ---- Move -------------------------------------------------------------- *)

PROCEDURE CopyForward (dest, src: ADDRESS; n: CARDINAL);
  VAR pd, ps: BytePtr; i: CARDINAL;
BEGIN
  pd := CAST(BytePtr, dest); ps := CAST(BytePtr, src); i := 0;
  WHILE i < n DO pd^[i] := ps^[i]; INC(i) END
END CopyForward;

PROCEDURE CopyBackward (dest, src: ADDRESS; n: CARDINAL);
  VAR pd, ps: BytePtr; i: CARDINAL;
BEGIN
  pd := CAST(BytePtr, dest); ps := CAST(BytePtr, src); i := n;
  WHILE i > 0 DO DEC(i); pd^[i] := ps^[i] END
END CopyBackward;

PROCEDURE MoveMem (dest, src: ADDRESS; numBytes: CARDINAL);
  VAR aD, aS: CARDINAL;
BEGIN
  IF numBytes = 0 THEN RETURN END;
  aD := CAST(CARDINAL, dest); aS := CAST(CARDINAL, src);
  (* Forward is safe when dest is at/below src, or the regions are disjoint
     (dest is at least numBytes above src). Use subtraction to avoid aS+n
     overflow: aD>aS here, so aD-aS cannot underflow. *)
  IF (aD <= aS) OR (aD - aS >= numBytes) THEN
    CopyForward(dest, src, numBytes)
  ELSE
    CopyBackward(dest, src, numBytes)
  END
END MoveMem;

PROCEDURE MoveMemForward (dest, src: ADDRESS; numBytes: CARDINAL);
BEGIN
  CopyForward(dest, src, numBytes)
END MoveMemForward;

PROCEDURE MoveMemBackward (dest, src: ADDRESS; numBytes: CARDINAL);
BEGIN
  CopyBackward(dest, src, numBytes)
END MoveMemBackward;

(* ---- Scan -------------------------------------------------------------- *)

PROCEDURE ScanMemBYTE (dest: ADDRESS; numBytes: CARDINAL; db: BYTE): CARDINAL;
  VAR p: BytePtr; i: CARDINAL;
BEGIN
  p := CAST(BytePtr, dest); i := 0;
  WHILE i < numBytes DO IF p^[i] = db THEN RETURN i END; INC(i) END;
  RETURN numBytes
END ScanMemBYTE;

PROCEDURE ScanMemNeBYTE (dest: ADDRESS; numBytes: CARDINAL; db: BYTE): CARDINAL;
  VAR p: BytePtr; i: CARDINAL;
BEGIN
  p := CAST(BytePtr, dest); i := 0;
  WHILE i < numBytes DO IF p^[i] # db THEN RETURN i END; INC(i) END;
  RETURN numBytes
END ScanMemNeBYTE;

PROCEDURE ScanMemWORD (dest: ADDRESS; numWords: CARDINAL; dw: CARDINAL): CARDINAL;
  VAR pat: ARRAY [0 .. 1] OF BYTE;
BEGIN
  Decompose(dw, 2, pat); RETURN ScanPattern(dest, numWords, 2, pat, TRUE)
END ScanMemWORD;

PROCEDURE ScanMemNeWORD (dest: ADDRESS; numWords: CARDINAL; dw: CARDINAL): CARDINAL;
  VAR pat: ARRAY [0 .. 1] OF BYTE;
BEGIN
  Decompose(dw, 2, pat); RETURN ScanPattern(dest, numWords, 2, pat, FALSE)
END ScanMemNeWORD;

PROCEDURE ScanMemDWORD (dest: ADDRESS; numDwords: CARDINAL; dd: CARDINAL): CARDINAL;
  VAR pat: ARRAY [0 .. 3] OF BYTE;
BEGIN
  Decompose(dd, 4, pat); RETURN ScanPattern(dest, numDwords, 4, pat, TRUE)
END ScanMemDWORD;

PROCEDURE ScanMemNeDWORD (dest: ADDRESS; numDwords: CARDINAL; dd: CARDINAL): CARDINAL;
  VAR pat: ARRAY [0 .. 3] OF BYTE;
BEGIN
  Decompose(dd, 4, pat); RETURN ScanPattern(dest, numDwords, 4, pat, FALSE)
END ScanMemNeDWORD;

PROCEDURE ScanMemQWORD (dest: ADDRESS; numQwords: CARDINAL; dq: CARDINAL): CARDINAL;
  VAR pat: ARRAY [0 .. 7] OF BYTE;
BEGIN
  Decompose(dq, 8, pat); RETURN ScanPattern(dest, numQwords, 8, pat, TRUE)
END ScanMemQWORD;

PROCEDURE ScanMemNeQWORD (dest: ADDRESS; numQwords: CARDINAL; dq: CARDINAL): CARDINAL;
  VAR pat: ARRAY [0 .. 7] OF BYTE;
BEGIN
  Decompose(dq, 8, pat); RETURN ScanPattern(dest, numQwords, 8, pat, FALSE)
END ScanMemNeQWORD;

(* ---- Compare ----------------------------------------------------------- *)

PROCEDURE CompMem (dest, src: ADDRESS; numBytes: CARDINAL): CARDINAL;
  VAR pd, ps: BytePtr; i: CARDINAL;
BEGIN
  pd := CAST(BytePtr, dest); ps := CAST(BytePtr, src); i := 0;
  WHILE i < numBytes DO IF pd^[i] # ps^[i] THEN RETURN i END; INC(i) END;
  RETURN numBytes
END CompMem;

(* ---- Security hardening ------------------------------------------------ *)

PROCEDURE SecureZeroMem (dest: ADDRESS; numBytes: CARDINAL);
  VAR p: BytePtr; i, sink: CARDINAL;
BEGIN
  p := CAST(BytePtr, dest); i := 0;
  WHILE i < numBytes DO p^[i] := VAL(BYTE, 0); INC(i) END;
  (* Fold the just-written bytes into a module-global, externally observable
     sink. Because gSink's final value could be read by anyone, the compiler
     cannot prove the read-back (hence the zero stores) dead, so the wipe
     survives dead-store elimination. *)
  sink := 0; i := 0;
  WHILE i < numBytes DO sink := sink BXOR ORD(p^[i]); INC(i) END;
  gSink := gSink BXOR sink
END SecureZeroMem;

PROCEDURE EqualCT (a, b: ADDRESS; numBytes: CARDINAL): BOOLEAN;
  VAR pa, pb: BytePtr; i, diff: CARDINAL;
BEGIN
  pa := CAST(BytePtr, a); pb := CAST(BytePtr, b);
  diff := 0; i := 0;
  WHILE i < numBytes DO            (* no early exit: time depends only on n *)
    diff := diff BOR (ORD(pa^[i]) BXOR ORD(pb^[i]));
    INC(i)
  END;
  RETURN diff = 0
END EqualCT;

BEGIN
  gSink := 0
END MemUtils.
