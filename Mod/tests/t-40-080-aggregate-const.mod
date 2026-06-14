MODULE T40080AggregateConst;
(*
 * Group 40 — Records / arrays
 * Test: structured constructors `T{...}` for RECORD and ARRAY constants —
 *       including a nested record — fold as aggregates and assign correctly.
 *
 * EXPECTED:
 * 5 9
 * 42 3 4
 * hi
 *)
FROM SWholeIO IMPORT WriteCard;
FROM STextIO IMPORT WriteString, WriteLn;

TYPE
  Arr    = ARRAY [0..4] OF CARDINAL;
  Pos    = RECORD x, y: CARDINAL END;
  Nested = RECORD tag: CARDINAL; p: Pos END;
  Str2   = ARRAY [0..1] OF CHAR;

CONST
  a = Arr{5, 6, 7, 8, 9};
  n = Nested{42, Pos{3, 4}};
  s = Str2{"h", "i"};

VAR
  va: Arr;
  vn: Nested;
  vs: Str2;

BEGIN
  va := a;
  WriteCard(va[0], 0); WriteString(" "); WriteCard(va[4], 0); WriteLn;
  vn := n;
  WriteCard(vn.tag, 0); WriteString(" ");
  WriteCard(vn.p.x, 0); WriteString(" "); WriteCard(vn.p.y, 0); WriteLn;
  vs := s;
  WriteString(vs); WriteLn
END T40080AggregateConst.
