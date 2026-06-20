MODULE T90276PtclControl;
(*
 * Group 90 — ptcl control flow (library/uimod/Ptcl): the expr/if/while/proc/incr slice.
 *   - expr: precedence-climbing infix (+ - * / % , comparisons, && || ! , parens, unary -),
 *     with $var AND [command] substitution inside the expression.
 *   - if {cond} {then} ?{else}? ; while {cond} {body} (iteration-capped); incr name ?amt?.
 *   - proc name {params} {body} -> a user command; params save/restore so RECURSION works.
 *
 * EXPECTED:
 * prec=11
 * parens=14
 * exprvar=25
 * ifthen=big
 * ifelse=small
 * while=15
 * proc=49
 * recurse=120
 * ifcmd=ELSE
 * dupparm=7
 *)
FROM Ptcl IMPORT Eval;
FROM STextIO IMPORT WriteString, WriteLn;

PROCEDURE Show (tag, script: ARRAY OF CHAR);
  VAR out: ARRAY [0..255] OF CHAR; ok: BOOLEAN;
BEGIN
  WriteString(tag); WriteString("=");
  ok := Eval(script, out);
  IF ok THEN WriteString(out) ELSE WriteString("ERR") END;
  WriteLn
END Show;

BEGIN
  Show("prec",    "expr {3 + 4 * 2}");
  Show("parens",  "expr {(3 + 4) * 2}");
  Show("exprvar", "set x 5; expr {$x * $x}");
  Show("ifthen",  "if {5 > 3} {puts big} {puts small}");
  Show("ifelse",  "if {1 > 3} {puts big} {puts small}");
  Show("while",   "set s 0; set i 1; while {$i <= 5} {set s [expr {$s + $i}]; incr i}; puts $s");
  Show("proc",    "proc sq {n} {expr {$n * $n}}; puts [sq 7]");
  Show("recurse", "proc fac {n} {if {$n <= 1} {expr 1} {expr {$n * [fac [expr {$n - 1}]]}}}; puts [fac 5]");
  (* a [command] in the condition must NOT clobber the if's branch blocks (review fix) *)
  Show("ifcmd",   "proc t {} {expr 1}; if {[t] > 99} {puts THEN} {puts ELSE}");
  (* duplicate proc params must restore the caller's global correctly (review fix) *)
  Show("dupparm", "set n 7; proc p {n n} {expr $n}; p 3 5; puts $n")
END T90276PtclControl.
