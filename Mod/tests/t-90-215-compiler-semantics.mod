MODULE T90215CompilerSemantics;
(*
 * Group 90 — language-semantics rules:
 *  1. Boolean AND/OR/& MUST short-circuit (Modula-2 conditional evaluation):
 *     `FALSE AND f()` / `TRUE OR f()` must NOT call f().
 *  2. REAL `#` is UNORDERED not-equal: `NaN # NaN` is TRUE and is the exact
 *     negation of `=`.
 *  3. CARDINAL DIV/MOD by a non-negative named CONST is UNSIGNED (a dividend
 *     with bit 63 set must not be treated as a negative signed value).
 *
 * EXPECTED:
 * sc 0 0 0
 * nan N Y
 * negprop ok
 * udiv 922337203685478 807
 *)
FROM SpecialReals IMPORT Infinity;
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

CONST Scale = 10000;
VAR calls: CARDINAL; nan: REAL; mag: CARDINAL;

PROCEDURE Side (): BOOLEAN;
BEGIN INC(calls); RETURN TRUE END Side;
PROCEDURE YN (b: BOOLEAN);
BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

BEGIN
  WriteString("sc ");
  calls := 0; IF FALSE AND Side() THEN END; WriteCard(calls, 1); WriteString(" ");
  calls := 0; IF TRUE OR Side() THEN END; WriteCard(calls, 1); WriteString(" ");
  calls := 0; IF FALSE & Side() THEN END; WriteCard(calls, 1); WriteLn;

  nan := Infinity - Infinity;
  WriteString("nan "); YN(nan = nan); WriteString(" "); YN(nan # nan); WriteLn;

  WriteString("negprop ");
  IF (nan # nan) = (NOT (nan = nan)) THEN WriteString("ok") ELSE WriteString("BAD") END; WriteLn;

  mag := 7FFFFFFFFFFFFFFFH; mag := mag + 5000;   (* bit 63 now set *)
  WriteString("udiv "); WriteCard(mag DIV Scale, 1); WriteString(" "); WriteCard(mag MOD Scale, 1); WriteLn
END T90215CompilerSemantics.
