IMPLEMENTATION MODULE StrBuf;

(* A growable CHAR buffer over Storage; capacity doubles. The buffer always has
   `len` chars followed by a 0C terminator, so `cap` holds at least len+1 cells
   and Ptr returns a usable C/ISO string. Designators go through a local PCh
   (a variable), never a function-call result. *)

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;

CONST MaxIdx = 268435455;

TYPE
  StrBuf = POINTER TO Rec;
  Rec = RECORD len, cap: CARDINAL; data: ADDRESS END;
  PCh = POINTER TO ARRAY [0..MaxIdx] OF CHAR;

PROCEDURE Ensure (b: StrBuf; need: CARDINAL);   (* room for `need` chars + terminator *)
  VAR nc, i: CARDINAL; na, old: ADDRESS; s, d: PCh;
BEGIN
  INC(need);                                    (* terminator slot *)
  IF need <= b^.cap THEN RETURN END;
  nc := b^.cap; IF nc < 16 THEN nc := 16 END;
  WHILE nc < need DO nc := nc * 2 END;
  na := NIL; ALLOCATE(na, nc * SIZE(CHAR));
  d := CAST(PCh, na);
  IF b^.data # NIL THEN
    s := CAST(PCh, b^.data);
    i := 0; WHILE i <= b^.len DO d^[i] := s^[i]; INC(i) END;   (* copy incl terminator *)
    old := b^.data; DEALLOCATE(old, b^.cap * SIZE(CHAR))
  ELSE
    d^[0] := 0C
  END;
  b^.data := na; b^.cap := nc
END Ensure;

PROCEDURE Create (): StrBuf;
  VAR b: StrBuf; a: ADDRESS;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(Rec)); b := CAST(StrBuf, a);
  b^.len := 0; b^.cap := 0; b^.data := NIL;
  Ensure(b, 0);
  RETURN b
END Create;

PROCEDURE Dispose (VAR b: StrBuf);
  VAR pb: ADDRESS;
BEGIN
  IF b # NIL THEN
    IF b^.data # NIL THEN DEALLOCATE(b^.data, b^.cap * SIZE(CHAR)) END;
    pb := CAST(ADDRESS, b); DEALLOCATE(pb, SIZE(Rec)); b := NIL
  END
END Dispose;

PROCEDURE Clear (b: StrBuf);
  VAR d: PCh;
BEGIN b^.len := 0; d := CAST(PCh, b^.data); d^[0] := 0C END Clear;

PROCEDURE Length (b: StrBuf): CARDINAL; BEGIN RETURN b^.len END Length;

PROCEDURE AppendCh (b: StrBuf; c: CHAR);
  VAR d: PCh;
BEGIN
  Ensure(b, b^.len + 1); d := CAST(PCh, b^.data);
  d^[b^.len] := c; INC(b^.len); d^[b^.len] := 0C
END AppendCh;

PROCEDURE Append (b: StrBuf; s: ARRAY OF CHAR);
  VAR d: PCh; n, i: CARDINAL;
BEGIN
  n := 0; WHILE (n <= HIGH(s)) AND (s[n] # 0C) DO INC(n) END;
  IF n = 0 THEN RETURN END;
  Ensure(b, b^.len + n); d := CAST(PCh, b^.data);
  i := 0; WHILE i < n DO d^[b^.len + i] := s[i]; INC(i) END;
  INC(b^.len, n); d^[b^.len] := 0C
END Append;

PROCEDURE AppendBuf (b, other: StrBuf);
  VAR d, o: PCh; i: CARDINAL;
BEGIN
  IF other^.len = 0 THEN RETURN END;
  Ensure(b, b^.len + other^.len); d := CAST(PCh, b^.data); o := CAST(PCh, other^.data);
  i := 0; WHILE i < other^.len DO d^[b^.len + i] := o^[i]; INC(i) END;
  INC(b^.len, other^.len); d^[b^.len] := 0C
END AppendBuf;

PROCEDURE AppendCard (b: StrBuf; v: CARDINAL);
  VAR tmp: ARRAY [0..23] OF CHAR; i: CARDINAL;
BEGIN
  IF v = 0 THEN AppendCh(b, '0'); RETURN END;
  i := 0;
  WHILE v > 0 DO tmp[i] := CHR(ORD('0') + v MOD 10); v := v DIV 10; INC(i) END;
  WHILE i > 0 DO DEC(i); AppendCh(b, tmp[i]) END
END AppendCard;

PROCEDURE AppendInt (b: StrBuf; v: INTEGER);
  VAR m: CARDINAL;
BEGIN
  IF v < 0 THEN AppendCh(b, '-'); m := VAL(CARDINAL, -(v + 1)) + 1
  ELSE m := VAL(CARDINAL, v) END;
  AppendCard(b, m)
END AppendInt;

PROCEDURE CharAt (b: StrBuf; i: CARDINAL): CHAR;
  VAR d: PCh;
BEGIN
  IF i >= b^.len THEN RETURN 0C END;
  d := CAST(PCh, b^.data); RETURN d^[i]
END CharAt;

PROCEDURE Ptr (b: StrBuf): ADDRESS;
BEGIN RETURN b^.data END Ptr;

PROCEDURE ToStr (b: StrBuf; VAR s: ARRAY OF CHAR): BOOLEAN;
  VAR d: PCh; i: CARDINAL;
BEGIN
  d := CAST(PCh, b^.data); i := 0;
  WHILE i < b^.len DO
    IF i > HIGH(s) THEN RETURN FALSE END;
    s[i] := d^[i]; INC(i)
  END;
  IF i > HIGH(s) THEN RETURN FALSE END;
  s[i] := 0C; RETURN TRUE
END ToStr;

END StrBuf.
