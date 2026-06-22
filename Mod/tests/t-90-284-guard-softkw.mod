MODULE t90284;
(* GUARD / AS / ISMEMBER are SOFT keywords: identifiers spelled guard, as,
   ismember (and even uppercase GUARD in non-statement-start position) keep
   working as ordinary variables. *)
IMPORT STextIO;
FROM SWholeIO IMPORT WriteInt;

VAR guard, as, ismember, GUARD : INTEGER;

BEGIN
  guard := 10;                 (* `guard :=` is an assignment, not a GUARD stmt *)
  as := 20;
  ismember := guard + as;      (* lowercase ismember is a plain variable *)
  GUARD := 5;                  (* even uppercase GUARD, when followed by :=, is a var *)
  guard := guard + GUARD;
  WriteInt(ismember, 0); STextIO.WriteLn;   (* 30 *)
  WriteInt(guard, 0); STextIO.WriteLn        (* 15 *)
END t90284.
