MODULE t30050;
IMPORT STextIO, SWholeIO;

(* Dense explicit ordinal values (ADW form) are accepted because each equals
   its position; the enum behaves as an ordinary dense enumeration. *)
TYPE Color = (red = 0, green = 1, blue = 2);

VAR c : Color;

BEGIN
  c := blue;
  SWholeIO.WriteInt(ORD(c), 0);      (* 2 *)
  STextIO.WriteString(" ");
  SWholeIO.WriteInt(ORD(MAX(Color)), 0);  (* 2 *)
  STextIO.WriteLn
END t30050.
