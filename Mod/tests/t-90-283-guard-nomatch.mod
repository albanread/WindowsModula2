MODULE t90283;
(* GUARD with no matching arm and no ELSE raises the NewM2 guardException. The
   Dog object matches neither the (only) Cat arm, so "after" is never reached. *)
IMPORT STextIO;

ABSTRACT CLASS Animal;
  ABSTRACT PROCEDURE V() : INTEGER;
END Animal;

CLASS Dog;
  INHERIT Animal;
  OVERRIDE PROCEDURE V() : INTEGER;
  BEGIN RETURN 1 END V;
END Dog;

CLASS Cat;
  INHERIT Animal;
  OVERRIDE PROCEDURE V() : INTEGER;
  BEGIN RETURN 2 END V;
END Cat;

VAR a : Animal; d : Dog;

BEGIN
  NEW(d); a := d;
  GUARD a AS
    cc : Cat DO STextIO.WriteString("cat")
  END;
  STextIO.WriteString("after")
END t90283.
