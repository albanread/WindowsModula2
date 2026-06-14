IMPLEMENTATION MODULE ExStrings;

CONST NUL = CHR(0);

PROCEDURE Length (s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # NUL) DO INC(i) END;
  RETURN i
END Length;

PROCEDURE HexDigit (d: CARDINAL): CHAR;
BEGIN
  IF d < 10 THEN RETURN CHR(ORD('0') + d)
  ELSE RETURN CHR(ORD('A') + (d - 10)) END
END HexDigit;

(* internal: forward substring search, case-sensitive (ci=FALSE) or not *)
PROCEDURE Find (pattern, s: ARRAY OF CHAR; startIndex: CARDINAL; ci: BOOLEAN;
                VAR found: BOOLEAN; VAR pos: CARDINAL);
  VAR lp, ls, i, j: CARDINAL; match: BOOLEAN; a, b: CHAR;
BEGIN
  found := FALSE; pos := 0;
  lp := Length(pattern); ls := Length(s);
  IF (lp = 0) OR (lp > ls) THEN RETURN END;
  i := startIndex;
  WHILE i + lp <= ls DO
    match := TRUE; j := 0;
    WHILE match AND (j < lp) DO
      a := s[i + j]; b := pattern[j];
      IF ci THEN a := CAP(a); b := CAP(b) END;
      IF a # b THEN match := FALSE END;
      INC(j)
    END;
    IF match THEN found := TRUE; pos := i; RETURN END;
    INC(i)
  END
END Find;

PROCEDURE CompareI (s1, s2: ARRAY OF CHAR): CompareResults;
  VAR i, l1, l2: CARDINAL; c1, c2: CHAR;
BEGIN
  l1 := Length(s1); l2 := Length(s2);
  i := 0;
  WHILE (i < l1) AND (i < l2) DO
    c1 := CAP(s1[i]); c2 := CAP(s2[i]);
    IF c1 < c2 THEN RETURN less
    ELSIF c1 > c2 THEN RETURN greater END;
    INC(i)
  END;
  IF l1 < l2 THEN RETURN less
  ELSIF l1 > l2 THEN RETURN greater
  ELSE RETURN equal END
END CompareI;

PROCEDURE EqualI (s1, s2: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN CompareI(s1, s2) = equal
END EqualI;

PROCEDURE FindNextI (pattern, stringToSearch: ARRAY OF CHAR; startIndex: CARDINAL;
                     VAR patternFound: BOOLEAN; VAR posOfPattern: CARDINAL);
BEGIN
  Find(pattern, stringToSearch, startIndex, TRUE, patternFound, posOfPattern)
END FindNextI;

PROCEDURE AssignNullTerm (source: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
  VAR i, cap: CARDINAL;
BEGIN
  cap := HIGH(destination) + 1;
  i := 0;
  WHILE (i < cap) AND (i <= HIGH(source)) AND (source[i] # NUL) DO
    destination[i] := source[i]; INC(i)
  END;
  IF i < cap THEN destination[i] := NUL
  ELSE destination[HIGH(destination)] := NUL END
END AssignNullTerm;

PROCEDURE NullTerminate (VAR str: ARRAY OF CHAR);
BEGIN
  str[HIGH(str)] := NUL
END NullTerminate;

PROCEDURE Lowercase (VAR str: ARRAY OF CHAR);
  VAR i, n: CARDINAL;
BEGIN
  n := Length(str); i := 0;
  WHILE i < n DO
    IF (str[i] >= 'A') AND (str[i] <= 'Z') THEN
      str[i] := CHR(ORD(str[i]) + (ORD('a') - ORD('A')))
    END;
    INC(i)
  END
END Lowercase;

PROCEDURE Uppercase (VAR str: ARRAY OF CHAR);
  VAR i, n: CARDINAL;
BEGIN
  n := Length(str); i := 0;
  WHILE i < n DO str[i] := CAP(str[i]); INC(i) END
END Uppercase;

PROCEDURE AppendChar (ch: CHAR; VAR str: ARRAY OF CHAR);
  VAR n: CARDINAL;
BEGIN
  n := Length(str);
  IF n < HIGH(str) THEN              (* room for ch at n and NUL at n+1 *)
    str[n] := ch; str[n + 1] := NUL
  END
END AppendChar;

PROCEDURE AppendCharCond (ch: CHAR; VAR str: ARRAY OF CHAR);
  VAR n: CARDINAL;
BEGIN
  n := Length(str);
  IF (n > 0) AND (str[n - 1] # ch) THEN AppendChar(ch, str) END
END AppendCharCond;

PROCEDURE AppendNum (num: CARDINAL; VAR str: ARRAY OF CHAR);
  VAR buf: ARRAY [0 .. 23] OF CHAR; i: CARDINAL;
BEGIN
  i := 0;
  REPEAT
    buf[i] := CHR(ORD('0') + (num MOD 10));
    num := num DIV 10; INC(i)
  UNTIL num = 0;
  WHILE i > 0 DO DEC(i); AppendChar(buf[i], str) END
END AppendNum;

PROCEDURE AppendHex (num, digits: CARDINAL; VAR str: ARRAY OF CHAR);
  VAR buf: ARRAY [0 .. 63] OF CHAR; i: CARDINAL;
BEGIN
  IF digits > 64 THEN digits := 64 END;
  i := 0;
  REPEAT
    buf[i] := HexDigit(num MOD 16);
    num := num DIV 16; INC(i)
  UNTIL num = 0;
  WHILE i < digits DO buf[i] := '0'; INC(i) END;   (* zero-pad up to `digits` *)
  i := digits;                                     (* emit exactly `digits` *)
  WHILE i > 0 DO DEC(i); AppendChar(buf[i], str) END
END AppendHex;

PROCEDURE Replace (find, replace: ARRAY OF CHAR; VAR str: ARRAY OF CHAR;
                   ci: BOOLEAN): BOOLEAN;
  VAR tmp: ARRAY [0 .. 511] OF CHAR;
      lf, lr, ls, pos, i, k: CARDINAL; found: BOOLEAN;
BEGIN
  lf := Length(find);
  IF lf = 0 THEN RETURN FALSE END;
  Find(find, str, 0, ci, found, pos);
  IF NOT found THEN RETURN FALSE END;
  lr := Length(replace); ls := Length(str);
  k := 0;
  i := 0;
  WHILE (i < pos) AND (k < HIGH(tmp)) DO tmp[k] := str[i]; INC(k); INC(i) END;
  i := 0;
  WHILE (i < lr) AND (k < HIGH(tmp)) DO tmp[k] := replace[i]; INC(k); INC(i) END;
  i := pos + lf;
  WHILE (i < ls) AND (k < HIGH(tmp)) DO tmp[k] := str[i]; INC(k); INC(i) END;
  tmp[k] := NUL;
  AssignNullTerm(tmp, str);
  RETURN TRUE
END Replace;

PROCEDURE FindAndReplace (find, replace: ARRAY OF CHAR;
                          VAR str: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Replace(find, replace, str, FALSE)
END FindAndReplace;

PROCEDURE FindAndReplaceI (find, replace: ARRAY OF CHAR;
                           VAR str: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Replace(find, replace, str, TRUE)
END FindAndReplaceI;

END ExStrings.
