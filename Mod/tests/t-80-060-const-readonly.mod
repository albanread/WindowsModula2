MODULE t80020;
PROCEDURE P(CONST a : INTEGER);
BEGIN
  a := 5            (* error: cannot assign to a CONST parameter *)
END P;
BEGIN
END t80020.
