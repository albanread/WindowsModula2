IMPLEMENTATION MODULE T90EnumLib;
PROCEDURE classify (n: CARDINAL): Result;
BEGIN
  IF n = 0 THEN RETURN failed
  ELSIF n = 1 THEN RETURN opened
  ELSE RETURN closed
  END
END classify;
END T90EnumLib.
