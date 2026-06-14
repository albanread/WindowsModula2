MODULE T91029ConstIndexOOB;
(*
 * Group 91 — diagnostics (negative, --strict): under the pedantic `--strict`
 * flag a compile-time-constant array index outside the declared dimension is a
 * static error (a[4] for ARRAY [0..3]). The lenient default accepts it and traps
 * at run time (indexException) instead.
 *)
VAR a: ARRAY [0..3] OF INTEGER;
BEGIN
  a[4] := 0
END T91029ConstIndexOOB.
