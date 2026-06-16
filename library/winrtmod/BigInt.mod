IMPLEMENTATION MODULE BigInt;

(* Representation: a heap record + a heap array of 64-bit limbs, little-endian
   (limb[0] is least significant), base 2^64. `sign` is -1/0/+1; `len` is the
   number of significant limbs (no leading-zero limb; len=0 iff value 0).

   The carry-propagating inner loops — multiply-accumulate, add, subtract and
   divide-by-one-limb — are inline-assembler leaf procedures using the Win64
   ABI (args rcx,rdx,r8,r9; result rax) and only volatile registers, so they
   need no stack frame. Everything else is plain Modula-2. *)

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;

CONST MaxIdx = 16777215;   (* limb-array index bound for the cast view (16M limbs) *)

TYPE
  BigInt = POINTER TO Rep;
  Rep = RECORD
    sign: INTEGER;          (* -1, 0, +1 *)
    len, cap: CARDINAL;     (* significant limbs; allocated limbs *)
    limbs: ADDRESS;         (* -> ARRAY OF CARDINAL (base 2^64, little-endian) *)
  END;
  PLimbs = POINTER TO ARRAY [0..MaxIdx] OF CARDINAL;

PROCEDURE Off (a: ADDRESS; n: CARDINAL): ADDRESS;
BEGIN RETURN CAST(ADDRESS, CAST(CARDINAL, a) + n) END Off;

(* ─────────────────────── inline-assembler limb kernels ─────────────────────── *)

(* rp[i] += ap[i]*b for i in 0..n-1; returns the out-carry limb. *)
PROCEDURE addmul1 (rp, ap: ADDRESS; n, b: CARDINAL): CARDINAL;
ASM
  xor r11, r11
  mov r10, rdx
  test r8, r8
  jz amul1_ret
amul1_loop:
  mov rax, [r10]
  mul r9
  add rax, r11
  adc rdx, 0
  add [rcx], rax
  adc rdx, 0
  mov r11, rdx
  lea r10, [r10+8]
  lea rcx, [rcx+8]
  dec r8
  jnz amul1_loop
amul1_ret:
  mov rax, r11
  ret
END addmul1;

(* rp[i] = ap[i]*b for i in 0..n-1; returns the out-carry limb. *)
PROCEDURE mul1 (rp, ap: ADDRESS; n, b: CARDINAL): CARDINAL;
ASM
  xor r11, r11
  mov r10, rdx
  test r8, r8
  jz mul1_ret
mul1_loop:
  mov rax, [r10]
  mul r9
  add rax, r11
  adc rdx, 0
  mov [rcx], rax
  mov r11, rdx
  lea r10, [r10+8]
  lea rcx, [rcx+8]
  dec r8
  jnz mul1_loop
mul1_ret:
  mov rax, r11
  ret
END mul1;

(* rp[i] = ap[i]+bp[i] for i in 0..n-1; returns the out-carry (0/1). *)
PROCEDURE addn (rp, ap, bp: ADDRESS; n: CARDINAL): CARDINAL;
ASM
  xor eax, eax
  test r9, r9
  jz addn_ret
  clc
addn_loop:
  mov rax, [rdx]
  adc rax, [r8]
  mov [rcx], rax
  lea rdx, [rdx+8]
  lea r8, [r8+8]
  lea rcx, [rcx+8]
  dec r9
  jnz addn_loop
  setc al
  movzx eax, al
addn_ret:
  ret
END addn;

(* rp[i] = ap[i]-bp[i] for i in 0..n-1; returns the out-borrow (0/1). *)
PROCEDURE subn (rp, ap, bp: ADDRESS; n: CARDINAL): CARDINAL;
ASM
  xor eax, eax
  test r9, r9
  jz subn_ret
  clc
subn_loop:
  mov rax, [rdx]
  sbb rax, [r8]
  mov [rcx], rax
  lea rdx, [rdx+8]
  lea r8, [r8+8]
  lea rcx, [rcx+8]
  dec r9
  jnz subn_loop
  setc al
  movzx eax, al
subn_ret:
  ret
END subn;

(* rp[] = ap[] / d (limbs 0..n-1, processed high->low); returns ap[] mod d. *)
PROCEDURE divmod1 (rp, ap: ADDRESS; n, d: CARDINAL): CARDINAL;
ASM
  mov r10, rdx
  test r8, r8
  jz dm1_zero
  xor edx, edx
  mov r11, r8
  dec r11
dm1_loop:
  mov rax, [r10 + r11*8]
  div r9
  mov [rcx + r11*8], rax
  dec r11
  jns dm1_loop
  mov rax, rdx
  ret
dm1_zero:
  xor eax, eax
  ret
END divmod1;

(* ─────────────────────────── rep helpers ─────────────────────────── *)

PROCEDURE Lp (p: BigInt): PLimbs;
BEGIN RETURN CAST(PLimbs, p^.limbs) END Lp;

(* limb get/set — go through a local so the designator is a variable, not a
   function-call result (which ISO M2 does not allow as an lvalue). *)
PROCEDURE GetL (p: BigInt; i: CARDINAL): CARDINAL;
  VAR l: PLimbs;
BEGIN l := Lp(p); RETURN l^[i] END GetL;

PROCEDURE SetL (p: BigInt; i, v: CARDINAL);
  VAR l: PLimbs;
BEGIN l := Lp(p); l^[i] := v END SetL;

PROCEDURE NewRep (cap: CARDINAL): BigInt;
  VAR p: BigInt; a: ADDRESS;
BEGIN
  IF cap = 0 THEN cap := 1 END;
  ALLOCATE(a, SIZE(Rep)); p := CAST(BigInt, a);
  p^.limbs := NIL; ALLOCATE(p^.limbs, cap * 8);
  p^.sign := 0; p^.len := 0; p^.cap := cap;
  RETURN p
END NewRep;

PROCEDURE Dispose (VAR a: BigInt);
  VAR pa: ADDRESS;
BEGIN
  IF a # NIL THEN
    DEALLOCATE(a^.limbs, a^.cap * 8);
    pa := CAST(ADDRESS, a); DEALLOCATE(pa, SIZE(Rep));
    a := NIL
  END
END Dispose;

PROCEDURE Ensure (p: BigInt; cap: CARDINAL);
  VAR na, old: ADDRESS; i: CARDINAL; src, dst: PLimbs;
BEGIN
  IF cap <= p^.cap THEN RETURN END;
  na := NIL; ALLOCATE(na, cap * 8);
  dst := CAST(PLimbs, na); src := Lp(p);
  i := 0; WHILE i < p^.len DO dst^[i] := src^[i]; INC(i) END;
  old := p^.limbs; DEALLOCATE(old, p^.cap * 8);
  p^.limbs := na; p^.cap := cap
END Ensure;

PROCEDURE Norm (p: BigInt);
  VAR l: PLimbs;
BEGIN
  l := Lp(p);
  WHILE (p^.len > 0) AND (l^[p^.len - 1] = 0) DO DEC(p^.len) END;
  IF p^.len = 0 THEN p^.sign := 0 END
END Norm;

PROCEDURE Create (): BigInt;
BEGIN RETURN NewRep(1) END Create;

PROCEDURE Copy (a: BigInt): BigInt;
  VAR p: BigInt; i: CARDINAL; sl, dl: PLimbs;
BEGIN
  p := NewRep(a^.len + 1);
  p^.sign := a^.sign; p^.len := a^.len;
  sl := Lp(a); dl := Lp(p);
  i := 0; WHILE i < a^.len DO dl^[i] := sl^[i]; INC(i) END;
  RETURN p
END Copy;

(* ─────────────────────────── construction ─────────────────────────── *)

PROCEDURE FromCard (v: CARDINAL): BigInt;
  VAR p: BigInt;
BEGIN
  p := NewRep(1);
  IF v # 0 THEN SetL(p, 0, v); p^.len := 1; p^.sign := 1 END;
  RETURN p
END FromCard;

PROCEDURE FromInt (v: INTEGER): BigInt;
  VAR p: BigInt; m: CARDINAL;
BEGIN
  p := NewRep(1);
  IF v > 0 THEN
    SetL(p, 0, VAL(CARDINAL, v)); p^.len := 1; p^.sign := 1
  ELSIF v < 0 THEN
    m := VAL(CARDINAL, -(v + 1)) + 1;        (* |v| without MIN(INTEGER) overflow *)
    SetL(p, 0, m); p^.len := 1; p^.sign := -1
  END;
  RETURN p
END FromInt;

(* a := a * m  (m a small CARDINAL), in place *)
PROCEDURE MulSmall (a: BigInt; m: CARDINAL);
  VAR c: CARDINAL;
BEGIN
  IF (a^.len = 0) OR (m = 0) THEN a^.len := 0; a^.sign := 0; RETURN END;
  Ensure(a, a^.len + 1);
  c := mul1(a^.limbs, a^.limbs, a^.len, m);
  IF c # 0 THEN SetL(a, a^.len, c); INC(a^.len) END;
  IF a^.sign = 0 THEN a^.sign := 1 END
END MulSmall;

(* a := a + v  (v a small CARDINAL), in place *)
PROCEDURE AddSmall (a: BigInt; v: CARDINAL);
  VAR i, carry, s: CARDINAL; l: PLimbs;
BEGIN
  IF v = 0 THEN RETURN END;
  Ensure(a, a^.len + 1);
  l := Lp(a); carry := v; i := 0;
  WHILE (carry # 0) AND (i < a^.len) DO
    s := l^[i] + carry; l^[i] := s;
    IF s < carry THEN carry := 1 ELSE carry := 0 END;
    INC(i)
  END;
  IF carry # 0 THEN l^[a^.len] := carry; INC(a^.len) END;
  IF a^.sign = 0 THEN a^.sign := 1 END
END AddSmall;

PROCEDURE DigitVal (c: CHAR): CARDINAL;
BEGIN
  IF (c >= '0') AND (c <= '9') THEN RETURN ORD(c) - ORD('0') END;
  IF (c >= 'a') AND (c <= 'f') THEN RETURN ORD(c) - ORD('a') + 10 END;
  IF (c >= 'A') AND (c <= 'F') THEN RETURN ORD(c) - ORD('A') + 10 END;
  RETURN 99
END DigitVal;

PROCEDURE FromStr (s: ARRAY OF CHAR; radix: CARDINAL; VAR a: BigInt): BOOLEAN;
  VAR p: BigInt; i, dv: CARDINAL; neg, any: BOOLEAN;
BEGIN
  p := NewRep(2); a := p;
  IF (radix < 2) OR (radix > 16) THEN RETURN FALSE END;
  i := 0; neg := FALSE; any := FALSE;
  WHILE (i <= HIGH(s)) AND ((s[i] = ' ') OR (s[i] = CHR(9))) DO INC(i) END;
  IF (i <= HIGH(s)) AND ((s[i] = '-') OR (s[i] = '+')) THEN
    neg := s[i] = '-'; INC(i)
  END;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO
    dv := DigitVal(s[i]);
    IF dv >= radix THEN RETURN FALSE END;
    MulSmall(p, radix); AddSmall(p, dv);
    any := TRUE; INC(i)
  END;
  IF NOT any THEN RETURN FALSE END;
  IF neg AND (p^.sign # 0) THEN p^.sign := -1 END;
  RETURN TRUE
END FromStr;

PROCEDURE FromStr0 (s: ARRAY OF CHAR): BigInt;
  VAR a: BigInt; ok: BOOLEAN;
BEGIN
  ok := FromStr(s, 10, a);
  IF NOT ok THEN a^.sign := 0; a^.len := 0 END;
  RETURN a
END FromStr0;

PROCEDURE DigitChar (d: CARDINAL): CHAR;
BEGIN
  IF d < 10 THEN RETURN CHR(ORD('0') + d) ELSE RETURN CHR(ORD('A') + d - 10) END
END DigitChar;

PROCEDURE ToStr (a: BigInt; radix: CARDINAL; VAR s: ARRAY OF CHAR): BOOLEAN;
  VAR tmp: BigInt; i, j, rem: CARDINAL; t: CHAR;
BEGIN
  IF (radix < 2) OR (radix > 16) THEN RETURN FALSE END;
  IF a^.sign = 0 THEN
    IF HIGH(s) < 1 THEN RETURN FALSE END;
    s[0] := '0'; s[1] := 0C; RETURN TRUE
  END;
  tmp := Copy(a); tmp^.sign := 1;
  i := 0;
  WHILE tmp^.len > 0 DO
    IF i > HIGH(s) THEN Dispose(tmp); RETURN FALSE END;
    rem := divmod1(tmp^.limbs, tmp^.limbs, tmp^.len, radix);
    Norm(tmp);
    s[i] := DigitChar(rem); INC(i)
  END;
  IF a^.sign < 0 THEN
    IF i > HIGH(s) THEN Dispose(tmp); RETURN FALSE END;
    s[i] := '-'; INC(i)
  END;
  (* reverse s[0..i-1] in place *)
  j := 0;
  WHILE j * 2 < i DO
    t := s[j]; s[j] := s[i - 1 - j]; s[i - 1 - j] := t; INC(j)
  END;
  IF i <= HIGH(s) THEN s[i] := 0C END;
  Dispose(tmp);
  RETURN TRUE
END ToStr;

(* ─────────────────────────── magnitude helpers ─────────────────────────── *)

PROCEDURE MagCmp (a, b: BigInt): INTEGER;
  VAR i: CARDINAL; la, lb: PLimbs;
BEGIN
  IF a^.len # b^.len THEN
    IF a^.len > b^.len THEN RETURN 1 ELSE RETURN -1 END
  END;
  la := Lp(a); lb := Lp(b); i := a^.len;
  WHILE i > 0 DO
    DEC(i);
    IF la^[i] # lb^[i] THEN
      IF la^[i] > lb^[i] THEN RETURN 1 ELSE RETURN -1 END
    END
  END;
  RETURN 0
END MagCmp;

PROCEDURE MagAdd (x, y: BigInt): BigInt;     (* |x| + |y|, result sign = +1 *)
  VAR big, small, r: BigInt; carry, i, s: CARDINAL; lb, lr: PLimbs;
BEGIN
  IF x^.len >= y^.len THEN big := x; small := y ELSE big := y; small := x END;
  r := NewRep(big^.len + 1);
  carry := addn(r^.limbs, big^.limbs, small^.limbs, small^.len);
  lb := Lp(big); lr := Lp(r); i := small^.len;
  WHILE (i < big^.len) AND (carry # 0) DO
    s := lb^[i] + carry; lr^[i] := s;
    IF s < carry THEN carry := 1 ELSE carry := 0 END;
    INC(i)
  END;
  WHILE i < big^.len DO lr^[i] := lb^[i]; INC(i) END;
  r^.len := big^.len;
  IF carry # 0 THEN lr^[big^.len] := carry; r^.len := big^.len + 1 END;
  r^.sign := 1; Norm(r);
  RETURN r
END MagAdd;

PROCEDURE MagSub (x, y: BigInt): BigInt;     (* |x| - |y|, requires |x| >= |y| *)
  VAR r: BigInt; borrow, i, d: CARDINAL; lx, lr: PLimbs;
BEGIN
  r := NewRep(x^.len);
  borrow := subn(r^.limbs, x^.limbs, y^.limbs, y^.len);
  lx := Lp(x); lr := Lp(r); i := y^.len;
  WHILE (i < x^.len) AND (borrow # 0) DO
    d := lx^[i]; lr^[i] := d - borrow;
    IF d < borrow THEN borrow := 1 ELSE borrow := 0 END;
    INC(i)
  END;
  WHILE i < x^.len DO lr^[i] := lx^[i]; INC(i) END;
  r^.len := x^.len; r^.sign := 1; Norm(r);
  RETURN r
END MagSub;

PROCEDURE MagSubIP (x, y: BigInt);           (* x := x - y, requires |x| >= |y| *)
  VAR borrow, i, d: CARDINAL; lx: PLimbs;
BEGIN
  borrow := subn(x^.limbs, x^.limbs, y^.limbs, y^.len);
  lx := Lp(x); i := y^.len;
  WHILE (i < x^.len) AND (borrow # 0) DO
    d := lx^[i]; lx^[i] := d - borrow;
    IF d < borrow THEN borrow := 1 ELSE borrow := 0 END;
    INC(i)
  END;
  Norm(x)
END MagSubIP;

PROCEDURE ShlOne (p: BigInt);                (* p := p << 1 (magnitude) *)
  VAR i, carry, nc: CARDINAL; l: PLimbs;
BEGIN
  IF p^.len = 0 THEN RETURN END;
  Ensure(p, p^.len + 1);
  l := Lp(p); carry := 0; i := 0;
  WHILE i < p^.len DO
    nc := l^[i] SHR 63; l^[i] := (l^[i] SHL 1) BOR carry; carry := nc; INC(i)
  END;
  IF carry # 0 THEN l^[p^.len] := 1; INC(p^.len) END
END ShlOne;

PROCEDURE ShrOne (p: BigInt);                (* p := p >> 1 (magnitude) *)
  VAR i, carry, nc: CARDINAL; l: PLimbs;
BEGIN
  IF p^.len = 0 THEN RETURN END;
  l := Lp(p); carry := 0; i := p^.len;
  WHILE i > 0 DO
    DEC(i);
    nc := l^[i] BAND 1; l^[i] := (l^[i] SHR 1) BOR (carry SHL 63); carry := nc
  END;
  Norm(p)
END ShrOne;

(* ─────────────────────────── public arithmetic ─────────────────────────── *)

PROCEDURE Add (a, b: BigInt): BigInt;
  VAR r: BigInt; c: INTEGER;
BEGIN
  IF a^.sign = 0 THEN RETURN Copy(b) END;
  IF b^.sign = 0 THEN RETURN Copy(a) END;
  IF a^.sign = b^.sign THEN
    r := MagAdd(a, b); r^.sign := a^.sign
  ELSE
    c := MagCmp(a, b);
    IF c = 0 THEN RETURN Create()
    ELSIF c > 0 THEN r := MagSub(a, b); r^.sign := a^.sign
    ELSE r := MagSub(b, a); r^.sign := b^.sign END
  END;
  Norm(r); RETURN r
END Add;

PROCEDURE Sub (a, b: BigInt): BigInt;
  VAR r: BigInt; c, bs: INTEGER;
BEGIN
  bs := -b^.sign;                         (* sign of -b *)
  IF a^.sign = 0 THEN
    r := Copy(b); IF r^.sign # 0 THEN r^.sign := -r^.sign END; RETURN r
  END;
  IF bs = 0 THEN RETURN Copy(a) END;
  IF a^.sign = bs THEN
    r := MagAdd(a, b); r^.sign := a^.sign
  ELSE
    c := MagCmp(a, b);
    IF c = 0 THEN RETURN Create()
    ELSIF c > 0 THEN r := MagSub(a, b); r^.sign := a^.sign
    ELSE r := MagSub(b, a); r^.sign := bs END
  END;
  Norm(r); RETURN r
END Sub;

PROCEDURE Mul (a, b: BigInt): BigInt;
  VAR r: BigInt; j, c: CARDINAL; lb, lr: PLimbs;
BEGIN
  IF (a^.sign = 0) OR (b^.sign = 0) THEN RETURN Create() END;
  r := NewRep(a^.len + b^.len);
  lr := Lp(r); j := 0;
  WHILE j < a^.len + b^.len DO lr^[j] := 0; INC(j) END;
  lb := Lp(b);
  c := mul1(r^.limbs, a^.limbs, a^.len, lb^[0]); lr^[a^.len] := c;
  j := 1;
  WHILE j < b^.len DO
    c := addmul1(Off(r^.limbs, j * 8), a^.limbs, a^.len, lb^[j]);
    lr^[j + a^.len] := c; INC(j)
  END;
  r^.len := a^.len + b^.len;
  IF a^.sign = b^.sign THEN r^.sign := 1 ELSE r^.sign := -1 END;
  Norm(r); RETURN r
END Mul;

PROCEDURE Neg (a: BigInt): BigInt;
  VAR r: BigInt;
BEGIN r := Copy(a); IF r^.sign # 0 THEN r^.sign := -r^.sign END; RETURN r END Neg;

PROCEDURE Abs (a: BigInt): BigInt;
  VAR r: BigInt;
BEGIN r := Copy(a); IF r^.sign < 0 THEN r^.sign := 1 END; RETURN r END Abs;

(* magnitude long division: q = |a| div |b|, rem = |a| mod |b|; both fresh *)
PROCEDURE BinDivMod (a, b: BigInt; VAR q, rem: BigInt);
  VAR qq, rr: BigInt; nbits, i: CARDINAL; la, lq: PLimbs; bitset: BOOLEAN;
BEGIN
  qq := NewRep(a^.len);
  lq := Lp(qq); i := 0; WHILE i < a^.len DO lq^[i] := 0; INC(i) END;
  qq^.len := a^.len;
  rr := NewRep(b^.len + 2); rr^.len := 0;
  nbits := BitLength(a); la := Lp(a);
  i := nbits;
  WHILE i > 0 DO
    DEC(i);
    ShlOne(rr);
    bitset := (la^[i DIV 64] SHR (i MOD 64)) BAND 1 # 0;
    IF bitset THEN
      IF rr^.len = 0 THEN SetL(rr, 0, 1); rr^.len := 1
      ELSE SetL(rr, 0, GetL(rr, 0) BOR 1) END
    END;
    IF MagCmp(rr, b) >= 0 THEN
      MagSubIP(rr, b);
      lq := Lp(qq); lq^[i DIV 64] := lq^[i DIV 64] BOR (VAL(CARDINAL, 1) SHL (i MOD 64))
    END
  END;
  Norm(qq); Norm(rr);
  q := qq; rem := rr
END BinDivMod;

PROCEDURE DivMod (a, b: BigInt; VAR q, r: BigInt): BOOLEAN;
  VAR qq, rr: BigInt; rem: CARDINAL; cmp: INTEGER;
BEGIN
  IF b^.sign = 0 THEN q := Create(); r := Create(); RETURN FALSE END;
  cmp := MagCmp(a, b);
  IF cmp < 0 THEN
    q := Create(); r := Copy(a); RETURN TRUE      (* |a|<|b|: quotient 0, remainder a *)
  END;
  IF b^.len = 1 THEN
    qq := NewRep(a^.len);
    rem := divmod1(qq^.limbs, a^.limbs, a^.len, GetL(b, 0));
    qq^.len := a^.len; Norm(qq);
    rr := FromCard(rem)
  ELSE
    BinDivMod(a, b, qq, rr)
  END;
  IF qq^.len > 0 THEN
    IF a^.sign = b^.sign THEN qq^.sign := 1 ELSE qq^.sign := -1 END
  END;
  IF rr^.len > 0 THEN rr^.sign := a^.sign END;
  q := qq; r := rr; RETURN TRUE
END DivMod;

PROCEDURE Div (a, b: BigInt): BigInt;
  VAR q, r: BigInt; ok: BOOLEAN;
BEGIN ok := DivMod(a, b, q, r); Dispose(r); RETURN q END Div;

PROCEDURE Mod (a, b: BigInt): BigInt;
  VAR q, r: BigInt; ok: BOOLEAN;
BEGIN ok := DivMod(a, b, q, r); Dispose(q); RETURN r END Mod;

PROCEDURE Pow (base: BigInt; exp: CARDINAL): BigInt;
  VAR result, b, t: BigInt; e: CARDINAL;
BEGIN
  result := FromCard(1); b := Copy(base); e := exp;
  WHILE e > 0 DO
    IF e BAND 1 # 0 THEN t := Mul(result, b); Dispose(result); result := t END;
    e := e SHR 1;
    IF e > 0 THEN t := Mul(b, b); Dispose(b); b := t END
  END;
  Dispose(b); RETURN result
END Pow;

PROCEDURE PowMod (base, exp, m: BigInt): BigInt;
  VAR result, b, e, t, q: BigInt; ok: BOOLEAN;
BEGIN
  result := FromCard(1);
  ok := DivMod(base, m, q, b); Dispose(q);        (* b := base mod m *)
  e := Copy(exp);
  WHILE e^.sign > 0 DO
    IF (GetL(e, 0) BAND 1) # 0 THEN
      t := Mul(result, b); Dispose(result);
      ok := DivMod(t, m, q, result); Dispose(q); Dispose(t)
    END;
    ShrOne(e);
    IF e^.sign > 0 THEN
      t := Mul(b, b); Dispose(b);
      ok := DivMod(t, m, q, b); Dispose(q); Dispose(t)
    END
  END;
  Dispose(b); Dispose(e); RETURN result
END PowMod;

PROCEDURE Gcd (a, b: BigInt): BigInt;
  VAR x, y, q, r: BigInt; ok: BOOLEAN;
BEGIN
  x := Abs(a); y := Abs(b);
  WHILE y^.sign # 0 DO
    ok := DivMod(x, y, q, r); Dispose(q);
    Dispose(x); x := y; y := r
  END;
  Dispose(y); RETURN x
END Gcd;

(* ─────────────────────────── inspection ─────────────────────────── *)

PROCEDURE Compare (a, b: BigInt): INTEGER;
BEGIN
  IF a^.sign # b^.sign THEN
    IF a^.sign > b^.sign THEN RETURN 1 ELSE RETURN -1 END
  END;
  IF a^.sign = 0 THEN RETURN 0 END;
  IF a^.sign > 0 THEN RETURN MagCmp(a, b) ELSE RETURN -MagCmp(a, b) END
END Compare;

PROCEDURE Sign (a: BigInt): INTEGER;
BEGIN RETURN a^.sign END Sign;

PROCEDURE IsZero (a: BigInt): BOOLEAN;
BEGIN RETURN a^.sign = 0 END IsZero;

PROCEDURE BitLength (a: BigInt): CARDINAL;
  VAR top, n: CARDINAL;
BEGIN
  IF a^.len = 0 THEN RETURN 0 END;
  top := GetL(a, a^.len - 1); n := 0;
  WHILE top # 0 DO top := top SHR 1; INC(n) END;
  RETURN (a^.len - 1) * 64 + n
END BitLength;

END BigInt.
