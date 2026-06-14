IMPLEMENTATION MODULE StdIO;

IMPORT STextIO;

PROCEDURE Read (VAR ch: CHAR);
BEGIN
  STextIO.ReadChar(ch)
END Read;

PROCEDURE Write (ch: CHAR);
BEGIN
  STextIO.WriteChar(ch)
END Write;

(* The redirection stack is not modelled; these are inert. *)

PROCEDURE PushOutput (p: ProcWrite);
BEGIN
END PushOutput;

PROCEDURE PopOutput;
BEGIN
END PopOutput;

PROCEDURE PushInput (p: ProcRead);
BEGIN
END PushInput;

PROCEDURE PopInput;
BEGIN
END PopInput;

END StdIO.
