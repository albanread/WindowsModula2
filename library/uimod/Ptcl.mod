IMPLEMENTATION MODULE Ptcl;

(* A small Tcl-dialect evaluator. Each command's words are parsed into a LOCAL array
   and the shared gArgs is set only just before dispatch, so nested [command]
   substitution (which recurses into Eval and uses gArgs for the inner command)
   never clobbers the outer command's words. *)

CONST
  MaxVars = 64; MaxCmds = 48;
  NameMax = 47;                 (* variable / command name length *)
  ValMax  = 1023;              (* variable value / result length *)
  MaxArgs = 16; ArgMax = 511;  (* words per command / word length *)
  DepthMax = 16;
  MaxProcs = 24;               (* user-defined `proc`s *)
  MaxParams = 6;               (* params bound per proc call (save/restore for recursion) *)
  MaxIters = 1000000;          (* `while` iteration cap (so a runaway loop can't hang the host) *)

TYPE
  EvalFn = PROCEDURE (ARRAY OF CHAR, VAR ARRAY OF CHAR): BOOLEAN;   (* = the signature of Eval *)

VAR
  gVarName: ARRAY [0..MaxVars-1] OF ARRAY [0..NameMax] OF CHAR;
  gVarVal:  ARRAY [0..MaxVars-1] OF ARRAY [0..ValMax] OF CHAR;
  gNVars:   CARDINAL;
  gCmdName: ARRAY [0..MaxCmds-1] OF ARRAY [0..NameMax] OF CHAR;
  gCmdProc: ARRAY [0..MaxCmds-1] OF CmdProc;
  gNCmds:   CARDINAL;
  gArgs:    ARRAY [0..MaxArgs-1] OF ARRAY [0..ArgMax] OF CHAR;
  gArgc:    CARDINAL;
  gResult:  ARRAY [0..ValMax] OF CHAR;
  gErrMsg:  ARRAY [0..ValMax] OF CHAR;
  gHasErr:  BOOLEAN;
  gDepth:   CARDINAL;                     (* live EvalRange activations — bounds ALL recursion (incl. re-entrant host verbs) *)
  gProcName: ARRAY [0..MaxProcs-1] OF ARRAY [0..NameMax] OF CHAR;   (* user `proc` table *)
  gProcParm: ARRAY [0..MaxProcs-1] OF ARRAY [0..ArgMax] OF CHAR;    (* its param-name list (space-separated) *)
  gProcBody: ARRAY [0..MaxProcs-1] OF ARRAY [0..ValMax] OF CHAR;    (* its body script *)
  gNProcs:  CARDINAL;
  gEvalHook: EvalFn;                      (* = Eval; lets expr run [..] without a forward decl of Eval *)

(* ---- small string helpers ---- *)
PROCEDURE Len (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR n: CARDINAL;
BEGIN n := 0; WHILE (n <= HIGH(s)) AND (s[n] # 0C) DO INC(n) END; RETURN n END Len;

PROCEDURE Copy (VAR d: ARRAY OF CHAR; VAR s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (i < HIGH(d)) AND (s[i] # 0C) DO d[i] := s[i]; INC(i) END; d[i] := 0C END Copy;

PROCEDURE CopyLit (VAR d: ARRAY OF CHAR; s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (i < HIGH(d)) AND (s[i] # 0C) DO d[i] := s[i]; INC(i) END; d[i] := 0C END CopyLit;

PROCEDURE Eq (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL; ca, cb: CHAR;
BEGIN
  i := 0;
  LOOP
    IF i > HIGH(a) THEN ca := 0C ELSE ca := a[i] END;   (* past end of array == NUL *)
    IF i > HIGH(b) THEN cb := 0C ELSE cb := b[i] END;
    IF ca # cb THEN RETURN FALSE END;
    IF ca = 0C THEN RETURN TRUE END;
    INC(i)
  END
END Eq;

PROCEDURE AppCh (VAR w: ARRAY OF CHAR; VAR wp: CARDINAL; c: CHAR);
BEGIN IF wp < HIGH(w) THEN w[wp] := c; INC(wp); w[wp] := 0C END END AppCh;

PROCEDURE IsNameCh (c: CHAR): BOOLEAN;
BEGIN RETURN ((c >= 'A') AND (c <= 'Z')) OR ((c >= 'a') AND (c <= 'z'))
          OR ((c >= '0') AND (c <= '9')) OR (c = '_') END IsNameCh;

PROCEDURE IntToStr (n: INTEGER; VAR s: ARRAY OF CHAR);
  VAR dig: ARRAY [0..31] OF CHAR; k, p, m: CARDINAL; neg: BOOLEAN;
BEGIN
  neg := n < 0; IF neg THEN m := VAL(CARDINAL, -n) ELSE m := VAL(CARDINAL, n) END;
  IF m = 0 THEN s[0] := '0'; s[1] := 0C; RETURN END;
  k := 0; WHILE m > 0 DO dig[k] := CHR((m MOD 10) + ORD('0')); m := m DIV 10; INC(k) END;
  p := 0; IF neg THEN s[0] := '-'; p := 1 END;
  WHILE k > 0 DO DEC(k); s[p] := dig[k]; INC(p) END; s[p] := 0C
END IntToStr;

(* ---- variables ---- *)
PROCEDURE FindVar (VAR name: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE i < gNVars DO IF Eq(gVarName[i], name) THEN RETURN i END; INC(i) END; RETURN MAX(CARDINAL) END FindVar;

PROCEDURE SetVar (name, val: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  IF Len(name) > NameMax THEN RETURN END;        (* refuse over-long names rather than truncate+alias distinct keys *)
  i := FindVar(name);
  IF i = MAX(CARDINAL) THEN
    IF gNVars >= MaxVars THEN RETURN END;
    i := gNVars; CopyLit(gVarName[i], name); INC(gNVars)
  END;
  CopyLit(gVarVal[i], val)
END SetVar;

PROCEDURE GetVar (name: ARRAY OF CHAR; VAR val: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := FindVar(name);
  IF i = MAX(CARDINAL) THEN val[0] := 0C; RETURN FALSE END;
  Copy(val, gVarVal[i]); RETURN TRUE
END GetVar;

(* ---- commands ---- *)
PROCEDURE Register (name: ARRAY OF CHAR; proc: CmdProc);
  VAR i: CARDINAL;
BEGIN
  i := 0; WHILE i < gNCmds DO IF Eq(gCmdName[i], name) THEN gCmdProc[i] := proc; RETURN END; INC(i) END;
  IF gNCmds >= MaxCmds THEN RETURN END;
  CopyLit(gCmdName[gNCmds], name); gCmdProc[gNCmds] := proc; INC(gNCmds)
END Register;

(* ---- user procs (define-time; the call lives inside Dispatch so it can run the body) ---- *)
PROCEDURE FindProc (VAR name: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE i < gNProcs DO IF Eq(gProcName[i], name) THEN RETURN i END; INC(i) END; RETURN MAX(CARDINAL) END FindProc;

PROCEDURE DefProc (name, parms, body: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := FindProc(name);
  IF i = MAX(CARDINAL) THEN
    IF gNProcs >= MaxProcs THEN RETURN END;
    i := gNProcs; CopyLit(gProcName[i], name); INC(gNProcs)
  END;
  CopyLit(gProcParm[i], parms); CopyLit(gProcBody[i], body)
END DefProc;

PROCEDURE Reset;
BEGIN gNVars := 0; gNProcs := 0 END Reset;

(* ---- CmdProc-facing accessors ---- *)
PROCEDURE Argc (): CARDINAL; BEGIN RETURN gArgc END Argc;

PROCEDURE Arg (i: CARDINAL; VAR s: ARRAY OF CHAR);
BEGIN IF i < gArgc THEN Copy(s, gArgs[i]) ELSE s[0] := 0C END END Arg;

PROCEDURE ArgInt (i: CARDINAL): INTEGER;
  VAR n, d: INTEGER; k: CARDINAL; neg: BOOLEAN;
BEGIN
  IF i >= gArgc THEN RETURN 0 END;
  k := 0; neg := FALSE; n := 0;
  IF gArgs[i][0] = '-' THEN neg := TRUE; k := 1 END;
  WHILE (gArgs[i][k] >= '0') AND (gArgs[i][k] <= '9') DO
    d := ORD(gArgs[i][k]) - ORD('0');
    IF n > (MAX(INTEGER) - d) DIV 10 THEN n := MAX(INTEGER)       (* saturate: never overflow/trap on a long digit run *)
    ELSE n := n*10 + d END;
    INC(k)
  END;
  IF neg THEN RETURN -n END; RETURN n
END ArgInt;

PROCEDURE Result (s: ARRAY OF CHAR); BEGIN CopyLit(gResult, s) END Result;
PROCEDURE Fail (msg: ARRAY OF CHAR); BEGIN CopyLit(gErrMsg, msg); gHasErr := TRUE END Fail;

(* ---- expr: a small infix integer/boolean expression (precedence climbing).
   $vars are substituted (the arg is usually braced, so unsubstituted, when it
   arrives); [..] is NOT evaluated inside expr — compute it into a var first.
   Operators (low->high): || && | == != | < <= > >= | + - | * / % | unary - ! ( ). *)
PROCEDURE EvalExpr (e: ARRAY OF CHAR; VAR result: INTEGER): BOOLEAN;
  VAR i, dp, np, kk, inLo, brk: CARDINAL; nm: ARRAY [0..NameMax] OF CHAR;
      val, sub: ARRAY [0..ValMax] OF CHAR; b: BOOLEAN;
      gEx: ARRAY [0..ValMax] OF CHAR;     (* LOCAL (not global) so nested expr via [..] is re-entrant *)
      gExPos: CARDINAL; gExErr: BOOLEAN;

  PROCEDURE ParseBin (minPrec: CARDINAL): INTEGER;
    VAR lhs, rhs: INTEGER; opc, prec, oplen: CARDINAL; c, c2: CHAR;

    PROCEDURE ParseAtom (): INTEGER;
      VAR v, d: INTEGER;
    BEGIN
      WHILE gEx[gExPos] = ' ' DO INC(gExPos) END;
      IF gEx[gExPos] = '-' THEN INC(gExPos); RETURN -ParseAtom()
      ELSIF gEx[gExPos] = '!' THEN INC(gExPos); IF ParseAtom() = 0 THEN RETURN 1 ELSE RETURN 0 END
      ELSIF gEx[gExPos] = '(' THEN
        INC(gExPos); v := ParseBin(0);
        WHILE gEx[gExPos] = ' ' DO INC(gExPos) END;
        IF gEx[gExPos] = ')' THEN INC(gExPos) ELSE gExErr := TRUE END;
        RETURN v
      ELSIF (gEx[gExPos] >= '0') AND (gEx[gExPos] <= '9') THEN
        v := 0;
        WHILE (gEx[gExPos] >= '0') AND (gEx[gExPos] <= '9') DO
          d := ORD(gEx[gExPos]) - ORD('0');
          IF v > (MAX(INTEGER) - d) DIV 10 THEN v := MAX(INTEGER) ELSE v := v*10 + d END;
          INC(gExPos)
        END;
        RETURN v
      ELSE gExErr := TRUE; RETURN 0 END
    END ParseAtom;

  BEGIN
    lhs := ParseAtom();
    LOOP
      IF gExErr THEN RETURN 0 END;
      WHILE gEx[gExPos] = ' ' DO INC(gExPos) END;
      c := gEx[gExPos]; IF gExPos < ValMax THEN c2 := gEx[gExPos+1] ELSE c2 := 0C END;
      opc := 0; oplen := 1; prec := 0;
      IF    (c='|') AND (c2='|') THEN opc:=1;  prec:=1; oplen:=2
      ELSIF (c='&') AND (c2='&') THEN opc:=2;  prec:=2; oplen:=2
      ELSIF (c='=') AND (c2='=') THEN opc:=3;  prec:=3; oplen:=2
      ELSIF (c='!') AND (c2='=') THEN opc:=4;  prec:=3; oplen:=2
      ELSIF (c='<') AND (c2='=') THEN opc:=6;  prec:=4; oplen:=2
      ELSIF (c='>') AND (c2='=') THEN opc:=8;  prec:=4; oplen:=2
      ELSIF  c='<'                THEN opc:=5;  prec:=4
      ELSIF  c='>'                THEN opc:=7;  prec:=4
      ELSIF  c='+'                THEN opc:=9;  prec:=5
      ELSIF  c='-'                THEN opc:=10; prec:=5
      ELSIF  c='*'                THEN opc:=11; prec:=6
      ELSIF  c='/'                THEN opc:=12; prec:=6
      ELSIF  c='%'                THEN opc:=13; prec:=6
      END;
      IF (opc = 0) OR (prec < minPrec) THEN EXIT END;
      gExPos := gExPos + oplen;
      rhs := ParseBin(prec + 1);                  (* left-assoc *)
      CASE opc OF
        1: IF (lhs#0) OR  (rhs#0) THEN lhs:=1 ELSE lhs:=0 END |
        2: IF (lhs#0) AND (rhs#0) THEN lhs:=1 ELSE lhs:=0 END |
        3: IF lhs =rhs THEN lhs:=1 ELSE lhs:=0 END |
        4: IF lhs #rhs THEN lhs:=1 ELSE lhs:=0 END |
        5: IF lhs <rhs THEN lhs:=1 ELSE lhs:=0 END |
        6: IF lhs<=rhs THEN lhs:=1 ELSE lhs:=0 END |
        7: IF lhs >rhs THEN lhs:=1 ELSE lhs:=0 END |
        8: IF lhs>=rhs THEN lhs:=1 ELSE lhs:=0 END |
        9:  lhs := lhs + rhs |
        10: lhs := lhs - rhs |
        11: lhs := lhs * rhs |
        12: IF rhs = 0 THEN gExErr := TRUE ELSE lhs := lhs DIV rhs END |
        13: IF rhs = 0 THEN gExErr := TRUE ELSE lhs := lhs MOD rhs END
      ELSE END
    END;
    RETURN lhs
  END ParseBin;

BEGIN
  i := 0; dp := 0; gExErr := FALSE;                (* substitute $vars and [..] from e into gEx *)
  WHILE (i <= HIGH(e)) AND (e[i] # 0C) DO
    IF e[i] = '$' THEN
      INC(i); np := 0;
      WHILE (i <= HIGH(e)) AND IsNameCh(e[i]) DO IF np < NameMax THEN nm[np] := e[i]; INC(np) END; INC(i) END;
      nm[np] := 0C; b := GetVar(nm, val);
      kk := 0; WHILE (val[kk] # 0C) AND (dp < ValMax-1) DO gEx[dp] := val[kk]; INC(dp); INC(kk) END
    ELSIF e[i] = '[' THEN                           (* command substitution inside expr (e.g. [fac $n]) *)
      INC(i); inLo := i; brk := 1;
      WHILE (i <= HIGH(e)) AND (e[i] # 0C) AND (brk > 0) DO
        IF e[i] = '[' THEN INC(brk) ELSIF e[i] = ']' THEN DEC(brk) END;
        IF brk > 0 THEN INC(i) END
      END;
      kk := 0; WHILE (inLo < i) AND (kk < ValMax) DO sub[kk] := e[inLo]; INC(kk); INC(inLo) END; sub[kk] := 0C;
      IF (i <= HIGH(e)) AND (e[i] = ']') THEN INC(i) END;   (* bounds-guard: scan may leave i = HIGH(e)+1 *)
      IF gEvalHook(sub, val) THEN
        kk := 0; WHILE (val[kk] # 0C) AND (dp < ValMax-1) DO gEx[dp] := val[kk]; INC(dp); INC(kk) END
      ELSE gExErr := TRUE END
    ELSE
      IF dp < ValMax-1 THEN gEx[dp] := e[i]; INC(dp) END; INC(i)
    END
  END;
  gEx[dp] := 0C;
  gExPos := 0;
  result := ParseBin(0);
  WHILE gEx[gExPos] = ' ' DO INC(gExPos) END;
  IF gEx[gExPos] # 0C THEN gExErr := TRUE END;      (* trailing junk -> error *)
  RETURN NOT gExErr
END EvalExpr;

(* ---- the evaluator ---- *)
PROCEDURE EvalRange (VAR s: ARRAY OF CHAR; lo, hi: CARDINAL; VAR out: ARRAY OF CHAR): BOOLEAN;
  VAR words: ARRAY [0..MaxArgs-1] OF ARRAY [0..ArgMax] OF CHAR;
      nw, i, k: CARDINAL; ok, subErr: BOOLEAN;

  (* substitute one element at s[j] into w (handles $name and [script]); advances j *)
  PROCEDURE SubstChar (VAR j: CARDINAL; VAR w: ARRAY OF CHAR; VAR wp: CARDINAL);
    VAR nm: ARRAY [0..NameMax] OF CHAR; np, brk, inLo, kk: CARDINAL;
        val: ARRAY [0..ValMax] OF CHAR; b: BOOLEAN;
  BEGIN
    IF s[j] = '$' THEN
      INC(j); np := 0;
      WHILE (j < hi) AND IsNameCh(s[j]) DO         (* consume the whole name; store up to NameMax (no truncate+alias) *)
        IF np < NameMax THEN nm[np] := s[j]; INC(np) END; INC(j)
      END;
      nm[np] := 0C;
      b := GetVar(nm, val);                       (* undefined -> empty *)
      kk := 0; WHILE (val[kk] # 0C) DO AppCh(w, wp, val[kk]); INC(kk) END
    ELSIF s[j] = '[' THEN
      INC(j); inLo := j; brk := 1;                (* find the matching ] *)
      WHILE (j < hi) AND (brk > 0) DO
        IF s[j] = '[' THEN INC(brk) ELSIF s[j] = ']' THEN DEC(brk) END;
        IF brk > 0 THEN INC(j) END
      END;
      b := EvalRange(s, inLo, j, val);             (* j = matching ]; gDepth bounds the recursion *)
      IF j < hi THEN INC(j) END;                   (* skip ] *)
      IF NOT b THEN subErr := TRUE; Copy(gErrMsg, val)   (* inner command failed -> propagate, don't inject error text *)
      ELSE kk := 0; WHILE (val[kk] # 0C) DO AppCh(w, wp, val[kk]); INC(kk) END END
    ELSE
      AppCh(w, wp, s[j]); INC(j)
    END
  END SubstChar;

  (* read one word at s[j] into w (with substitution unless braced); advances j *)
  PROCEDURE ReadWord (VAR j: CARDINAL; VAR w: ARRAY OF CHAR);
    VAR wp, br: CARDINAL;
  BEGIN
    wp := 0; w[0] := 0C;
    IF s[j] = '{' THEN
      br := 1; INC(j);
      WHILE (j < hi) AND (br > 0) DO
        IF s[j] = '{' THEN INC(br); AppCh(w, wp, s[j])
        ELSIF s[j] = '}' THEN DEC(br); IF br > 0 THEN AppCh(w, wp, s[j]) END
        ELSE AppCh(w, wp, s[j]) END;
        INC(j)
      END
    ELSIF s[j] = '"' THEN
      INC(j);
      WHILE (j < hi) AND (s[j] # '"') DO SubstChar(j, w, wp) END;
      IF j < hi THEN INC(j) END
    ELSE
      WHILE (j < hi) AND (s[j] # ' ') AND (s[j] # 011C) AND (s[j] # ';')
            AND (s[j] # CHR(10)) AND (s[j] # CHR(13)) DO
        SubstChar(j, w, wp)
      END
    END
  END ReadWord;

  (* dispatch the current gArgs: builtins, then user procs, then host verbs. Nested in
     EvalRange so the control-flow builtins can run their blocks via EvalRange (enclosing). *)
  PROCEDURE Dispatch (): BOOLEAN;
    VAR di, dp, q, sargc: CARDINAL; v, m: ARRAY [0..ValMax] OF CHAR;
        ev, amt: INTEGER; iters: CARDINAL;
        cond, body, blk: ARRAY [0..ArgMax] OF CHAR;

    PROCEDURE CallProc (pi: CARDINAL): BOOLEAN;       (* bind params (save/restore -> recursion-safe), run body *)
      VAR pn: ARRAY [0..MaxParams-1] OF ARRAY [0..NameMax] OF CHAR;
          sv: ARRAY [0..MaxParams-1] OF ARRAY [0..ValMax] OF CHAR;
          had: ARRAY [0..MaxParams-1] OF BOOLEAN;
          bodyc: ARRAY [0..ValMax] OF CHAR;
          n, pp, q, a: CARDINAL; r: BOOLEAN;
    BEGIN
      n := 0; pp := 0;                                (* parse param names from gProcParm[pi] *)
      LOOP
        WHILE gProcParm[pi][pp] = ' ' DO INC(pp) END;
        IF (gProcParm[pi][pp] = 0C) OR (n >= MaxParams) THEN EXIT END;
        q := 0;
        WHILE IsNameCh(gProcParm[pi][pp]) DO IF q < NameMax THEN pn[n][q] := gProcParm[pi][pp]; INC(q) END; INC(pp) END;
        pn[n][q] := 0C; INC(n)
      END;
      a := 0;                                         (* two passes: save ALL caller values first, *)
      WHILE a < n DO had[a] := GetVar(pn[a], sv[a]); INC(a) END;   (* (so duplicate param names can't lose the caller's value) *)
      a := 0;                                         (* then bind the args *)
      WHILE a < n DO
        IF a+1 < gArgc THEN SetVar(pn[a], gArgs[a+1]) ELSE SetVar(pn[a], "") END; INC(a)
      END;
      Copy(bodyc, gProcBody[pi]);
      r := EvalRange(bodyc, 0, Len(bodyc), gResult);
      a := 0;
      WHILE a < n DO                                  (* restore (recursion-safe) *)
        IF had[a] THEN SetVar(pn[a], sv[a]) ELSE SetVar(pn[a], "") END; INC(a)
      END;
      RETURN r
    END CallProc;

  BEGIN
    IF gArgc = 0 THEN gResult[0] := 0C; RETURN TRUE END;
    IF Eq(gArgs[0], "set") THEN
      IF gArgc >= 3 THEN SetVar(gArgs[1], gArgs[2]); Copy(gResult, gArgs[2])
      ELSIF gArgc = 2 THEN
        IF GetVar(gArgs[1], v) THEN Copy(gResult, v)
        ELSE Fail("no such variable"); RETURN FALSE END
      ELSE Fail("set: wrong # args"); RETURN FALSE END;
      RETURN TRUE
    ELSIF Eq(gArgs[0], "puts") THEN
      IF gArgc >= 2 THEN Copy(gResult, gArgs[1]) ELSE gResult[0] := 0C END; RETURN TRUE
    ELSIF Eq(gArgs[0], "incr") THEN                   (* incr name ?amt? -> add amt (default 1) to the var *)
      IF gArgc < 2 THEN Fail("incr: wrong # args"); RETURN FALSE END;
      sargc := gArgc; Copy(cond, gArgs[1]);           (* snapshot BEFORE EvalExpr (a [..] in the value re-enters EvalRange + clobbers gArgs) *)
      IF sargc >= 3 THEN Copy(body, gArgs[2]) ELSE body[0] := 0C END;
      IF NOT GetVar(cond, v) THEN v[0] := '0'; v[1] := 0C END;
      IF NOT EvalExpr(v, ev) THEN IF NOT gHasErr THEN Fail("incr: not an integer") END; RETURN FALSE END;
      IF sargc >= 3 THEN
        IF NOT EvalExpr(body, amt) THEN IF NOT gHasErr THEN Fail("incr: bad amount") END; RETURN FALSE END
      ELSE amt := 1 END;
      IF amt >= 0 THEN                                 (* saturating add: never overflow/trap *)
        IF ev > MAX(INTEGER) - amt THEN ev := MAX(INTEGER) ELSE ev := ev + amt END
      ELSE
        IF ev < MIN(INTEGER) - amt THEN ev := MIN(INTEGER) ELSE ev := ev + amt END
      END;
      IntToStr(ev, m); SetVar(cond, m); Copy(gResult, m); RETURN TRUE
    ELSIF Eq(gArgs[0], "expr") THEN
      dp := 0; di := 1;                               (* join args 1.. with spaces, then evaluate *)
      WHILE di < gArgc DO
        IF di > 1 THEN IF dp < ValMax THEN m[dp] := ' '; INC(dp) END END;
        q := 0; WHILE (gArgs[di][q] # 0C) AND (dp < ValMax) DO m[dp] := gArgs[di][q]; INC(dp); INC(q) END;
        INC(di)
      END;
      m[dp] := 0C;
      IF EvalExpr(m, ev) THEN IntToStr(ev, gResult); RETURN TRUE
      ELSE IF NOT gHasErr THEN Fail("expr: syntax error") END; RETURN FALSE END   (* keep a propagated inner error *)
    ELSIF Eq(gArgs[0], "if") THEN
      IF gArgc < 3 THEN Fail("if: wrong # args"); RETURN FALSE END;
      sargc := gArgc; Copy(cond, gArgs[1]); Copy(body, gArgs[2]);   (* snapshot then/else + argc BEFORE EvalExpr (a [..] in cond clobbers gArgs) *)
      IF sargc = 4 THEN Copy(blk, gArgs[3]) ELSIF sargc >= 5 THEN Copy(blk, gArgs[4]) ELSE blk[0] := 0C END;
      IF NOT EvalExpr(cond, ev) THEN IF NOT gHasErr THEN Fail("if: bad condition") END; RETURN FALSE END;
      IF ev # 0 THEN RETURN EvalRange(body, 0, Len(body), gResult)
      ELSIF sargc >= 4 THEN RETURN EvalRange(blk, 0, Len(blk), gResult)
      ELSE gResult[0] := 0C; RETURN TRUE END
    ELSIF Eq(gArgs[0], "while") THEN
      IF gArgc < 3 THEN Fail("while: wrong # args"); RETURN FALSE END;
      Copy(cond, gArgs[1]); Copy(body, gArgs[2]); iters := 0;
      LOOP
        IF NOT EvalExpr(cond, ev) THEN IF NOT gHasErr THEN Fail("while: bad condition") END; RETURN FALSE END;
        IF ev = 0 THEN EXIT END;
        IF NOT EvalRange(body, 0, Len(body), gResult) THEN RETURN FALSE END;
        INC(iters); IF iters >= MaxIters THEN Fail("while: too many iterations"); RETURN FALSE END
      END;
      gResult[0] := 0C; RETURN TRUE
    ELSIF Eq(gArgs[0], "proc") THEN
      IF gArgc < 4 THEN Fail("proc: wrong # args"); RETURN FALSE END;
      DefProc(gArgs[1], gArgs[2], gArgs[3]); gResult[0] := 0C; RETURN TRUE
    ELSE
      di := FindProc(gArgs[0]);
      IF di # MAX(CARDINAL) THEN RETURN CallProc(di) END;
      di := 0;
      WHILE di < gNCmds DO IF Eq(gCmdName[di], gArgs[0]) THEN RETURN gCmdProc[di]() END; INC(di) END;
      dp := 0; CopyLit(m, "unknown command: "); dp := Len(m);
      di := 0; WHILE (gArgs[0][di] # 0C) AND (dp < ValMax) DO m[dp] := gArgs[0][di]; INC(dp); INC(di) END; m[dp] := 0C;
      Fail(m); RETURN FALSE
    END
  END Dispatch;

BEGIN
  out[0] := 0C;
  INC(gDepth);                                          (* one budget for ALL nesting: [..] AND re-entrant host verbs *)
  IF gDepth > DepthMax THEN                             (* Fail (not just local out) so the message survives propagation up the re-entry chain *)
    DEC(gDepth); Fail("recursion too deep"); Copy(out, gErrMsg); RETURN FALSE
  END;
  subErr := FALSE;
  i := lo;
  LOOP
    WHILE (i < hi) AND ((s[i] = ' ') OR (s[i] = 011C) OR (s[i] = ';')
          OR (s[i] = CHR(10)) OR (s[i] = CHR(13))) DO INC(i) END;
    IF i >= hi THEN EXIT END;
    IF s[i] = '#' THEN
      WHILE (i < hi) AND (s[i] # CHR(10)) DO INC(i) END;
    ELSE
      nw := 0;
      LOOP
        WHILE (i < hi) AND ((s[i] = ' ') OR (s[i] = 011C)) DO INC(i) END;
        IF (i >= hi) OR (s[i] = ';') OR (s[i] = CHR(10)) OR (s[i] = CHR(13)) THEN EXIT END;
        IF nw >= MaxArgs THEN                           (* too many words: drop the tail so it isn't re-parsed as a new command *)
          WHILE (i < hi) AND (s[i] # ';') AND (s[i] # CHR(10)) AND (s[i] # CHR(13)) DO INC(i) END;
          EXIT
        END;
        ReadWord(i, words[nw]);
        IF subErr THEN EXIT END;                        (* an inner [..] failed -> stop reading words *)
        INC(nw)
      END;
      IF subErr THEN DEC(gDepth); Copy(out, gErrMsg); RETURN FALSE END;   (* propagate the inner failure *)
      IF nw > 0 THEN
        gArgc := nw; k := 0; WHILE k < nw DO Copy(gArgs[k], words[k]); INC(k) END;
        gHasErr := FALSE; gResult[0] := 0C;
        ok := Dispatch();
        IF (NOT ok) OR gHasErr THEN DEC(gDepth); Copy(out, gErrMsg); RETURN FALSE END;
        Copy(out, gResult)
      END
    END
  END;
  DEC(gDepth);
  RETURN TRUE
END EvalRange;

PROCEDURE Eval (script: ARRAY OF CHAR; VAR out: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN EvalRange(script, 0, Len(script), out) END Eval;

BEGIN
  gNVars := 0; gNCmds := 0; gNProcs := 0; gArgc := 0; gHasErr := FALSE; gDepth := 0;
  gResult[0] := 0C; gErrMsg[0] := 0C;
  gEvalHook := Eval;                       (* expr -> [..] command substitution, via an indirect call *)
END Ptcl.
