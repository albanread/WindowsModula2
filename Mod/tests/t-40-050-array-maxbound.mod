MODULE t40050;
IMPORT STextIO, SWholeIO;

(* Static array bound derived from a type builtin: [0..MAX(INTEGER8)] has
   128 elements (indices 0..127). *)
TYPE Buf = ARRAY [0..MAX(INTEGER8)] OF INTEGER;

VAR b : Buf; i, sum : INTEGER;

BEGIN
  sum := 0;
  FOR i := 0 TO MAX(INTEGER8) DO
    b[i] := i;
    sum := sum + b[i]
  END;
  (* sum of 0..127 = 8128 *)
  STextIO.WriteString("sum=");
  SWholeIO.WriteInt(sum, 0);
  STextIO.WriteLn
END t40050.
