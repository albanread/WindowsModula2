MODULE T90189EmptyVariantArms;
(*
 * Group 90 — variant records
 * Test: empty variant arms are tolerated (a leading run of `|` and `||`
 *       between arms). The record still selects the right field by tag.
 *
 * EXPECTED:
 * 65
 * 7
 *)
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteLn;

TYPE
  t = RECORD
        CASE tag: CARDINAL OF
      ||| 0 : a : CHAR;
        | 1 : b : CARDINAL;
        ELSE
        END
      END;

VAR r: t;
BEGIN
  r.tag := 0; r.a := 'A';
  WriteCard(ORD(r.a), 0); WriteLn;
  r.tag := 1; r.b := 7;
  WriteCard(r.b, 0); WriteLn
END T90189EmptyVariantArms.
