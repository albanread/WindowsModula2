MODULE t90060;
IMPORT STextIO, SWholeIO;

CLASS Animal;
  VAR legs : INTEGER;
  PROCEDURE Speak() : INTEGER;
  BEGIN RETURN 1 END Speak;
  PROCEDURE Legs() : INTEGER;       (* not overridden *)
  BEGIN RETURN legs END Legs;
END Animal;

CLASS Dog;
  INHERIT Animal;
  VAR tail : INTEGER;
  OVERRIDE PROCEDURE Speak() : INTEGER;
  BEGIN RETURN 2 END Speak;
  PROCEDURE Wag() : INTEGER;        (* Dog-only method *)
  BEGIN RETURN tail END Wag;
END Dog;

VAR a : Animal; d : Dog;

PROCEDURE SpeakOf(x : Animal) : INTEGER;  (* polymorphic param *)
BEGIN
  RETURN x.Speak()
END SpeakOf;

BEGIN
  NEW(a); a.legs := 2;
  NEW(d); d.legs := 4; d.tail := 9;
  SWholeIO.WriteInt(a.Speak(), 0); STextIO.WriteLn;   (* 1 base *)
  SWholeIO.WriteInt(d.Speak(), 0); STextIO.WriteLn;   (* 2 override *)
  SWholeIO.WriteInt(d.Legs(), 0); STextIO.WriteLn;    (* 4 inherited method + field *)
  SWholeIO.WriteInt(d.Wag(), 0); STextIO.WriteLn;     (* 9 own method + field *)
  SWholeIO.WriteInt(SpeakOf(a), 0); STextIO.WriteLn;  (* 1 polymorphic *)
  SWholeIO.WriteInt(SpeakOf(d), 0); STextIO.WriteLn   (* 2 polymorphic override *)
END t90060.
