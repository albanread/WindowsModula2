MODULE t91032;
(* Negative: ISMEMBER misuse on interfaces is rejected at compile time.
   - the target must be an interface TYPE name, not a variable;
   - a native class and a COM interface cannot be mixed. *)
IMPORT STextIO;

INTERFACE IFoo ["11111111-1111-1111-1111-111111111111"];
  ABSTRACT PROCEDURE QueryInterface () : INTEGER;
  ABSTRACT PROCEDURE AddRef () : INTEGER;
  ABSTRACT PROCEDURE Release () : INTEGER;
END IFoo;

CLASS Widget; VAR n : INTEGER; END Widget;

VAR f, g : IFoo; w : Widget;
BEGIN
  IF ISMEMBER(f, g) THEN STextIO.WriteString("a") END;     (* g is a variable -> TYPE name *)
  IF ISMEMBER(w, IFoo) THEN STextIO.WriteString("b") END   (* native vs interface -> cannot mix *)
END t91032.
