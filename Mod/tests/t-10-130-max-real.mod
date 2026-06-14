MODULE T10130MaxReal;
(*
 * Group 10 — Arithmetic / constants
 * Test: MAX(REAL) / MIN(REAL) fold to real extremes (not ordinal 0), so a
 *       CONST built from them is typed REAL and assigns to a REAL variable.
 *
 * EXPECTED:
 * big
 * small
 *)
FROM STextIO IMPORT WriteString, WriteLn;

CONST
  big   = MAX(REAL);
  small = MIN(REAL);

VAR r: REAL;

BEGIN
  r := big;
  IF r > 1.0E300 THEN WriteString("big") END; WriteLn;
  r := small;
  IF r < -1.0E300 THEN WriteString("small") END; WriteLn
END T10130MaxReal.
