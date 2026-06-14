MODULE T90216WinrtRandomNumbers;
(*
 * Group 90 — M2WINRT: RandomNumbers, the NON-cryptographic
 * lagged-Fibonacci PRNG. Known-answer: seed=1 the first five raw 64-bit words
 * are fixed; seed=12345 the first eight Rnd(100) draws are fixed; and the
 * generator is deterministic (same seed -> same sequence). The known-answer
 * words were cross-checked against an independent reference implementation.
 *
 * EXPECTED:
 * 16826983207204404568
 * 11868665664293886290
 * 15636431333310144292
 * 5703284894643461686
 * 7645942511238512128
 * 80 46 28 74 76 94 76 2
 * det Y
 *)
FROM RandomNumbers IMPORT Randomize, Rnd, RandomStream, SeedStream, RndStream;
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

VAR s, s2: RandomStream; i, a, b: CARDINAL; det: BOOLEAN;
BEGIN
  Randomize(1);
  FOR i := 1 TO 5 DO WriteCard(Rnd(0), 1); WriteLn END;
  SeedStream(s, 12345);
  FOR i := 1 TO 8 DO WriteCard(RndStream(s, 100), 1); IF i < 8 THEN WriteString(" ") END END;
  WriteLn;
  SeedStream(s, 999); SeedStream(s2, 999); det := TRUE;
  FOR i := 1 TO 50 DO
    a := RndStream(s, 0); b := RndStream(s2, 0);
    IF a # b THEN det := FALSE END
  END;
  WriteString("det "); IF det THEN WriteString("Y") ELSE WriteString("N") END; WriteLn
END T90216WinrtRandomNumbers.
