MODULE t10090;
IMPORT STextIO, SWholeIO;

(* A CARDINAL whose top bit is set must compare and divide as unsigned even
   when the other operand is an INTEGER literal. *)
VAR c : CARDINAL;

BEGIN
  c := MAX(CARDINAL);          (* all ones; signed view would be -1 *)
  IF c > 100 THEN
    STextIO.WriteString("big")
  ELSE
    STextIO.WriteString("small")
  END;
  STextIO.WriteLn;
  (* unsigned division: MAX(CARDINAL) DIV 2 has the top bit clear, > 0 *)
  IF (c DIV 2) > 1000000 THEN
    STextIO.WriteString("half-big")
  ELSE
    STextIO.WriteString("half-small")
  END;
  STextIO.WriteLn
END t10090.
