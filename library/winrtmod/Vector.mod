IMPLEMENTATION MODULE Vector;

(* A growable array of CARDINAL cells over Storage. The cell block grows by
   doubling; the handle is a small heap record. Designators read/write through
   a local PData (an ISO-legal variable), never through a function result. *)

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;

CONST MaxIdx = 268435455;   (* cell index bound for the cast view (256M cells) *)

TYPE
  Vector = POINTER TO VRec;
  VRec = RECORD len, cap: CARDINAL; data: ADDRESS END;
  PData = POINTER TO ARRAY [0..MaxIdx] OF CARDINAL;

PROCEDURE Reserve (v: Vector; cap: CARDINAL);
  VAR nc, i: CARDINAL; na, old: ADDRESS; s, d: PData;
BEGIN
  IF cap <= v^.cap THEN RETURN END;
  nc := v^.cap; IF nc < 4 THEN nc := 4 END;
  WHILE nc < cap DO nc := nc * 2 END;
  na := NIL; ALLOCATE(na, nc * 8);
  d := CAST(PData, na);
  IF v^.data # NIL THEN
    s := CAST(PData, v^.data);
    i := 0; WHILE i < v^.len DO d^[i] := s^[i]; INC(i) END;
    old := v^.data; DEALLOCATE(old, v^.cap * 8)
  END;
  v^.data := na; v^.cap := nc
END Reserve;

PROCEDURE Create (): Vector;
  VAR v: Vector; a: ADDRESS;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(VRec)); v := CAST(Vector, a);
  v^.len := 0; v^.cap := 0; v^.data := NIL;
  RETURN v
END Create;

PROCEDURE CreateCap (cap: CARDINAL): Vector;
  VAR v: Vector;
BEGIN v := Create(); Reserve(v, cap); RETURN v END CreateCap;

PROCEDURE Dispose (VAR v: Vector);
  VAR pv: ADDRESS;
BEGIN
  IF v # NIL THEN
    IF v^.data # NIL THEN DEALLOCATE(v^.data, v^.cap * 8) END;
    pv := CAST(ADDRESS, v); DEALLOCATE(pv, SIZE(VRec)); v := NIL
  END
END Dispose;

PROCEDURE Length   (v: Vector): CARDINAL; BEGIN RETURN v^.len END Length;
PROCEDURE Capacity (v: Vector): CARDINAL; BEGIN RETURN v^.cap END Capacity;
PROCEDURE IsEmpty  (v: Vector): BOOLEAN;  BEGIN RETURN v^.len = 0 END IsEmpty;
PROCEDURE Clear    (v: Vector);           BEGIN v^.len := 0 END Clear;

PROCEDURE Push (v: Vector; x: CARDINAL);
  VAR d: PData;
BEGIN
  Reserve(v, v^.len + 1); d := CAST(PData, v^.data);
  d^[v^.len] := x; INC(v^.len)
END Push;

PROCEDURE Pop (v: Vector): CARDINAL;
  VAR d: PData;
BEGIN
  IF v^.len = 0 THEN RETURN 0 END;
  DEC(v^.len); d := CAST(PData, v^.data); RETURN d^[v^.len]
END Pop;

PROCEDURE Last (v: Vector): CARDINAL;
  VAR d: PData;
BEGIN
  IF v^.len = 0 THEN RETURN 0 END;
  d := CAST(PData, v^.data); RETURN d^[v^.len - 1]
END Last;

PROCEDURE Get (v: Vector; i: CARDINAL): CARDINAL;
  VAR d: PData;
BEGIN
  IF i >= v^.len THEN RETURN 0 END;
  d := CAST(PData, v^.data); RETURN d^[i]
END Get;

PROCEDURE Set (v: Vector; i, x: CARDINAL);
  VAR d: PData;
BEGIN
  IF i < v^.len THEN d := CAST(PData, v^.data); d^[i] := x END
END Set;

PROCEDURE Insert (v: Vector; i, x: CARDINAL);
  VAR d: PData; j: CARDINAL;
BEGIN
  IF i > v^.len THEN i := v^.len END;
  Reserve(v, v^.len + 1); d := CAST(PData, v^.data);
  j := v^.len;
  WHILE j > i DO d^[j] := d^[j - 1]; DEC(j) END;
  d^[i] := x; INC(v^.len)
END Insert;

PROCEDURE Remove (v: Vector; i: CARDINAL): CARDINAL;
  VAR d: PData; r, j: CARDINAL;
BEGIN
  IF i >= v^.len THEN RETURN 0 END;
  d := CAST(PData, v^.data); r := d^[i];
  j := i; WHILE j + 1 < v^.len DO d^[j] := d^[j + 1]; INC(j) END;
  DEC(v^.len); RETURN r
END Remove;

PROCEDURE Swap (v: Vector; i, j: CARDINAL);
  VAR d: PData; t: CARDINAL;
BEGIN
  IF (i < v^.len) AND (j < v^.len) THEN
    d := CAST(PData, v^.data); t := d^[i]; d^[i] := d^[j]; d^[j] := t
  END
END Swap;

END Vector.
