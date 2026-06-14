MODULE t90090;
(* LOCAL MODULE — encapsulated state (count), exported procedures,
   import from enclosing scope, and an initialization body that runs before the
   enclosing BEGIN. *)
IMPORT STextIO, SWholeIO;

MODULE Counter;
  IMPORT SWholeIO;
  EXPORT Bump, Value;
  VAR count : INTEGER;
  PROCEDURE Bump;
  BEGIN count := count + 1 END Bump;
  PROCEDURE Value() : INTEGER;
  BEGIN RETURN count END Value;
BEGIN
  count := 100        (* init body *)
END Counter;

BEGIN
  Bump; Bump;
  SWholeIO.WriteInt(Value(), 0); STextIO.WriteLn   (* 102 *)
END t90090.
