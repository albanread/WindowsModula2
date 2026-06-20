MODULE PtclTest;
(* Smoke-test the ptcl interpreter: variables, $ and [] and "" substitution,
   nested command substitution, and a registered host command. *)
FROM Ptcl IMPORT Register, Argc, Arg, ArgInt, Result, Eval;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;

PROCEDURE IntToStr (n: INTEGER; VAR s: ARRAY OF CHAR);
  VAR dig: ARRAY [0..31] OF CHAR; k, p, m: CARDINAL; neg: BOOLEAN;
BEGIN
  neg := n < 0; IF neg THEN m := VAL(CARDINAL, -n) ELSE m := VAL(CARDINAL, n) END;
  IF m = 0 THEN s[0] := '0'; s[1] := 0C; RETURN END;
  k := 0; WHILE m > 0 DO dig[k] := CHR((m MOD 10) + ORD('0')); m := m DIV 10; INC(k) END;
  p := 0; IF neg THEN s[0] := '-'; p := 1 END;
  WHILE k > 0 DO DEC(k); s[p] := dig[k]; INC(p) END; s[p] := 0C
END IntToStr;

PROCEDURE VAdd (): BOOLEAN;            (* add a b -> a+b *)
  VAR s: ARRAY [0..31] OF CHAR;
BEGIN IntToStr(ArgInt(1) + ArgInt(2), s); Result(s); RETURN TRUE END VAdd;

PROCEDURE VRecur (): BOOLEAN;          (* re-entrant verb: calls Eval again -> must be bounded, not crash *)
  VAR x: ARRAY [0..255] OF CHAR;
BEGIN RETURN Eval("recur", x) END VRecur;

PROCEDURE VBig (): BOOLEAN;            (* echo ArgInt(1) -> proves overflow saturates, no trap *)
  VAR s: ARRAY [0..31] OF CHAR;
BEGIN IntToStr(ArgInt(1), s); Result(s); RETURN TRUE END VBig;

PROCEDURE Run (script: ARRAY OF CHAR);
  VAR out: ARRAY [0..255] OF CHAR; ok: BOOLEAN;
BEGIN
  WriteString(script); WriteString("   =>   ");
  ok := Eval(script, out);
  IF NOT ok THEN WriteString("ERR: ") END;
  WriteString(out); WriteLn
END Run;

BEGIN
  Register("add", VAdd); Register("recur", VRecur); Register("big", VBig);
  Run("set x 5");
  Run("puts $x");
  Run("set y [add 3 4]");
  Run("puts $y");
  Run('puts "x is $x and y is $y"');
  Run("set z [add [add 1 2] 10]");
  Run("puts $z");
  Run("puts [add $x $z]");
  WriteLn; WriteString("-- review fixes --"); WriteLn;
  Run("puts [nosuchcmd]");                 (* error in [] now PROPAGATES (was: injected as text) *)
  Run("puts [set neverset]");              (* undefined var read in [] -> error propagates *)
  Run("recur");                            (* bounded re-entrant recursion -> 'recursion too deep', no crash *)
  Run("big 99999999999999999999");         (* ArgInt overflow saturates instead of trapping *)
  Run("add 1 2 a a a a a a a a a a a a a a a a a a");  (* >16 words: tail dropped, NOT re-parsed as 'unknown command: a' *)
  WriteLn; WriteString("-- control flow --"); WriteLn;
  Run("expr {3 + 4 * 2}");                  (* precedence -> 11 *)
  Run("expr {(3 + 4) * 2}");                (* parens -> 14 *)
  Run("expr {$x * $x}");                    (* $ in expr -> 25 *)
  Run("if {$x > 3} {puts big} {puts small}");          (* -> big *)
  Run("set s 0; set i 1; while {$i <= 5} {set s [expr {$s + $i}]; incr i}; puts $s");  (* sum 1..5 -> 15 *)
  Run("proc sq {n} {expr {$n * $n}}; puts [sq 7]");    (* user proc -> 49 *)
  Run("proc fac {n} {if {$n <= 1} {expr 1} {expr {$n * [fac [expr {$n - 1}]]}}}; puts [fac 5]");  (* recursive -> 120 *)
  WriteLn; WriteString("-- review-2 fixes --"); WriteLn;
  Run("proc t {} {expr 1}; if {[t] > 99} {puts THEN} {puts ELSE}");  (* [] in cond no longer clobbers else -> ELSE *)
  Run("expr {1 + [nope]}");                            (* propagated inner error, not generic 'syntax error' *)
  Run("set n 7; proc p {n n} {expr $n}; p 3 5; puts $n")  (* dup-param restore -> n back to 7 *)
END PtclTest.
