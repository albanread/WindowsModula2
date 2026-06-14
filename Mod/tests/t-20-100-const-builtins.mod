MODULE t20100;
IMPORT STextIO, SWholeIO;

TYPE Color = (red, green, blue, white);
     Digit = [0..9];

CONST
  MaxI8  = MAX(INTEGER8);     (* 127 *)
  MinI16 = MIN(INTEGER16);    (* -32768 *)
  SzI32  = SIZE(INTEGER32);   (* 4 *)
  SzChar = TSIZE(CHAR);       (* 2 *)
  MaxCol = MAX(Color);        (* 3 = ORD(white) *)
  MaxDig = MAX(Digit);        (* 9 *)
  MinDig = MIN(Digit);        (* 0 *)
  Span   = MAX(Digit) - MIN(Digit) + 1;  (* 10 — folded arithmetic *)

PROCEDURE Emit(label : ARRAY OF CHAR; n : INTEGER);
BEGIN
  STextIO.WriteString(label);
  SWholeIO.WriteInt(n, 0);
  STextIO.WriteLn
END Emit;

BEGIN
  Emit("MaxI8=", MaxI8);
  Emit("MinI16=", MinI16);
  Emit("SzI32=", SzI32);
  Emit("SzChar=", SzChar);
  Emit("MaxCol=", MaxCol);
  Emit("MaxDig=", MaxDig);
  Emit("MinDig=", MinDig);
  Emit("Span=", Span)
END t20100.
