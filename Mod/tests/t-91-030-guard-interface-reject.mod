MODULE t91030;
(* Negative: a NATIVE-class arm on an INTERFACE selector is a compile error — a
   COM object can't be narrowed to a native class (there is no QI tear-off), so
   an interface GUARD's arms must themselves be interfaces. *)
IMPORT STextIO;

INTERFACE IFoo ["12345678-0000-0000-0000-000000000001"];
  ABSTRACT PROCEDURE QueryInterface () : INTEGER;
  ABSTRACT PROCEDURE AddRef () : INTEGER;
  ABSTRACT PROCEDURE Release () : INTEGER;
END IFoo;

CLASS Widget;
  VAR n : INTEGER;
END Widget;

VAR f : IFoo;

BEGIN
  GUARD f AS
    w : Widget DO STextIO.WriteString("widget")
  END
END t91030.
