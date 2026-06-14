MODULE t11010;
(* Hardening (semantics audit #2): a constant expression that overflows the
   folder's i128 range must produce a clean "constant overflow" diagnostic, not
   crash the compiler (debug panic) or silently wrap (release). *)
CONST
  A    = 9223372036854775807;   (* MAX(INTEGER64) *)
  Over = A * A * A;             (* overflows i128 *)
BEGIN
END t11010.
