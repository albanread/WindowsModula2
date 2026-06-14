MODULE T90188InlineEnumMembers;
(*
 * Group 90 — enumerations
 * Test: members of an anonymous enumeration used directly as an array element
 *       type are visible as ordinal constants in the enclosing scope and carry
 *       the right ordinals.
 *
 * EXPECTED:
 * 2
 * 0
 *)
FROM StrIO IMPORT WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR
  a: ARRAY [1..3] OF (one, two, three);
BEGIN
  a[1] := three;
  a[2] := one;
  WriteCard(ORD(a[1]), 0); WriteLn;
  WriteCard(ORD(a[2]), 0); WriteLn
END T90188InlineEnumMembers.
