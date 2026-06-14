MODULE T10110AddressArith;
(*
 * Group 10 — Arithmetic
 * Test: SYSTEM.ADDRESS supports arithmetic operators (pointer arithmetic).
 *       Operands are pointers; results carry the ADDRESS type so they
 *       compare and store correctly.
 *
 * EXPECTED:
 * add
 * mod
 * mul
 *)
FROM SYSTEM IMPORT ADDRESS, ADR;
FROM STextIO IMPORT WriteString, WriteLn;

VAR
  x: CARDINAL;
  p, zero, one: ADDRESS;

BEGIN
  x := 5;
  p := ADR(x);
  zero := p - p;          (* 0 *)
  one  := p DIV p;        (* 1 *)
  IF (p + zero) = p     THEN WriteString("add"); WriteLn END;
  IF (p MOD p) = zero   THEN WriteString("mod"); WriteLn END;
  IF (zero * one) = zero THEN WriteString("mul"); WriteLn END
END T10110AddressArith.
