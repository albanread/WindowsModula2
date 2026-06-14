MODULE t30080;
IMPORT STextIO, SWholeIO;

(* A genuinely sparse enumeration (ADW / C-enum form): each member keeps its
   explicit ordinal, and a member with no value takes previous+1. *)
TYPE Code = (ok = 0, warn = 5, fail = 10, fatal);  (* fatal = 11 *)

PROCEDURE Emit(label : ARRAY OF CHAR; n : INTEGER);
BEGIN
  STextIO.WriteString(label);
  SWholeIO.WriteInt(n, 0);
  STextIO.WriteLn
END Emit;

VAR c : Code;

BEGIN
  c := warn;
  Emit("ord_c=", ORD(c));            (* 5 *)
  Emit("ord_fail=", ORD(fail));      (* 10 *)
  Emit("ord_fatal=", ORD(fatal));    (* 11 (previous + 1) *)
  Emit("max=", ORD(MAX(Code)));      (* 11 *)
  Emit("min=", ORD(MIN(Code)))       (* 0 *)
END t30080.
