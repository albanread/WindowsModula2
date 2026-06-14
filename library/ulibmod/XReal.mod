(* Ported to NewM2 2026-05-13 from XDS 2.60 lib/src/lib/XReal.mod. Apache-2.0.
   Integration notes:
     - Dropped XDS pragmas (`<*- M2BASE16 *>`, `<*+ M2EXTENSIONS *>`).
     - Flattened `<* IF TARGET_FAMILY = "UNIX" *> ... %ELSE … %END *>`
       around `exponent`. Kept the **non-UNIX** branch — it copies
       `rr` into a local `r`, mutates the local, and writes back at
       the end. The UNIX branch mutated `rr` in-place; behaviour is
       identical on a correct compiler but the non-UNIX form is the
       conservative choice on a fresh codegen.
     - Dropped XDS `s-` constant-parameter modifier on `strcpy`.
     - `MAXPOW = 30` is preserved verbatim. The original XDS comment
       `(* must be less than 32 *)` is a stale 32-bit-CARDINAL note;
       in practice `pow_max` is bounded by `MAX(LONGREAL)` overflow
       (settles at i ≈ 9 for IEEE-754 binary64), not by integer width.
       The algorithm is wordsize-clean on 64-bit.
     - `TRUNC(r)` returns CARDINAL by ISO; the body uses it on a
       LONGREAL `r < 10` — fits any CARDINAL. No 32-bit hazard.
*)
IMPLEMENTATION MODULE XReal;

CONST
  MAXPOW = 30;

VAR
  pow: ARRAY [0..MAXPOW-1] OF LONGREAL; (* pow[i] = 10^(2^i), or -1.0 *)
  pow_max, pow2: CARDINAL; (* max: 10^(pow2 = 2^pow_max) < MAX(float) *)
  pow_done: BOOLEAN;

PROCEDURE pow_init;
  VAR i: INTEGER;
BEGIN
  IF pow_done THEN RETURN END; pow_done := TRUE;
  i := 1; pow[0] := 10.0; pow2 := 1;
  WHILE (i < MAXPOW) & (MAX(LONGREAL) / pow[i-1] > pow[i-1]) DO
    pow[i] := pow[i-1] * pow[i-1]; INC(pow2, pow2); INC(i);
  END;
  pow_max := i - 1;
  WHILE i < MAXPOW DO
    pow[i] := -1.0; INC(i);
  END;
END pow_init;

PROCEDURE power10(e: CARDINAL; VAR oo: BOOLEAN): LONGREAL;
  VAR
    i: CARDINAL;
    t: LONGREAL;
    ovf: BOOLEAN;
BEGIN
  i := 0; t := 1.0; ovf := oo;
  WHILE (e # 0) & NOT ovf DO
    pow_init;
    IF ODD(e) THEN
      ovf := ovf OR (i > pow_max) OR (MAX(LONGREAL) / pow[i] <= t);
      IF NOT ovf THEN t := t * pow[i] END;
    END;
    INC(i); e := e DIV 2;
  END;
  oo := ovf;
  IF ovf THEN t := MAX(LONGREAL) END;
  RETURN t;
END power10;

PROCEDURE exponent(VAR rr: LONGREAL): INTEGER;
(* exponent(0.5) = 0, exponent(5.0) = 1, etc. *)
  VAR
    r, x: LONGREAL;
    n, i: INTEGER;
    e   : INTEGER;
BEGIN
  pow_init;
  ASSERT(rr >= 0.0);
  n := pow2; i := pow_max; e := 0; r := rr;
  IF r >= 1.0 THEN
    IF r / 2.0 = r THEN (* IEEE infinity *) r := MAX(LONGREAL) END;
    LOOP
      x := r / pow[i];
      IF x < 0.1 THEN
        IF i = 0 THEN EXIT ELSE DEC(i); n := n DIV 2 END;
      ELSE
        r := x; INC(e, n);
      END;
    END;
  ELSIF (r < 0.1) & (r * 2.0 # r) THEN
    LOOP
      x := r * pow[i];
      ASSERT(x > 0.0);
      IF x >= 1.0 THEN
        IF i = 0 THEN EXIT ELSE DEC(i); n := n DIV 2 END;
      ELSE
        r := x; DEC(e, n);
      END;
    END;
  END;
  rr := r;
  IF rr >= 1.0 THEN rr := rr / 10.0; INC(e) END;
  RETURN e;
END exponent;

PROCEDURE get_digit(VAR r: LONGREAL): CHAR;
  VAR d: CARDINAL;
BEGIN
  ASSERT(r < 1.0);
  ASSERT(r >= 0.0);
  r := r * 10.0;
  d := TRUNC(r);
  r := r - LFLOAT(d);
  RETURN CHR(d + ORD('0'));
END get_digit;

PROCEDURE to_float (r: LONGREAL;
                    digs, round, max: INTEGER;
                    exp: CHAR;
                    tail: BOOLEAN;
                    esig: BOOLEAN;
                    VAR str: STR);

  VAR
    ps: CARDINAL;

  PROCEDURE ch(c: CHAR);
  BEGIN
    IF ps <= HIGH(str) THEN str[ps] := c END;
    INC(ps);
  END ch;

  PROCEDURE cnum(n: CARDINAL);
  BEGIN
    IF n < 10 THEN
      ch(CHR(n + ORD('0')));
    ELSE
      cnum(n DIV 10);
      ch(CHR(n MOD 10 + ORD('0')));
    END;
  END cnum;

  VAR
    k, l, d, pt, e, len: INTEGER;
    c: CHAR;
    ovr, nz: BOOLEAN;
BEGIN
  ps := 0; len := 0; ovr := FALSE; nz := FALSE;

  IF r < 0.0 THEN ch('-'); r := -r END;
  e := exponent(r);

  d := max;
  IF (digs > 0) & (digs < d) THEN d := digs END;

  IF r > 0.0 THEN
    r := r + 0.5 / power10(d, ovr);
    IF r >= 1.0 THEN r := r / 10.0; INC(e) END;
  END;

  pt := 1; DEC(e);
  k := e MOD round;
  IF k # 0 THEN pt := k + 1; DEC(e, k) END;

  ASSERT(r < 1.0);
  ASSERT(r >= 0.0);
  FOR k := 1 TO pt DO
    IF len < d THEN c := get_digit(r); INC(len);
    ELSE c := '0';
    END;
    IF nz THEN ch(c)
    ELSIF c # '0' THEN ch(c); nz := TRUE;
    ELSIF k = pt THEN ch(c);
    END;
    ASSERT(r < 1.0);
  END;

  IF d > pt THEN
    k := ps; ch('.');
    FOR l := 1 TO d - pt DO
      c := get_digit(r); ch(c);
      IF c # '0' THEN k := ps; nz := TRUE END;
    END;
    IF NOT tail THEN ps := k END;
  END;

  IF nz & (e # 0) THEN
    ch(exp);
    IF e < 0 THEN ch('-'); e := -e ELSIF esig THEN ch('+') END;
    cnum(e);
  END;

  ASSERT(NOT ovr);
  IF ps <= HIGH(str) THEN str[ps] := 0C END;
END to_float;

PROCEDURE to_fixed (r: LONGREAL;
                    place, max: INTEGER;
                    VAR str: STR);
  VAR
    ps: CARDINAL;

  PROCEDURE ch(c: CHAR);
  BEGIN
    IF ps <= HIGH(str) THEN str[ps] := c END;
    INC(ps);
  END ch;

  VAR
    e, n, d, len: INTEGER;
    ovr: BOOLEAN;
BEGIN
  ps := 0; len := 0; ovr := FALSE;
  IF r < 0.0 THEN ch('-'); r := -r END;

  IF r > 0.0 THEN
    e := exponent(r);
    IF place >= 0 THEN n := e + place ELSE n := e + place + 1 END;
    IF n > max THEN r := r + 0.5 / power10(max, ovr);
    ELSIF n >= 0 THEN r := r + 0.5 / power10(n, ovr);
    END;
    IF r >= 1.0 THEN r := r / 10.0; INC(e) END;
  ELSE
    e := 0;
  END;
  d := max;
  IF e <= 0 THEN
    ch('0');
    IF place > -1 THEN
      ch('.'); n := 0;
      WHILE (n < place) & (ps < HIGH(str) + 1) DO
        IF (n < -e) OR (len >= d) THEN ch('0');
        ELSE ch(get_digit(r)); INC(len);
        END;
        INC(n);
      END;
    END;
  ELSIF -place - 1 >= e THEN
    ch('0');
  ELSE
    n := 0;
    WHILE (n < e) & (ps < HIGH(str) + 2) DO
      IF (n < e + place + 1) & (len < d) THEN ch(get_digit(r)); INC(len);
      ELSE ch('0');
      END;
      INC(n);
    END;
    IF place > -1 THEN
      ch('.'); n := 0;
      WHILE (n < place) & (ps < HIGH(str) + 1) DO
        IF len < d THEN ch(get_digit(r)); INC(len);
        ELSE ch('0');
        END;
        INC(n);
      END;
    END;
  END;
  ASSERT(NOT ovr);
  IF ps <= HIGH(str) THEN str[ps] := 0C END;
END to_fixed;

PROCEDURE to_any(r      : LONGREAL;
                 max    : INTEGER;
                 VAR s  : STR;
                 len    : INTEGER);
  VAR
    d, e: INTEGER;
    sg  : INTEGER;
    f   : LONGREAL;
BEGIN
  IF len <= 0 THEN RETURN END;
  f := r; sg := 0;
  IF f < 0.0 THEN f := -f; sg := 1 END;
  e := exponent(f);
  IF max > len - sg THEN max := len - sg END;
  IF (max = len - sg) & (e + 1 < max) THEN max := len - sg - 1 END;
  FOR d := 0 TO max DO s[d] := get_digit(f) END;
  WHILE (max > 1) & (s[max-1] = '0') & (s[max] < '5') DO DEC(max) END;
  IF (e >= max) & (sg + e <= len) THEN
    to_fixed(r, len - e - sg - 1, max, s);
    IF INT(LENGTH(s)) <= len THEN RETURN END;
  END;
  IF (e >= 0) & (e < max) & (sg + 1 + max <= len) THEN
    to_fixed(r, len - e - sg - 1, max, s);
  ELSIF (e < 0) & (sg + 2 + ABS(e) + max <= len) THEN
    to_fixed(r, len - sg - 2, max, s);
  ELSE
    d := len;
    LOOP
      to_float(r, d, 1, max, 'E', FALSE, FALSE, s);
      IF (d <= 1) OR (INT(LENGTH(s)) <= len) THEN EXIT END;
      DEC(d);
    END;
  END;
END to_any;

PROCEDURE strcpy(fr: STR; VAR to: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(fr)) & (i < LEN(to)) & (fr[i] # 0C) DO
    to[i] := fr[i]; INC(i);
  END;
  IF i <= INT(HIGH(to)) THEN to[i] := 0C END;
END strcpy;

BEGIN
  pow_done := FALSE;
END XReal.
