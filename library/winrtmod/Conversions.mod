IMPLEMENTATION MODULE Conversions;

CONST NUL = CHR(0);

(* --- shared helpers ------------------------------------------------------ *)

PROCEDURE DigitChar (d: CARDINAL): CHAR;
  (* 0..9 -> '0'..'9', 10..15 -> 'A'..'F'. Upper-case alphabet for base > 10. *)
BEGIN
  IF d < 10 THEN
    RETURN CHR(ORD('0') + d)
  ELSE
    RETURN CHR(ORD('A') + (d - 10))
  END
END DigitChar;

PROCEDURE DigitVal (ch: CHAR): CARDINAL;
  (* Map a (case-folded) digit to its value, or 100 (>= any base) if not one. *)
  VAR c: CHAR;
BEGIN
  c := CAP(ch);
  IF (c >= '0') AND (c <= '9') THEN
    RETURN ORD(c) - ORD('0')
  ELSIF (c >= 'A') AND (c <= 'F') THEN
    RETURN ORD(c) - ORD('A') + 10
  ELSE
    RETURN 100
  END
END DigitVal;

PROCEDURE Capacity (VAR str: ARRAY OF CHAR): CARDINAL;
BEGIN
  RETURN HIGH(str) + 1
END Capacity;

(* Emit the magnitude `mag` (already non-negative) in `base` into `str` at
   `pos`, right-justified to at least `size` columns with a leading `sign`
   character ('-' or NUL) and space padding. Sets done := FALSE if `str` ran
   out of room. NUL-terminates if there is room. *)
PROCEDURE EmitNumber (mag, base, size: CARDINAL; sign: CHAR;
                      VAR str: ARRAY OF CHAR; VAR pos: CARDINAL;
                      VAR done: BOOLEAN);
  VAR buf: ARRAY [0 .. 79] OF CHAR;   (* binary of 64-bit + slack *)
      i, width, cap: CARDINAL;
BEGIN
  cap := Capacity(str);
  done := TRUE;
  (* digits least-significant first *)
  i := 0;
  REPEAT
    buf[i] := DigitChar(mag MOD base);
    mag := mag DIV base;
    INC(i)
  UNTIL mag = 0;
  (* total emitted width = digits + (sign, if any) *)
  width := i;
  IF sign # NUL THEN INC(width) END;
  (* left space padding up to `size` *)
  WHILE width < size DO
    IF pos < cap THEN str[pos] := ' '; INC(pos) ELSE done := FALSE END;
    INC(width)
  END;
  (* sign, then digits most-significant first *)
  IF sign # NUL THEN
    IF pos < cap THEN str[pos] := sign; INC(pos) ELSE done := FALSE END
  END;
  WHILE i > 0 DO
    DEC(i);
    IF pos < cap THEN str[pos] := buf[i]; INC(pos) ELSE done := FALSE END
  END;
  IF pos < cap THEN str[pos] := NUL END
END EmitNumber;

(* --- unsigned decimal (CARDINAL) ---------------------------------------- *)

PROCEDURE StringToCard (str: ARRAY OF CHAR; VAR pos: CARDINAL;
                        VAR num: CARDINAL; VAR done: BOOLEAN);
  VAR cap, d, lnum, maxv, lastv: CARDINAL; ch: CHAR; first: BOOLEAN;
BEGIN
  cap := Capacity(str);
  maxv := MAX(CARDINAL) DIV 10;
  lastv := MAX(CARDINAL) MOD 10;
  WHILE (pos < cap) AND (str[pos] = ' ') DO INC(pos) END;
  IF (pos < cap) AND (str[pos] = '+') THEN INC(pos) END;
  lnum := 0; first := TRUE; done := TRUE;
  LOOP
    IF pos >= cap THEN EXIT END;
    ch := str[pos];
    IF (ch < '0') OR (ch > '9') THEN EXIT END;     (* NUL stops here too *)
    d := ORD(ch) - ORD('0');
    IF (lnum > maxv) OR ((lnum = maxv) AND (d > lastv)) THEN
      done := FALSE; EXIT
    END;
    lnum := lnum * 10 + d;
    first := FALSE;
    INC(pos)
  END;
  IF first THEN done := FALSE END;
  num := lnum
END StringToCard;

PROCEDURE StrToCard (buf: ARRAY OF CHAR; VAR num: CARDINAL): BOOLEAN;
  VAR pos: CARDINAL; done: BOOLEAN;
BEGIN
  pos := 0;
  StringToCard(buf, pos, num, done);
  RETURN done AND ((pos > HIGH(buf)) OR (buf[pos] = NUL))
END StrToCard;

PROCEDURE CardToString (num, size: CARDINAL; VAR str: ARRAY OF CHAR;
                        VAR pos: CARDINAL; VAR done: BOOLEAN);
BEGIN
  EmitNumber(num, 10, size, NUL, str, pos, done)
END CardToString;

PROCEDURE CardToStr (num: CARDINAL; VAR str: ARRAY OF CHAR): BOOLEAN;
  VAR pos: CARDINAL; done: BOOLEAN;
BEGIN
  pos := 0;
  CardToString(num, 0, str, pos, done);
  RETURN done
END CardToStr;

(* --- signed decimal (INTEGER) ------------------------------------------- *)

PROCEDURE Magnitude (num: INTEGER): CARDINAL;
  (* |num| without overflowing on MIN(INTEGER): for negatives compute
     (-(num+1)) + 1 so the intermediate stays inside INTEGER. *)
BEGIN
  IF num < 0 THEN
    RETURN VAL(CARDINAL, -(num + 1)) + 1
  ELSE
    RETURN VAL(CARDINAL, num)
  END
END Magnitude;

PROCEDURE StringToInt (str: ARRAY OF CHAR; VAR pos: CARDINAL;
                       VAR num: INTEGER; VAR done: BOOLEAN);
  VAR cap, d, lnum, maxv, lastv: CARDINAL; ch: CHAR; first, neg: BOOLEAN;
BEGIN
  cap := Capacity(str);
  WHILE (pos < cap) AND (str[pos] = ' ') DO INC(pos) END;
  neg := FALSE;
  IF pos < cap THEN
    IF str[pos] = '-' THEN neg := TRUE; INC(pos)
    ELSIF str[pos] = '+' THEN INC(pos) END
  END;
  (* magnitude limit: |MIN| = |MAX|+1, so negatives allow one extra last digit *)
  IF neg THEN
    maxv := Magnitude(MIN(INTEGER)) DIV 10;
    lastv := Magnitude(MIN(INTEGER)) MOD 10
  ELSE
    maxv := VAL(CARDINAL, MAX(INTEGER)) DIV 10;
    lastv := VAL(CARDINAL, MAX(INTEGER)) MOD 10
  END;
  lnum := 0; first := TRUE; done := TRUE;
  LOOP
    IF pos >= cap THEN EXIT END;
    ch := str[pos];
    IF (ch < '0') OR (ch > '9') THEN EXIT END;
    d := ORD(ch) - ORD('0');
    IF (lnum > maxv) OR ((lnum = maxv) AND (d > lastv)) THEN
      done := FALSE; EXIT
    END;
    lnum := lnum * 10 + d;
    first := FALSE;
    INC(pos)
  END;
  IF first THEN done := FALSE END;
  IF neg THEN
    IF lnum = Magnitude(MIN(INTEGER)) THEN
      num := MIN(INTEGER)
    ELSE
      num := -VAL(INTEGER, lnum)
    END
  ELSE
    num := VAL(INTEGER, lnum)
  END
END StringToInt;

PROCEDURE StrToInt (buf: ARRAY OF CHAR; VAR num: INTEGER): BOOLEAN;
  VAR pos: CARDINAL; done: BOOLEAN;
BEGIN
  pos := 0;
  StringToInt(buf, pos, num, done);
  RETURN done AND ((pos > HIGH(buf)) OR (buf[pos] = NUL))
END StrToInt;

PROCEDURE IntToString (num: INTEGER; size: CARDINAL; VAR str: ARRAY OF CHAR;
                       VAR pos: CARDINAL; VAR done: BOOLEAN);
  VAR sign: CHAR;
BEGIN
  IF num < 0 THEN sign := '-' ELSE sign := NUL END;
  EmitNumber(Magnitude(num), 10, size, sign, str, pos, done)
END IntToString;

PROCEDURE IntToStr (num: INTEGER; VAR str: ARRAY OF CHAR): BOOLEAN;
  VAR pos: CARDINAL; done: BOOLEAN;
BEGIN
  pos := 0;
  IntToString(num, 0, str, pos, done);
  RETURN done
END IntToStr;

(* --- unsigned arbitrary base 2..16 (CARDINAL) --------------------------- *)

PROCEDURE StrBaseToCard (str: ARRAY OF CHAR; base: CARDINAL;
                         VAR num: CARDINAL): BOOLEAN;
  VAR cap, pos, d, lnum, maxv, lastv: CARDINAL; first: BOOLEAN;
BEGIN
  IF (base < 2) OR (base > 16) THEN RETURN FALSE END;
  cap := Capacity(str);
  maxv := MAX(CARDINAL) DIV base;
  lastv := MAX(CARDINAL) MOD base;
  pos := 0;
  WHILE (pos < cap) AND (str[pos] = ' ') DO INC(pos) END;
  lnum := 0; first := TRUE;
  LOOP
    IF pos >= cap THEN EXIT END;
    d := DigitVal(str[pos]);
    IF d >= base THEN EXIT END;                    (* non-digit / NUL / too big *)
    IF (lnum > maxv) OR ((lnum = maxv) AND (d > lastv)) THEN RETURN FALSE END;
    lnum := lnum * base + d;
    first := FALSE;
    INC(pos)
  END;
  IF first THEN RETURN FALSE END;
  num := lnum;
  RETURN TRUE
END StrBaseToCard;

PROCEDURE CardBaseToStr (num, base: CARDINAL; VAR str: ARRAY OF CHAR): BOOLEAN;
  VAR pos: CARDINAL; done: BOOLEAN;
BEGIN
  IF (base < 2) OR (base > 16) THEN RETURN FALSE END;
  pos := 0;
  EmitNumber(num, base, 0, NUL, str, pos, done);
  RETURN done
END CardBaseToStr;

END Conversions.
