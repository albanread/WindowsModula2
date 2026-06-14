MODULE T20050Nested;
(* Group 20 — nested procedures. A non-capturing nested helper called from its
   enclosing procedure, including nested recursion. EXPECTED: 120 / 7 *)
IMPORT STextIO, WholeStr;
VAR s: ARRAY [0..31] OF CHAR;

PROCEDURE factorial(n: CARDINAL): CARDINAL;
  PROCEDURE step(acc, k: CARDINAL): CARDINAL;
  BEGIN
    IF k <= 1 THEN RETURN acc END;
    RETURN step(acc * k, k - 1);
  END step;
BEGIN
  RETURN step(1, n);
END factorial;

PROCEDURE addTwo(a, b: CARDINAL): CARDINAL;
  PROCEDURE inc(x: CARDINAL): CARDINAL;
  BEGIN
    RETURN x + 1;
  END inc;
BEGIN
  RETURN inc(a) + inc(b);
END addTwo;

BEGIN
  WholeStr.CardToStr(factorial(5), s); STextIO.WriteString(s); STextIO.WriteLn;
  WholeStr.CardToStr(addTwo(2, 3), s); STextIO.WriteString(s); STextIO.WriteLn;
END T20050Nested.
