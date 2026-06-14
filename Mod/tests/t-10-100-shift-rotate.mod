MODULE t10100;
IMPORT STextIO, SWholeIO;
FROM SYSTEM IMPORT SHIFT, ROTATE;

VAR w : CARDINAL;

PROCEDURE Emit(label : ARRAY OF CHAR; n : CARDINAL);
BEGIN
  STextIO.WriteString(label);
  SWholeIO.WriteCard(n, 0);
  STextIO.WriteLn
END Emit;

BEGIN
  w := 1;   Emit("shl=", SHIFT(w, 4));    (* 16 *)
  w := 48;  Emit("shr=", SHIFT(w, -2));   (* 12 *)
  w := 1;   Emit("rol=", ROTATE(w, 4));   (* 16 *)
  w := 16;  Emit("ror=", ROTATE(w, -2));  (* 4 *)
  (* ROTATE wraps where SHIFT drops the bit: bit 0 rotated right 1 on a 64-bit
     CARDINAL lands in bit 63 = 2^63. *)
  w := 1;   Emit("wrap=", ROTATE(w, -1)); (* 9223372036854775808 *)
  w := 1;   Emit("drop=", SHIFT(w, -1))   (* 0 *)
END t10100.
