(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-13 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - XDS source assumed 32-bit CARDINAL; on NewM2 (64-bit) MAX(CARDINAL)
       is 20 decimal digits. The local buffer in AppendCard has been
       widened from [0..11] (32-bit) to [0..20] (covers MAX(CARDINAL_64)
       = 18446744073709551615 plus a one-byte head margin).
     - All logic is otherwise unchanged. The algorithm is wordsize-clean:
       it uses MAX(CARDINAL), MAX(INTEGER), MIN(INTEGER) symbolically.
*)
IMPLEMENTATION MODULE WholeStr;

IMPORT ConvTypes, CharClass;

CONST ok = ConvTypes.strAllRight;

PROCEDURE StrToInt(s: ARRAY OF CHAR; VAR val: INTEGER; VAR res: ConvResults);
  VAR i, n, ord: CARDINAL; neg: BOOLEAN;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) & CharClass.IsWhiteSpace(s[i]) DO INC(i) END;
  IF (i > HIGH(s)) OR (s[i] = 0C) THEN res := ConvTypes.strEmpty; RETURN END;
  neg := s[i] = '-';
  IF neg OR (s[i] = '+') THEN INC(i) END;
  IF (i > HIGH(s)) OR NOT CharClass.IsNumeric(s[i]) THEN
    res := ConvTypes.strWrongFormat; RETURN
  END;
  n := 0; res := ok;
  WHILE (i <= HIGH(s)) & CharClass.IsNumeric(s[i]) DO
    IF res = ok THEN
      ord := ORD(s[i]) - ORD('0');
      IF n > (MAX(CARDINAL) - ord) DIV 10 THEN
        res := ConvTypes.strOutOfRange;
        IF neg THEN val := MIN(INTEGER) ELSE val := MAX(INTEGER) END;
      ELSE n := n * 10 + ord
      END;
    END;
    INC(i);
  END;
  IF (i <= HIGH(s)) & (s[i] # 0C) THEN res := ConvTypes.strWrongFormat;
  ELSIF res = ok THEN
    IF neg THEN
      IF n > VAL(CARDINAL, MAX(INTEGER)) + 1 THEN res := ConvTypes.strOutOfRange
      ELSIF n = VAL(CARDINAL, MAX(INTEGER)) + 1 THEN val := MIN(INTEGER)
      ELSE val := -INT(n)
      END;
    ELSIF n > VAL(CARDINAL, MAX(INTEGER)) THEN res := ConvTypes.strOutOfRange
    ELSE val := INT(n)
    END;
  END;
END StrToInt;

PROCEDURE StrToCard(s: ARRAY OF CHAR; VAR val: CARDINAL; VAR res: ConvResults);
  VAR i, n, ord: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) & CharClass.IsWhiteSpace(s[i]) DO INC(i) END;
  IF (i > HIGH(s)) OR (s[i] = 0C) THEN res := ConvTypes.strEmpty; RETURN
  ELSIF NOT CharClass.IsNumeric(s[i]) THEN
    res := ConvTypes.strWrongFormat; RETURN
  END;
  n := 0; res := ok;
  WHILE (i <= HIGH(s)) & CharClass.IsNumeric(s[i]) DO
    IF res = ok THEN
      ord := ORD(s[i]) - ORD('0');
      IF n > (MAX(CARDINAL) - ord) DIV 10 THEN
        res := ConvTypes.strOutOfRange; val := MAX(CARDINAL);
      ELSE n := n * 10 + ord
      END;
    END;
    INC(i);
  END;
  IF (i <= HIGH(s)) & (s[i] # 0C) THEN res := ConvTypes.strWrongFormat
  ELSIF res = ok THEN val := n
  END;
END StrToCard;

PROCEDURE AppendCard(x, n: CARDINAL; VAR str: ARRAY OF CHAR);
  (* 20 covers MAX(CARDINAL_64) = 18446744073709551615; XDS used [0..11] for 32-bit. *)
  VAR i: CARDINAL; a: ARRAY [0..20] OF CHAR;
BEGIN
  i := 0;
  REPEAT
    a[i] := CHR(x MOD 10 + ORD("0")); x := x DIV 10; INC(i)
  UNTIL x = 0;
  REPEAT DEC(i); str[n] := a[i]; INC(n) UNTIL (n > HIGH(str)) OR (i = 0);
  IF n <= HIGH(str) THEN str[n] := 0C END;
END AppendCard;

PROCEDURE CardToStr(card: CARDINAL; VAR str: ARRAY OF CHAR);
BEGIN
  AppendCard(card, 0, str);
END CardToStr;

PROCEDURE IntToStr(int: INTEGER; VAR str: ARRAY OF CHAR);
  VAR x, n: CARDINAL;
BEGIN
  IF int < 0 THEN
    n := 1; str[0] := '-';
    IF int = MIN(INTEGER) THEN x := MAX(INTEGER) + 1
    ELSE x := VAL(CARDINAL, -int)
    END;
  ELSE
    n := 0; x := VAL(CARDINAL, int);
  END;
  AppendCard(x, n, str);
END IntToStr;

END WholeStr.
