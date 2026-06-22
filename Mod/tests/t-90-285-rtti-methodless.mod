MODULE t90285;
(* RTTI on a FIELD-ONLY (method-less) class hierarchy. A concrete class with no
   methods still carries typeinfo (a [typeinfo]-only vtable), so ISMEMBER/GUARD
   answer correctly instead of always FALSE. Regression for review finding B1. *)
IMPORT STextIO;

CLASS Base;
  VAR id : INTEGER;
END Base;

CLASS Leaf;
  INHERIT Base;
  VAR extra : INTEGER;
END Leaf;

VAR b : Base; lf : Leaf;

PROCEDURE YN (x : BOOLEAN);
BEGIN
  IF x THEN STextIO.WriteString("Y") ELSE STextIO.WriteString("N") END
END YN;

BEGIN
  NEW(lf); b := lf;          (* static Base, dynamic Leaf *)
  YN(ISMEMBER(b, Leaf));     (* Y - dynamic Leaf is-a Leaf *)
  YN(ISMEMBER(b, Base));     (* Y - Leaf is-a Base *)
  YN(ISMEMBER(lf, Leaf));    (* Y - own type *)
  STextIO.WriteLn;
  GUARD b AS
    l : Leaf DO STextIO.WriteString("leaf")
  ELSE
    STextIO.WriteString("base")
  END;
  STextIO.WriteLn
END t90285.
