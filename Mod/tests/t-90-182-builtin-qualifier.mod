MODULE T90182BuiltinQualifier;
(*
 * Group 90 — parser
 * Test: the `PROCEDURE __BUILTIN__ <name> (...)` / `__INLINE__` qualifier
 *       between PROCEDURE and the name is accepted and the procedure is
 *       declared/callable normally. (Used by the `builtin` module.)
 *
 * EXPECTED:
 * 5 9
 *)
FROM SWholeIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE __BUILTIN__ five (): CARDINAL;
BEGIN
  RETURN 5
END five;

PROCEDURE __INLINE__ square (n: CARDINAL): CARDINAL;
BEGIN
  RETURN n * n
END square;

BEGIN
  WriteCard(five(), 0); WriteString(" ");
  WriteCard(square(3), 0); WriteLn        (* 5 9 *)
END T90182BuiltinQualifier.
