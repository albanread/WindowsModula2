MODULE t90280;
(* ISMEMBER over a 3-level hierarchy Animal(abstract) -> Dog -> Puppy, plus an
   unrelated Cat. Exercises all four operand combinations (value/type x
   value/type) AND the abstract-base typeinfo: `a` is statically Animal but
   dynamically Puppy, so the RTTI walk must reach the abstract Animal. *)
IMPORT STextIO;

ABSTRACT CLASS Animal;
  ABSTRACT PROCEDURE Speak() : INTEGER;
END Animal;

CLASS Dog;
  INHERIT Animal;
  OVERRIDE PROCEDURE Speak() : INTEGER;
  BEGIN RETURN 1 END Speak;
END Dog;

CLASS Puppy;
  INHERIT Dog;
  OVERRIDE PROCEDURE Speak() : INTEGER;
  BEGIN RETURN 2 END Speak;
END Puppy;

CLASS Cat;
  INHERIT Animal;
  OVERRIDE PROCEDURE Speak() : INTEGER;
  BEGIN RETURN 3 END Speak;
END Cat;

VAR a : Animal; p : Puppy;

PROCEDURE YN (b : BOOLEAN);
BEGIN
  IF b THEN STextIO.WriteString("Y") ELSE STextIO.WriteString("N") END
END YN;

BEGIN
  NEW(p);
  a := p;                       (* static Animal, dynamic Puppy *)

  (* (VALUE, TYPE): dynamic type of `a` is Puppy *)
  YN(ISMEMBER(a, Puppy));       (* Y *)
  YN(ISMEMBER(a, Dog));         (* Y *)
  YN(ISMEMBER(a, Animal));      (* Y - reaches the abstract base *)
  YN(ISMEMBER(a, Cat));         (* N *)
  STextIO.WriteLn;

  (* (TYPE, TYPE): static fold *)
  YN(ISMEMBER(Puppy, Animal));  (* Y *)
  YN(ISMEMBER(Puppy, Dog));     (* Y *)
  YN(ISMEMBER(Animal, Puppy));  (* N - base is not a member of derived *)
  YN(ISMEMBER(Dog, Cat));       (* N - unrelated *)
  STextIO.WriteLn;

  (* (VALUE, VALUE): both dynamic Puppy *)
  YN(ISMEMBER(p, a));           (* Y *)
  STextIO.WriteLn;

  (* (TYPE, VALUE): against `a`'s dynamic Puppy *)
  YN(ISMEMBER(Puppy, a));       (* Y *)
  YN(ISMEMBER(Dog, a));         (* N - Dog is not a Puppy *)
  STextIO.WriteLn
END t90280.
