IMPLEMENTATION MODULE StrMap;

(* Open addressing with linear probing and tombstones. The table is a power-of-
   two slot array; it grows (rehashing, which also clears tombstones) when the
   used+tomb fill reaches 3/4, so an empty slot — hence loop termination — is
   guaranteed. Keys are heap-copied and owned; the same key handle is carried
   across a rehash without re-copying. *)

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
IMPORT Hashing;

CONST
  Empty = 0; Used = 1; Tomb = 2;
  InitCap = 8;
  MaxIdx = 268435455;

TYPE
  StrMap = POINTER TO MRec;
  Slot = RECORD
    state: CARDINAL;     (* Empty / Used / Tomb *)
    hash:  CARDINAL;
    key:   ADDRESS;      (* -> heap ARRAY OF CHAR (klen chars) *)
    klen:  CARDINAL;
    value: CARDINAL;
  END;
  PSlots = POINTER TO ARRAY [0..MaxIdx] OF Slot;
  PKey   = POINTER TO ARRAY [0..MaxIdx] OF CHAR;
  MRec = RECORD slots: ADDRESS; cap, used, tomb: CARDINAL END;

PROCEDURE StrLen (s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END; RETURN i END StrLen;

PROCEDURE CopyKey (s: ARRAY OF CHAR; slen: CARDINAL): ADDRESS;
  VAR a: ADDRESS; p: PKey; i: CARDINAL;
BEGIN
  a := NIL; ALLOCATE(a, slen * SIZE(CHAR));
  p := CAST(PKey, a);
  i := 0; WHILE i < slen DO p^[i] := s[i]; INC(i) END;
  RETURN a
END CopyKey;

PROCEDURE KeyEq (VAR slot: Slot; s: ARRAY OF CHAR): BOOLEAN;
  VAR p: PKey; i: CARDINAL;
BEGIN
  p := CAST(PKey, slot.key); i := 0;
  WHILE i < slot.klen DO IF p^[i] # s[i] THEN RETURN FALSE END; INC(i) END;
  RETURN TRUE
END KeyEq;

(* place an already-owned key (no copy) into the current table *)
PROCEDURE ReinsertRaw (m: StrMap; h, klen, value: CARDINAL; key: ADDRESS);
  VAR sl: PSlots; mask, i: CARDINAL;
BEGIN
  sl := CAST(PSlots, m^.slots); mask := m^.cap - 1; i := h BAND mask;
  WHILE sl^[i].state = Used DO i := (i + 1) BAND mask END;
  sl^[i].state := Used; sl^[i].hash := h; sl^[i].key := key;
  sl^[i].klen := klen; sl^[i].value := value;
  INC(m^.used)
END ReinsertRaw;

PROCEDURE Grow (m: StrMap);
  VAR oldsl, nsl: PSlots; oldcap, ncap, i: CARDINAL; na, old: ADDRESS;
BEGIN
  ncap := m^.cap * 2; IF ncap < InitCap THEN ncap := InitCap END;
  oldcap := m^.cap;
  na := NIL; ALLOCATE(na, ncap * SIZE(Slot));
  nsl := CAST(PSlots, na);
  i := 0; WHILE i < ncap DO nsl^[i].state := Empty; nsl^[i].key := NIL; INC(i) END;
  IF m^.slots # NIL THEN
    oldsl := CAST(PSlots, m^.slots);
    m^.slots := na; m^.cap := ncap; m^.used := 0; m^.tomb := 0;
    i := 0;
    WHILE i < oldcap DO
      IF oldsl^[i].state = Used THEN
        ReinsertRaw(m, oldsl^[i].hash, oldsl^[i].klen, oldsl^[i].value, oldsl^[i].key)
      END;
      INC(i)
    END;
    old := CAST(ADDRESS, oldsl); DEALLOCATE(old, oldcap * SIZE(Slot))
  ELSE
    m^.slots := na; m^.cap := ncap; m^.used := 0; m^.tomb := 0
  END
END Grow;

PROCEDURE Create (): StrMap;
  VAR m: StrMap; a: ADDRESS;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(MRec)); m := CAST(StrMap, a);
  m^.slots := NIL; m^.cap := 0; m^.used := 0; m^.tomb := 0;
  Grow(m);
  RETURN m
END Create;

PROCEDURE FreeKeys (m: StrMap);
  VAR sl: PSlots; i: CARDINAL;
BEGIN
  IF m^.slots = NIL THEN RETURN END;
  sl := CAST(PSlots, m^.slots); i := 0;
  WHILE i < m^.cap DO
    IF (sl^[i].state = Used) AND (sl^[i].key # NIL) THEN
      DEALLOCATE(sl^[i].key, sl^[i].klen * SIZE(CHAR))
    END;
    sl^[i].state := Empty; sl^[i].key := NIL;
    INC(i)
  END
END FreeKeys;

PROCEDURE Clear (m: StrMap);
BEGIN FreeKeys(m); m^.used := 0; m^.tomb := 0 END Clear;

PROCEDURE Dispose (VAR m: StrMap);
  VAR old, pm: ADDRESS;
BEGIN
  IF m # NIL THEN
    FreeKeys(m);
    IF m^.slots # NIL THEN old := m^.slots; DEALLOCATE(old, m^.cap * SIZE(Slot)) END;
    pm := CAST(ADDRESS, m); DEALLOCATE(pm, SIZE(MRec)); m := NIL
  END
END Dispose;

PROCEDURE Count (m: StrMap): CARDINAL; BEGIN RETURN m^.used END Count;

(* find the USED slot holding key (-> TRUE,idx) or the first insertable slot
   (-> FALSE,idx: an empty slot, or the first tombstone seen) *)
PROCEDURE FindSlot (m: StrMap; s: ARRAY OF CHAR; slen, h: CARDINAL; VAR idx: CARDINAL): BOOLEAN;
  VAR sl: PSlots; mask, i, firstTomb: CARDINAL; haveTomb: BOOLEAN;
BEGIN
  sl := CAST(PSlots, m^.slots); mask := m^.cap - 1;
  i := h BAND mask; haveTomb := FALSE; firstTomb := 0;
  LOOP
    IF sl^[i].state = Empty THEN
      IF haveTomb THEN idx := firstTomb ELSE idx := i END;
      RETURN FALSE
    ELSIF sl^[i].state = Tomb THEN
      IF NOT haveTomb THEN haveTomb := TRUE; firstTomb := i END
    ELSE
      IF (sl^[i].hash = h) AND (sl^[i].klen = slen) AND KeyEq(sl^[i], s) THEN
        idx := i; RETURN TRUE
      END
    END;
    i := (i + 1) BAND mask
  END
END FindSlot;

PROCEDURE Put (m: StrMap; key: ARRAY OF CHAR; value: CARDINAL);
  VAR sl: PSlots; slen, h, idx: CARDINAL; found: BOOLEAN;
BEGIN
  IF (m^.used + m^.tomb) * 4 >= m^.cap * 3 THEN Grow(m) END;
  slen := StrLen(key); h := Hashing.FNV1a(key);
  found := FindSlot(m, key, slen, h, idx);
  sl := CAST(PSlots, m^.slots);
  IF found THEN
    sl^[idx].value := value
  ELSE
    IF sl^[idx].state = Tomb THEN DEC(m^.tomb) END;
    sl^[idx].state := Used; sl^[idx].hash := h;
    sl^[idx].key := CopyKey(key, slen); sl^[idx].klen := slen;
    sl^[idx].value := value; INC(m^.used)
  END
END Put;

PROCEDURE Get (m: StrMap; key: ARRAY OF CHAR; VAR value: CARDINAL): BOOLEAN;
  VAR sl: PSlots; idx: CARDINAL;
BEGIN
  IF FindSlot(m, key, StrLen(key), Hashing.FNV1a(key), idx) THEN
    sl := CAST(PSlots, m^.slots); value := sl^[idx].value; RETURN TRUE
  END;
  RETURN FALSE
END Get;

PROCEDURE Has (m: StrMap; key: ARRAY OF CHAR): BOOLEAN;
  VAR idx: CARDINAL;
BEGIN RETURN FindSlot(m, key, StrLen(key), Hashing.FNV1a(key), idx) END Has;

PROCEDURE Remove (m: StrMap; key: ARRAY OF CHAR): BOOLEAN;
  VAR sl: PSlots; idx: CARDINAL;
BEGIN
  IF FindSlot(m, key, StrLen(key), Hashing.FNV1a(key), idx) THEN
    sl := CAST(PSlots, m^.slots);
    IF sl^[idx].key # NIL THEN DEALLOCATE(sl^[idx].key, sl^[idx].klen * SIZE(CHAR)) END;
    sl^[idx].state := Tomb; sl^[idx].key := NIL;
    DEC(m^.used); INC(m^.tomb); RETURN TRUE
  END;
  RETURN FALSE
END Remove;

PROCEDURE Iterate (m: StrMap): Iterator;
BEGIN RETURN 0 END Iterate;

PROCEDURE Next (m: StrMap; VAR it: Iterator; VAR key: ARRAY OF CHAR; VAR value: CARDINAL): BOOLEAN;
  VAR sl: PSlots; p: PKey; i, j: CARDINAL;
BEGIN
  sl := CAST(PSlots, m^.slots); i := it;
  WHILE i < m^.cap DO
    IF sl^[i].state = Used THEN
      (* copy the key, always reserving the last cell for a terminator so the
         returned buffer is NUL-terminated even if the key was too long *)
      p := CAST(PKey, sl^[i].key); j := 0;
      WHILE (j < sl^[i].klen) AND (j < HIGH(key)) DO key[j] := p^[j]; INC(j) END;
      key[j] := 0C;
      value := sl^[i].value; it := i + 1; RETURN TRUE
    END;
    INC(i)
  END;
  it := i; RETURN FALSE
END Next;

END StrMap.
