MODULE Calculator;
(*
 * A scientific calculator drawn with the Canvas2D Direct2D host. The interesting
 * part is the evaluator: a hand-written RECURSIVE-DESCENT parser over the typed
 * expression string, with the usual precedence (+ - below * / below ^, ^ right-
 * associative), unary minus, parentheses, the functions sin/cos/tan/ln/log/sqrt/
 * exp/abs and the constants pi and e. It exercises recursion, CASE/IF dispatch,
 * string scanning, RealMath, and ISO real<->string conversion.
 *
 * Click the buttons or type; Enter (or =) evaluates, C clears, the arrow deletes.
 *
 *   build: newm2 build demos/calculator.mod   then run the .exe
 *   click / type    build an expression        = or Enter   evaluate
 *   C clear         <- backspace               Esc quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  RunMessageLoop, Quit;
FROM Canvas2D IMPORT Startup, Attach, Begin, Flush, Clear, FillRect, DrawText;
FROM RealMath IMPORT sqrt, sin, cos, tan, ln, exp, power;
IMPORT RealStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  WinW = 384; WinH = 560;
  PI = 3.14159265358979; EE = 2.71828182845905;

  ActIns = 0; ActClear = 1; ActBack = 2; ActEval = 3;

  CDigit = 040444CH; COp = 0B5701EH; CFunc = 02A5A8AH;
  CClear = 0A83838H; CBack = 0803838H; CEq = 02E8B40H;

  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  WM_LBUTTONDOWN = 513;
  VK_RETURN = 0DH; VK_BACK = 08H; VK_ESCAPE = 1BH;

TYPE
  Btn = RECORD x, y, w, h: REAL; label, ins: ARRAY [0..7] OF CHAR; act, col: CARDINAL END;

VAR
  gWin:    Window;
  gExpr:   ARRAY [0..127] OF CHAR;   (* expression being edited / parser source *)
  gResult: ARRAY [0..63] OF CHAR;
  cur:     CARDINAL;                 (* parser cursor into gExpr *)
  ok:      BOOLEAN;                  (* parser success flag *)
  btn:     ARRAY [0..29] OF Btn;
  nBtn:    CARDINAL;
  Mrg, Gap, DH, GX, GY, BW, BH: REAL;

(* ---- string helpers ---------------------------------------------------- *)

PROCEDURE SCopy (VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (i < HIGH(dst)) AND (src[i] # 0C) DO dst[i] := src[i]; INC(i) END;
  dst[i] := 0C
END SCopy;

PROCEDURE SLen (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END; RETURN i END SLen;

PROCEDURE StrEq (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  LOOP
    IF (a[i] = 0C) AND (b[i] = 0C) THEN RETURN TRUE END;
    IF a[i] # b[i] THEN RETURN FALSE END;
    INC(i)
  END
END StrEq;

PROCEDURE AppendIns (s: ARRAY OF CHAR);
  VAR n, i: CARDINAL;
BEGIN
  n := SLen(gExpr); i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) AND (n < HIGH(gExpr)) DO
    gExpr[n] := s[i]; INC(n); INC(i)
  END;
  gExpr[n] := 0C
END AppendIns;

PROCEDURE Backspace;
  VAR n: CARDINAL;
BEGIN n := SLen(gExpr); IF n > 0 THEN gExpr[n-1] := 0C END END Backspace;

(* drop trailing zeros (and a bare '.') from a fixed-format number string *)
PROCEDURE Trim (VAR s: ARRAY OF CHAR);
  VAR i, dot, last: CARDINAL; hasDot: BOOLEAN;
BEGIN
  i := 0; hasDot := FALSE; dot := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO IF s[i] = '.' THEN hasDot := TRUE; dot := i END; INC(i) END;
  IF NOT hasDot THEN RETURN END;
  last := i;
  WHILE (last > dot + 1) AND (s[last-1] = '0') DO DEC(last) END;
  IF last = dot + 1 THEN last := dot END;
  s[last] := 0C
END Trim;

(* ---- recursive-descent evaluator (parser source = gExpr) --------------- *)

PROCEDURE Peek (): CHAR;
BEGIN IF cur <= HIGH(gExpr) THEN RETURN gExpr[cur] ELSE RETURN 0C END END Peek;
PROCEDURE Skip; BEGIN WHILE Peek() = ' ' DO INC(cur) END END Skip;

PROCEDURE ParseNumber (): REAL;
  VAR buf: ARRAY [0..31] OF CHAR; i: CARDINAL; v: REAL;
      res: RealStr.ConvResults; dig: BOOLEAN;
BEGIN
  i := 0; dig := FALSE;
  WHILE ((Peek() >= '0') AND (Peek() <= '9')) OR (Peek() = '.') DO
    IF Peek() # '.' THEN dig := TRUE END;
    IF i <= HIGH(buf)-1 THEN buf[i] := Peek(); INC(i) END; INC(cur)
  END;
  IF (Peek() = 'e') OR (Peek() = 'E') THEN          (* every store bounds-guarded, *)
    IF i <= HIGH(buf)-1 THEN buf[i] := Peek(); INC(i) END; INC(cur);   (* like the mantissa loop *)
    IF (Peek() = '+') OR (Peek() = '-') THEN
      IF i <= HIGH(buf)-1 THEN buf[i] := Peek(); INC(i) END; INC(cur)
    END;
    WHILE (Peek() >= '0') AND (Peek() <= '9') DO
      IF i <= HIGH(buf)-1 THEN buf[i] := Peek(); INC(i) END; INC(cur)
    END
  END;
  buf[i] := 0C;                                     (* i <= HIGH(buf) by the guards above *)
  IF NOT dig THEN ok := FALSE; RETURN 0.0 END;
  RealStr.StrToReal(buf, v, res);
  RETURN v
END ParseNumber;

PROCEDURE ApplyFunc (VAR name: ARRAY OF CHAR; a: REAL): REAL;
BEGIN
  IF    StrEq(name, "sqrt") THEN RETURN sqrt(a)
  ELSIF StrEq(name, "sin")  THEN RETURN sin(a)
  ELSIF StrEq(name, "cos")  THEN RETURN cos(a)
  ELSIF StrEq(name, "tan")  THEN RETURN tan(a)
  ELSIF StrEq(name, "ln")   THEN RETURN ln(a)
  ELSIF StrEq(name, "exp")  THEN RETURN exp(a)
  ELSIF StrEq(name, "log")  THEN RETURN ln(a) / ln(10.0)
  ELSIF StrEq(name, "abs")  THEN IF a < 0.0 THEN RETURN -a ELSE RETURN a END
  ELSE ok := FALSE; RETURN 0.0 END
END ApplyFunc;

PROCEDURE ParseIdent (): REAL;
  VAR name: ARRAY [0..15] OF CHAR; i: CARDINAL; arg: REAL;
BEGIN
  i := 0;
  WHILE ((Peek() >= 'a') AND (Peek() <= 'z')) OR ((Peek() >= 'A') AND (Peek() <= 'Z')) DO
    IF i <= HIGH(name)-1 THEN name[i] := Peek(); INC(i) END; INC(cur)
  END;
  name[i] := 0C; Skip;
  IF Peek() = '(' THEN
    INC(cur); arg := ParseExpr(); Skip;
    IF Peek() = ')' THEN INC(cur) ELSE ok := FALSE END;
    RETURN ApplyFunc(name, arg)
  ELSIF StrEq(name, "pi") THEN RETURN PI
  ELSIF StrEq(name, "e")  THEN RETURN EE
  ELSE ok := FALSE; RETURN 0.0 END
END ParseIdent;

PROCEDURE ParsePrimary (): REAL;
  VAR v: REAL; c: CHAR;
BEGIN
  Skip; c := Peek();
  IF c = '(' THEN
    INC(cur); v := ParseExpr(); Skip;
    IF Peek() = ')' THEN INC(cur) ELSE ok := FALSE END; RETURN v
  ELSIF ((c >= '0') AND (c <= '9')) OR (c = '.') THEN RETURN ParseNumber()
  ELSIF ((c >= 'a') AND (c <= 'z')) OR ((c >= 'A') AND (c <= 'Z')) THEN RETURN ParseIdent()
  ELSE ok := FALSE; RETURN 0.0 END
END ParsePrimary;

PROCEDURE ParseUnary (): REAL;
BEGIN
  Skip;
  IF Peek() = '-' THEN INC(cur); RETURN -ParseUnary()
  ELSIF Peek() = '+' THEN INC(cur); RETURN ParseUnary()
  ELSE RETURN ParsePrimary() END
END ParseUnary;

PROCEDURE ParsePower (): REAL;
  VAR b: REAL;
BEGIN
  b := ParseUnary(); Skip;
  IF Peek() = '^' THEN INC(cur); RETURN power(b, ParsePower()) ELSE RETURN b END
END ParsePower;

PROCEDURE ParseTerm (): REAL;
  VAR v, d: REAL;
BEGIN
  v := ParsePower();
  LOOP
    Skip;
    IF Peek() = '*' THEN INC(cur); v := v * ParsePower()
    ELSIF Peek() = '/' THEN INC(cur); d := ParsePower();
      IF d = 0.0 THEN ok := FALSE; RETURN 0.0 ELSE v := v / d END
    ELSE EXIT END
  END;
  RETURN v
END ParseTerm;

PROCEDURE ParseExpr (): REAL;
  VAR v: REAL;
BEGIN
  v := ParseTerm();
  LOOP
    Skip;
    IF Peek() = '+' THEN INC(cur); v := v + ParseTerm()
    ELSIF Peek() = '-' THEN INC(cur); v := v - ParseTerm()
    ELSE EXIT END
  END;
  RETURN v
END ParseExpr;

PROCEDURE Eval;
  VAR v: REAL;
BEGIN
  IF gExpr[0] = 0C THEN RETURN END;
  cur := 0; ok := TRUE;
  v := ParseExpr(); Skip;
  IF Peek() # 0C THEN ok := FALSE END;
  IF ok THEN RealStr.RealToFixed(v, 10, gResult); Trim(gResult)
  ELSE SCopy(gResult, "Error") END
END Eval;

(* ---- buttons + rendering ----------------------------------------------- *)

PROCEDURE AddBtn (c, r: CARDINAL; label, ins: ARRAY OF CHAR; act, colr: CARDINAL);
  VAR b: CARDINAL;
BEGIN
  b := nBtn;
  btn[b].x := GX + VAL(REAL, c) * (BW + Gap);
  btn[b].y := GY + VAL(REAL, r) * (BH + Gap);
  btn[b].w := BW; btn[b].h := BH;
  SCopy(btn[b].label, label); SCopy(btn[b].ins, ins);
  btn[b].act := act; btn[b].col := colr;
  INC(nBtn)
END AddBtn;

PROCEDURE InitButtons;
BEGIN
  Mrg := 10.0; Gap := 8.0; DH := 104.0;
  GX := Mrg; GY := DH + Mrg;
  BW := (VAL(REAL, WinW) - 2.0*Mrg - 4.0*Gap) / 5.0;
  BH := (VAL(REAL, WinH) - DH - 2.0*Mrg - 5.0*Gap) / 6.0;
  nBtn := 0;
  AddBtn(0,0,"sin","sin(",ActIns,CFunc);  AddBtn(1,0,"cos","cos(",ActIns,CFunc);
  AddBtn(2,0,"tan","tan(",ActIns,CFunc);   AddBtn(3,0,"ln","ln(",ActIns,CFunc);
  AddBtn(4,0,"log","log(",ActIns,CFunc);
  AddBtn(0,1,"(","(",ActIns,CFunc);        AddBtn(1,1,")",")",ActIns,CFunc);
  AddBtn(2,1,"^","^",ActIns,COp);          AddBtn(3,1,"sqrt","sqrt(",ActIns,CFunc);
  AddBtn(4,1,"pi","pi",ActIns,CFunc);
  AddBtn(0,2,"7","7",ActIns,CDigit);       AddBtn(1,2,"8","8",ActIns,CDigit);
  AddBtn(2,2,"9","9",ActIns,CDigit);       AddBtn(3,2,"/","/",ActIns,COp);
  AddBtn(4,2,"e","e",ActIns,CFunc);
  AddBtn(0,3,"4","4",ActIns,CDigit);       AddBtn(1,3,"5","5",ActIns,CDigit);
  AddBtn(2,3,"6","6",ActIns,CDigit);       AddBtn(3,3,"*","*",ActIns,COp);
  AddBtn(4,3,"C","",ActClear,CClear);
  AddBtn(0,4,"1","1",ActIns,CDigit);       AddBtn(1,4,"2","2",ActIns,CDigit);
  AddBtn(2,4,"3","3",ActIns,CDigit);       AddBtn(3,4,"-","-",ActIns,COp);
  AddBtn(4,4,"<-","",ActBack,CBack);
  AddBtn(0,5,"0","0",ActIns,CDigit);       AddBtn(1,5,".",".",ActIns,CDigit);
  AddBtn(2,5,"exp","exp(",ActIns,CFunc);   AddBtn(3,5,"+","+",ActIns,COp);
  AddBtn(4,5,"=","",ActEval,CEq)
END InitButtons;

PROCEDURE Render;
  VAR b: CARDINAL;
BEGIN
  Begin;
  Clear(01A1D22H);
  FillRect(Mrg, Mrg, VAL(REAL, WinW) - 2.0*Mrg, DH - Mrg, 0101418H);  (* display *)
  DrawText(Mrg + 8.0, Mrg + 6.0,  VAL(REAL, WinW) - 2.0*Mrg - 16.0, 30.0, 080C8FFH, gExpr);
  DrawText(Mrg + 8.0, Mrg + 46.0, VAL(REAL, WinW) - 2.0*Mrg - 16.0, 40.0, 0FFFFFFH, gResult);
  FOR b := 0 TO nBtn-1 DO
    FillRect(btn[b].x, btn[b].y, btn[b].w, btn[b].h, btn[b].col);
    DrawText(btn[b].x + 12.0, btn[b].y + btn[b].h*0.26, btn[b].w, btn[b].h, 0FFFFFFH, btn[b].label)
  END;
  Flush
END Render;

PROCEDURE DoAction (b: CARDINAL);
BEGIN
  CASE btn[b].act OF
    ActIns:   AppendIns(btn[b].ins)
  | ActClear: gExpr[0] := 0C; SCopy(gResult, "0")
  | ActBack:  Backspace
  | ActEval:  Eval
  END
END DoAction;

PROCEDURE Click (lParam: CARDINAL);
  VAR px, py, b: CARDINAL; fx, fy: REAL;
BEGIN
  px := lParam MOD 65536; py := lParam DIV 65536;
  fx := VAL(REAL, px); fy := VAL(REAL, py);
  FOR b := 0 TO nBtn-1 DO
    IF (fx >= btn[b].x) AND (fx < btn[b].x + btn[b].w)
       AND (fy >= btn[b].y) AND (fy < btn[b].y + btn[b].h) THEN
      DoAction(b); RETURN
    END
  END
END Click;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok2: BOOL; ch: CHAR; s: ARRAY [0..1] OF CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Render; ok2 := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_LBUTTONDOWN THEN
    Click(lParam); Repaint(w); RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF (ch = '=') OR (ch = CHR(VK_RETURN)) THEN Eval
    ELSIF ch = CHR(VK_BACK) THEN Backspace
    ELSIF (ch > ' ') AND (ch < CHR(127)) THEN s[0] := ch; s[1] := 0C; AppendIns(s)
    END;
    Repaint(w); RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF wParam = VK_ESCAPE THEN Quit END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, chh: CARDINAL; ok3: BOOLEAN;
BEGIN
  gExpr[0] := 0C; SCopy(gResult, "0");
  InitButtons;
  ok3 := Startup();
  gWin := CreateAppWindow("NewM2 Scientific Calculator", WinW + 16, WinH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, chh);
  IF NOT Attach(gWin, cw, chh) THEN HALT END;
  Repaint(gWin);
  RunMessageLoop()
END Calculator.
