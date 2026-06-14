MODULE T60015SetInclExcl;
(* Group 60 — INCL/EXCL pervasives + BITSET membership / empty constructor.
   EXPECTED: ynyn *)
IMPORT STextIO;
VAR s: BITSET;
PROCEDURE show(b: BOOLEAN);
BEGIN IF b THEN STextIO.WriteString("y") ELSE STextIO.WriteString("n") END; END show;
BEGIN
  s := BITSET{};
  INCL(s, 3); INCL(s, 5);
  show(3 IN s); show(4 IN s); show(5 IN s);
  EXCL(s, 3);
  show(3 IN s);
  STextIO.WriteLn;
END T60015SetInclExcl.
