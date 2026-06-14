MODULE T90217WinrtSecureRandom;
(*
 * Group 90 — M2WINRT: SecureRandom, the OS CSPRNG via a DIRECT
 * Windows BCryptGenRandom call (system-preferred RNG) from M2 — no Rust shim.
 * Also exercises direct-Win32 binding at the JIT (and AOT) level. The RNG is
 * non-deterministic, so the assertions are PROPERTIES: a fill succeeds, two
 * draws differ, and rejection-sampled draws always land in range (incl. the
 * power-of-2 bound that takes the no-rejection path).
 *
 * EXPECTED:
 * fill ok: Y
 * distinct words: Y
 * NextBelow(100) in range 1000/1000
 * NextRange(10,20) in range 1000/1000
 * NextBelow(256) in range 1000/1000
 *)
FROM SecureRandom IMPORT FillBytes, NextCard, NextBelow, NextRange;
FROM SYSTEM IMPORT ADR;
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR i, a, b, inRange: CARDINAL; buf: ARRAY [0..31] OF BYTE; ok: BOOLEAN;
BEGIN
  ok := FillBytes(ADR(buf), 32);
  WriteString("fill ok: "); YN(ok); WriteLn;
  a := NextCard(); b := NextCard();
  WriteString("distinct words: "); YN(a # b); WriteLn;

  inRange := 0;
  FOR i := 1 TO 1000 DO IF NextBelow(100) < 100 THEN INC(inRange) END END;
  WriteString("NextBelow(100) in range 1000/"); WriteCard(inRange, 1); WriteLn;

  inRange := 0;
  FOR i := 1 TO 1000 DO a := NextRange(10, 20); IF (a >= 10) AND (a <= 20) THEN INC(inRange) END END;
  WriteString("NextRange(10,20) in range 1000/"); WriteCard(inRange, 1); WriteLn;

  inRange := 0;
  FOR i := 1 TO 1000 DO IF NextBelow(256) < 256 THEN INC(inRange) END END;
  WriteString("NextBelow(256) in range 1000/"); WriteCard(inRange, 1); WriteLn
END T90217WinrtSecureRandom.
