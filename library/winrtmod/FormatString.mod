IMPLEMENTATION MODULE FormatString;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM Conversions IMPORT CardToStr, IntToStr, CardBaseToStr;

CONST
  NUL = CHR(0);  CR = CHR(13);  LF = CHR(10);  TAB = CHR(9);

TYPE
  StrPtr = POINTER TO ARRAY [0 .. MAX(CARDINAL) - 1] OF CHAR;

(* ---- argument constructors ---- *)

PROCEDURE ArgCard (n: CARDINAL): FormatArg;
  VAR a: FormatArg;
BEGIN a.kind := argCard; a.num := n; a.str := NIL; RETURN a END ArgCard;

PROCEDURE ArgInt (n: INTEGER): FormatArg;
  VAR a: FormatArg;
BEGIN a.kind := argInt; a.num := CAST(CARDINAL, n); a.str := NIL; RETURN a END ArgInt;

PROCEDURE ArgHex (n: CARDINAL): FormatArg;
  VAR a: FormatArg;
BEGIN a.kind := argHex; a.num := n; a.str := NIL; RETURN a END ArgHex;

PROCEDURE ArgBool (b: BOOLEAN): FormatArg;
  VAR a: FormatArg;
BEGIN a.kind := argBool; IF b THEN a.num := 1 ELSE a.num := 0 END; a.str := NIL; RETURN a END ArgBool;

PROCEDURE ArgChar (c: CHAR): FormatArg;
  VAR a: FormatArg;
BEGIN a.kind := argChar; a.num := ORD(c); a.str := NIL; RETURN a END ArgChar;

PROCEDURE ArgStr (VAR s: ARRAY OF CHAR): FormatArg;
  VAR a: FormatArg;
BEGIN a.kind := argStr; a.num := 0; a.str := ADR(s); RETURN a END ArgStr;

(* ---- helpers ---- *)

PROCEDURE Length (s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # NUL) DO INC(i) END;
  RETURN i
END Length;

PROCEDURE Lower (VAR s: ARRAY OF CHAR);
  VAR i, n: CARDINAL;
BEGIN
  n := Length(s); i := 0;
  WHILE i < n DO
    IF (s[i] >= 'A') AND (s[i] <= 'Z') THEN s[i] := CHR(ORD(s[i]) + 32) END;
    INC(i)
  END
END Lower;

(* ---- formatter ---- *)

PROCEDURE Format (fmt: ARRAY OF CHAR; VAR dest: ARRAY OF CHAR;
                  args: ARRAY OF FormatArg; argCount: CARDINAL): BOOLEAN;
  VAR fi, di, ai, cap, width: CARDINAL;
      ok, left, zero, numeric, ignore: BOOLEAN;
      letter: CHAR;
      scratch: ARRAY [0 .. 79] OF CHAR;
      sp: StrPtr;

  PROCEDURE EmitCh (ch: CHAR);
  BEGIN
    IF di + 1 < cap THEN dest[di] := ch; INC(di) ELSE ok := FALSE END
  END EmitCh;

  (* Emit s[0..NUL) padded to `width`. Numeric zero-pad keeps a leading sign in
     front of the zeros (e.g. %05d of -42 -> "-0042"). *)
  PROCEDURE EmitField (VAR s: ARRAY OF CHAR; numericField: BOOLEAN);
    VAR slen, pad, k, start: CARDINAL; signed: BOOLEAN;
  BEGIN
    slen := Length(s);
    IF slen >= width THEN
      k := 0; WHILE k < slen DO EmitCh(s[k]); INC(k) END;
      RETURN
    END;
    pad := width - slen;
    IF left THEN
      k := 0; WHILE k < slen DO EmitCh(s[k]); INC(k) END;
      k := 0; WHILE k < pad DO EmitCh(' '); INC(k) END
    ELSIF zero AND numericField THEN
      start := 0;
      signed := (slen > 0) AND ((s[0] = '-') OR (s[0] = '+'));
      IF signed THEN EmitCh(s[0]); start := 1 END;
      k := 0; WHILE k < pad DO EmitCh('0'); INC(k) END;
      k := start; WHILE k < slen DO EmitCh(s[k]); INC(k) END
    ELSE
      k := 0; WHILE k < pad DO EmitCh(' '); INC(k) END;
      k := 0; WHILE k < slen DO EmitCh(s[k]); INC(k) END
    END
  END EmitField;

BEGIN
  cap := HIGH(dest) + 1; di := 0; ai := 0; ok := TRUE; fi := 0;
  WHILE (fi <= HIGH(fmt)) AND (fmt[fi] # NUL) DO
    IF fmt[fi] = '\' THEN
      INC(fi);
      IF (fi <= HIGH(fmt)) AND (fmt[fi] # NUL) THEN
        CASE fmt[fi] OF
          'n': EmitCh(CR); EmitCh(LF) |
          't': EmitCh(TAB) |
          'r': EmitCh(CR) |
          '\': EmitCh('\') |
          '"': EmitCh('"')
        ELSE
          EmitCh(fmt[fi])
        END;
        INC(fi)
      END
    ELSIF fmt[fi] = '%' THEN
      INC(fi);
      left := FALSE; zero := FALSE; width := 0;
      WHILE (fi <= HIGH(fmt)) AND ((fmt[fi] = '-') OR (fmt[fi] = '0')) DO
        IF fmt[fi] = '-' THEN left := TRUE ELSE zero := TRUE END;
        INC(fi)
      END;
      WHILE (fi <= HIGH(fmt)) AND (fmt[fi] >= '0') AND (fmt[fi] <= '9') DO
        width := width * 10 + (ORD(fmt[fi]) - ORD('0'));
        INC(fi)
      END;
      IF width > MaxWidth THEN width := MaxWidth END;
      IF fi <= HIGH(fmt) THEN
        letter := fmt[fi]; INC(fi);
        IF letter = '%' THEN
          EmitCh('%')
        ELSIF ai >= argCount THEN
          ok := FALSE                      (* more %-specs than arguments *)
        ELSE
          numeric := TRUE;
          CASE letter OF
            'd', 'i': ignore := IntToStr(CAST(INTEGER, args[ai].num), scratch) |
            'u'     : ignore := CardToStr(args[ai].num, scratch) |
            'x'     : ignore := CardBaseToStr(args[ai].num, 16, scratch); Lower(scratch) |
            'X'     : ignore := CardBaseToStr(args[ai].num, 16, scratch) |
            'b'     : IF args[ai].num # 0 THEN scratch := "TRUE" ELSE scratch := "FALSE" END; numeric := FALSE |
            'c'     : scratch[0] := CHR(args[ai].num); scratch[1] := NUL; numeric := FALSE
          ELSE
            scratch[0] := NUL; numeric := FALSE   (* unknown spec: empty *)
          END;
          IF letter = 's' THEN
            sp := CAST(StrPtr, args[ai].str);
            IF sp = NIL THEN
              scratch[0] := NUL; EmitField(scratch, FALSE)   (* NIL/non-string arg: empty *)
            ELSE
              EmitField(sp^, FALSE)
            END
          ELSE
            EmitField(scratch, numeric)
          END;
          INC(ai)
        END
      END
    ELSE
      EmitCh(fmt[fi]); INC(fi)
    END
  END;
  IF di < cap THEN dest[di] := NUL END;
  RETURN ok
END Format;

END FormatString.
