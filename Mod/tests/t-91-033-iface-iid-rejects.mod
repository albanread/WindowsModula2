MODULE t91033;
(* Negative: IID rules.
   - a malformed IID literal is a compile error at the interface declaration;
   - an interface with no IID cannot be used as a GUARD arm (QI needs an IID). *)
IMPORT STextIO;

INTERFACE IBad ["not-a-valid-guid"];          (* malformed -> error at decl *)
  ABSTRACT PROCEDURE QueryInterface () : INTEGER;
  ABSTRACT PROCEDURE AddRef () : INTEGER;
  ABSTRACT PROCEDURE Release () : INTEGER;
END IBad;

INTERFACE INoIid;                             (* legal: an interface need not have an IID *)
  ABSTRACT PROCEDURE QueryInterface () : INTEGER;
  ABSTRACT PROCEDURE AddRef () : INTEGER;
  ABSTRACT PROCEDURE Release () : INTEGER;
END INoIid;

VAR s : INoIid;
BEGIN
  GUARD s AS
    x : INoIid DO STextIO.WriteString("x")    (* arm interface has no IID -> error *)
  END
END t91033.
