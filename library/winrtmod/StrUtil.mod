IMPLEMENTATION MODULE StrUtil;

(* Naive substring scanning (fine for the small strings these serve). All output
   paths NUL-terminate; CopyRange reserves the terminator slot. *)

PROCEDURE SLen (s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END; RETURN i END SLen;

PROCEDURE IsWS (c: CHAR): BOOLEAN;
BEGIN RETURN (c = ' ') OR (c = CHR(9)) OR (c = CHR(10)) OR (c = CHR(13)) END IsWS;

PROCEDURE MatchAt (s, sub: ARRAY OF CHAR; i, ml: CARDINAL): BOOLEAN;
  VAR j: CARDINAL;
BEGIN
  j := 0; WHILE (j < ml) AND (s[i + j] = sub[j]) DO INC(j) END; RETURN j = ml
END MatchAt;

PROCEDURE CopyRange (s: ARRAY OF CHAR; a, b: CARDINAL; VAR out: ARRAY OF CHAR);
  VAR i, k: CARDINAL;                          (* copy s[a..b-1] -> out, always terminated *)
BEGIN
  k := 0; i := a;
  WHILE (i < b) AND (k < HIGH(out)) DO out[k] := s[i]; INC(k); INC(i) END;
  out[k] := 0C
END CopyRange;

PROCEDURE TrimLeft (s: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR sl, a: CARDINAL;
BEGIN
  sl := SLen(s); a := 0;
  WHILE (a < sl) AND IsWS(s[a]) DO INC(a) END;
  CopyRange(s, a, sl, out)
END TrimLeft;

PROCEDURE TrimRight (s: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR sl, b: CARDINAL;
BEGIN
  sl := SLen(s); b := sl;
  WHILE (b > 0) AND IsWS(s[b - 1]) DO DEC(b) END;
  CopyRange(s, 0, b, out)
END TrimRight;

PROCEDURE Trim (s: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR sl, a, b: CARDINAL;
BEGIN
  sl := SLen(s); a := 0;
  WHILE (a < sl) AND IsWS(s[a]) DO INC(a) END;
  b := sl;
  WHILE (b > a) AND IsWS(s[b - 1]) DO DEC(b) END;
  CopyRange(s, a, b, out)
END Trim;

PROCEDURE IndexOf (s, sub: ARRAY OF CHAR; from: CARDINAL): INTEGER;
  VAR sl, ml, i: CARDINAL;
BEGIN
  sl := SLen(s); ml := SLen(sub);
  IF ml = 0 THEN
    IF from <= sl THEN RETURN VAL(INTEGER, from) ELSE RETURN -1 END
  END;
  IF ml > sl THEN RETURN -1 END;
  i := from;
  WHILE i + ml <= sl DO
    IF MatchAt(s, sub, i, ml) THEN RETURN VAL(INTEGER, i) END;
    INC(i)
  END;
  RETURN -1
END IndexOf;

PROCEDURE Contains (s, sub: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN IndexOf(s, sub, 0) >= 0 END Contains;

PROCEDURE StartsWith (s, prefix: ARRAY OF CHAR): BOOLEAN;
  VAR pl: CARDINAL;
BEGIN
  pl := SLen(prefix);
  IF pl > SLen(s) THEN RETURN FALSE END;
  RETURN MatchAt(s, prefix, 0, pl)
END StartsWith;

PROCEDURE EndsWith (s, suffix: ARRAY OF CHAR): BOOLEAN;
  VAR sl, fl: CARDINAL;
BEGIN
  sl := SLen(s); fl := SLen(suffix);
  IF fl > sl THEN RETURN FALSE END;
  RETURN MatchAt(s, suffix, sl - fl, fl)
END EndsWith;

PROCEDURE Count (s, sub: ARRAY OF CHAR): CARDINAL;
  VAR sl, ml, i, n: CARDINAL;
BEGIN
  sl := SLen(s); ml := SLen(sub);
  IF ml = 0 THEN RETURN 0 END;
  n := 0; i := 0;
  WHILE i + ml <= sl DO
    IF MatchAt(s, sub, i, ml) THEN INC(n); INC(i, ml) ELSE INC(i) END
  END;
  RETURN n
END Count;

PROCEDURE ReplaceAll (s, from, to: ARRAY OF CHAR; VAR out: ARRAY OF CHAR): BOOLEAN;
  VAR sl, fl, tl, i, j, k: CARDINAL;

  PROCEDURE PutC (c: CHAR): BOOLEAN;
  BEGIN IF k > HIGH(out) THEN RETURN FALSE END; out[k] := c; INC(k); RETURN TRUE END PutC;

BEGIN
  sl := SLen(s); fl := SLen(from); tl := SLen(to); i := 0; k := 0;
  WHILE i < sl DO
    IF (fl # 0) AND (i + fl <= sl) AND MatchAt(s, from, i, fl) THEN
      j := 0; WHILE j < tl DO IF NOT PutC(to[j]) THEN RETURN FALSE END; INC(j) END;
      INC(i, fl)
    ELSE
      IF NOT PutC(s[i]) THEN RETURN FALSE END; INC(i)
    END
  END;
  IF k > HIGH(out) THEN RETURN FALSE END;
  out[k] := 0C; RETURN TRUE
END ReplaceAll;

PROCEDURE SplitCount (s, sep: ARRAY OF CHAR): CARDINAL;
  VAR sl, pl, i, n: CARDINAL;
BEGIN
  sl := SLen(s); pl := SLen(sep);
  IF pl = 0 THEN RETURN 1 END;
  n := 1; i := 0;
  WHILE i + pl <= sl DO
    IF MatchAt(s, sep, i, pl) THEN INC(n); INC(i, pl) ELSE INC(i) END
  END;
  RETURN n
END SplitCount;

PROCEDURE SplitPart (s, sep: ARRAY OF CHAR; index: CARDINAL; VAR part: ARRAY OF CHAR): BOOLEAN;
  VAR sl, pl, i, start, cur: CARDINAL;
BEGIN
  sl := SLen(s); pl := SLen(sep);
  IF pl = 0 THEN
    IF index = 0 THEN CopyRange(s, 0, sl, part); RETURN TRUE ELSE RETURN FALSE END
  END;
  cur := 0; start := 0; i := 0;
  WHILE i + pl <= sl DO
    IF MatchAt(s, sep, i, pl) THEN
      IF cur = index THEN CopyRange(s, start, i, part); RETURN TRUE END;
      INC(cur); INC(i, pl); start := i
    ELSE
      INC(i)
    END
  END;
  IF cur = index THEN CopyRange(s, start, sl, part); RETURN TRUE END;
  RETURN FALSE
END SplitPart;

END StrUtil.
