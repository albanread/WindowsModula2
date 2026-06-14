MODULE T90251ExprEval;
(*
 * Group 90 — a recursive-descent expression evaluator (the engine behind
 * demos/calculator.mod). Exercises mutual recursion via in-module forward
 * references (ParseNumber/ParseIdent call ParseExpr defined later), operator
 * precedence (+ - < * / < ^, ^ right-assoc), unary minus, parentheses, the
 * RealMath functions, and ISO real<->string conversion. Only exact-valued
 * expressions are used so the printed strings are deterministic.
 *
 * EXPECTED:
 * 1+2*3 = 7
 * (1+2)*3 = 9
 * 100-58 = 42
 * 2*-3+5 = -1
 * 10/4 = 2.5
 * 3*(4+5)-6/2 = 24
 * sqrt(16) = 4
 * abs(-5) = 5
 * 2.5*4 = 10
 * 1/0 = Error
 * 2+ = Error
 *)
FROM STextIO IMPORT WriteString, WriteLn;
FROM RealMath IMPORT sqrt, sin, cos, tan, ln, exp, power;
IMPORT RealStr;

CONST PI = 3.14159265358979; EE = 2.71828182845905;
VAR src: ARRAY [0..127] OF CHAR; cur: CARDINAL; ok: BOOLEAN;

PROCEDURE Peek (): CHAR;
BEGIN IF cur <= HIGH(src) THEN RETURN src[cur] ELSE RETURN 0C END END Peek;
PROCEDURE Skip; BEGIN WHILE Peek() = ' ' DO INC(cur) END END Skip;
PROCEDURE StrEq (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN i := 0;
  LOOP IF (a[i]=0C) AND (b[i]=0C) THEN RETURN TRUE END;
    IF a[i]#b[i] THEN RETURN FALSE END; INC(i) END
END StrEq;

PROCEDURE ParseNumber (): REAL;
  VAR buf: ARRAY [0..31] OF CHAR; i: CARDINAL; v: REAL; res: RealStr.ConvResults; dig: BOOLEAN;
BEGIN
  i := 0; dig := FALSE;
  WHILE ((Peek()>='0') AND (Peek()<='9')) OR (Peek()='.') DO
    IF Peek()#'.' THEN dig := TRUE END;
    IF i <= HIGH(buf)-1 THEN buf[i] := Peek(); INC(i) END; INC(cur) END;
  buf[i] := 0C;
  IF NOT dig THEN ok := FALSE; RETURN 0.0 END;
  RealStr.StrToReal(buf, v, res); RETURN v
END ParseNumber;

PROCEDURE ApplyFunc (VAR name: ARRAY OF CHAR; a: REAL): REAL;
BEGIN
  IF StrEq(name,"sqrt") THEN RETURN sqrt(a)
  ELSIF StrEq(name,"sin") THEN RETURN sin(a)
  ELSIF StrEq(name,"cos") THEN RETURN cos(a)
  ELSIF StrEq(name,"ln") THEN RETURN ln(a)
  ELSIF StrEq(name,"exp") THEN RETURN exp(a)
  ELSIF StrEq(name,"abs") THEN IF a<0.0 THEN RETURN -a ELSE RETURN a END
  ELSE ok := FALSE; RETURN 0.0 END
END ApplyFunc;

PROCEDURE ParseIdent (): REAL;
  VAR name: ARRAY [0..15] OF CHAR; i: CARDINAL; arg: REAL;
BEGIN
  i := 0;
  WHILE ((Peek()>='a') AND (Peek()<='z')) OR ((Peek()>='A') AND (Peek()<='Z')) DO
    IF i <= HIGH(name)-1 THEN name[i] := Peek(); INC(i) END; INC(cur) END;
  name[i] := 0C; Skip;
  IF Peek()='(' THEN INC(cur); arg := ParseExpr(); Skip;
    IF Peek()=')' THEN INC(cur) ELSE ok := FALSE END; RETURN ApplyFunc(name, arg)
  ELSIF StrEq(name,"pi") THEN RETURN PI
  ELSIF StrEq(name,"e") THEN RETURN EE
  ELSE ok := FALSE; RETURN 0.0 END
END ParseIdent;

PROCEDURE ParsePrimary (): REAL;
  VAR v: REAL; c: CHAR;
BEGIN Skip; c := Peek();
  IF c='(' THEN INC(cur); v := ParseExpr(); Skip;
    IF Peek()=')' THEN INC(cur) ELSE ok := FALSE END; RETURN v
  ELSIF ((c>='0') AND (c<='9')) OR (c='.') THEN RETURN ParseNumber()
  ELSIF ((c>='a') AND (c<='z')) OR ((c>='A') AND (c<='Z')) THEN RETURN ParseIdent()
  ELSE ok := FALSE; RETURN 0.0 END
END ParsePrimary;

PROCEDURE ParseUnary (): REAL;
BEGIN Skip;
  IF Peek()='-' THEN INC(cur); RETURN -ParseUnary()
  ELSIF Peek()='+' THEN INC(cur); RETURN ParseUnary()
  ELSE RETURN ParsePrimary() END
END ParseUnary;

PROCEDURE ParsePower (): REAL;
  VAR b: REAL;
BEGIN b := ParseUnary(); Skip;
  IF Peek()='^' THEN INC(cur); RETURN power(b, ParsePower()) ELSE RETURN b END
END ParsePower;

PROCEDURE ParseTerm (): REAL;
  VAR v, d: REAL;
BEGIN v := ParsePower();
  LOOP Skip;
    IF Peek()='*' THEN INC(cur); v := v * ParsePower()
    ELSIF Peek()='/' THEN INC(cur); d := ParsePower();
      IF d=0.0 THEN ok := FALSE; RETURN 0.0 ELSE v := v/d END
    ELSE EXIT END END;
  RETURN v
END ParseTerm;

PROCEDURE ParseExpr (): REAL;
  VAR v: REAL;
BEGIN v := ParseTerm();
  LOOP Skip;
    IF Peek()='+' THEN INC(cur); v := v + ParseTerm()
    ELSIF Peek()='-' THEN INC(cur); v := v - ParseTerm()
    ELSE EXIT END END;
  RETURN v
END ParseExpr;

PROCEDURE Trim (VAR s: ARRAY OF CHAR);
  VAR i, dot, last: CARDINAL; hasDot: BOOLEAN;
BEGIN i := 0; hasDot := FALSE; dot := 0;
  WHILE (i <= HIGH(s)) AND (s[i]#0C) DO IF s[i]='.' THEN hasDot := TRUE; dot := i END; INC(i) END;
  IF NOT hasDot THEN RETURN END;
  last := i; WHILE (last > dot+1) AND (s[last-1]='0') DO DEC(last) END;
  IF last = dot+1 THEN last := dot END; s[last] := 0C
END Trim;

PROCEDURE Eval (e: ARRAY OF CHAR);
  VAR v: REAL; i: CARDINAL; buf: ARRAY [0..63] OF CHAR;
BEGIN
  i := 0; WHILE (i <= HIGH(e)) AND (e[i]#0C) DO src[i] := e[i]; INC(i) END; src[i] := 0C;
  cur := 0; ok := TRUE; v := ParseExpr(); Skip;
  IF Peek()#0C THEN ok := FALSE END;
  WriteString(e); WriteString(" = ");
  IF ok THEN RealStr.RealToFixed(v, 10, buf); Trim(buf); WriteString(buf) ELSE WriteString("Error") END;
  WriteLn
END Eval;

BEGIN
  Eval("1+2*3"); Eval("(1+2)*3"); Eval("100-58"); Eval("2*-3+5"); Eval("10/4");
  Eval("3*(4+5)-6/2"); Eval("sqrt(16)"); Eval("abs(-5)"); Eval("2.5*4");
  Eval("1/0"); Eval("2+")
END T90251ExprEval.
