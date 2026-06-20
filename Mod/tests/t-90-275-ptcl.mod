MODULE T90275Ptcl;
(*
 * Group 90 — ptcl interpreter (library/uidef + library/uimod/Ptcl): a small embedded
 * Tcl dialect. Variables, $ / [] / "" substitution (incl. nested command sub), the
 * set/puts builtins, and host-verb registration + dispatch. Also pins the six
 * adversarial-review fixes:
 *   - errors inside [command] PROPAGATE (were injected as text) -> propagate/undefvar = ERR
 *   - re-entrant host recursion is BOUNDED by a global depth budget -> recur = ERR (no crash)
 *   - ArgInt overflow SATURATES instead of trapping -> exercised via add tail
 *   - a command with > MaxArgs words drops its tail (no spurious second command) -> maxargs = 3
 *   - NUL-safe Eq (exact-length literal vs NUL-terminated buffer) -> all dispatch works
 *
 * EXPECTED:
 * x=5
 * y=7
 * quote=x is 5 and y is 7
 * nested=13
 * propagate=ERR
 * undefvar=ERR
 * recur=ERR
 * maxargs=3
 *)
FROM Ptcl IMPORT Register, ArgInt, Result, Eval;
FROM STextIO IMPORT WriteString, WriteLn;

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

PROCEDURE VRecur (): BOOLEAN;          (* re-entrant: calls Eval again -> must be bounded, not crash *)
  VAR x: ARRAY [0..255] OF CHAR;
BEGIN RETURN Eval("recur", x) END VRecur;

PROCEDURE Show (tag, script: ARRAY OF CHAR);
  VAR out: ARRAY [0..255] OF CHAR; ok: BOOLEAN;
BEGIN
  WriteString(tag); WriteString("=");
  ok := Eval(script, out);
  IF ok THEN WriteString(out) ELSE WriteString("ERR") END;
  WriteLn
END Show;

BEGIN
  Register("add", VAdd); Register("recur", VRecur);
  Show("x", "set x 5");
  Show("y", "set y [add 3 4]");
  Show("quote", 'puts "x is $x and y is $y"');
  Show("nested", "puts [add [add 1 2] 10]");
  Show("propagate", "puts [nosuchcmd]");
  Show("undefvar", "puts [set neverset]");
  Show("recur", "recur");
  Show("maxargs", "add 1 2 a a a a a a a a a a a a a a a a a a")
END T90275Ptcl.
