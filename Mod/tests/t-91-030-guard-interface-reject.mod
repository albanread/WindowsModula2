MODULE t91029;
(* Negative: GUARD on an interface selector is rejected. RTTI is native-only —
   an interface carries no typeinfo (it would need a QueryInterface probe, not
   yet implemented), so GUARD/ISMEMBER on an interface must be a compile error
   rather than reading a foreign COM vtable's slot. Regression for finding B2. *)
IMPORT STextIO;

INTERFACE IFoo;
  ABSTRACT PROCEDURE Bar() : INTEGER;
END IFoo;

VAR f : IFoo;

BEGIN
  GUARD f AS
    x : IFoo DO STextIO.WriteString("foo")
  END
END t91029.
