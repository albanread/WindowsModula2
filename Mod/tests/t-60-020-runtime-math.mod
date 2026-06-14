MODULE T60020RuntimeMath;
(*
 * Group 60 — runtime primitive call path. M2 calling an NM2.* runtime
 * primitive (qualified) through an rtdef DEFINITION MODULE. Exercises
 * Frexp/Ldexp (NM2Math -> nm2_math_frexp/ldexp) and LONGREAL comparison.
 *
 * EXPECTED:
 * 4
 * 1
 *)
IMPORT STextIO, SWholeIO, NM2Math;

VAR e : INTEGER;
    m, back : LONGREAL;
BEGIN
  m := NM2Math.Frexp(8.0, e);              (* m = 0.5, e = 4 *)
  SWholeIO.WriteInt(e, 0);
  STextIO.WriteLn;                         (* 4 *)

  back := NM2Math.Ldexp(m, e);             (* 0.5 * 2^4 = 8.0 *)
  IF back = 8.0 THEN
    SWholeIO.WriteInt(1, 0)
  ELSE
    SWholeIO.WriteInt(0, 0)
  END;
  STextIO.WriteLn;                         (* 1 *)
END T60020RuntimeMath.
