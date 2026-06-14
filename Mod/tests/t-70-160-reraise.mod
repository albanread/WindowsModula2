MODULE t70160;
IMPORT STextIO, EXCEPTIONS, NM2RT;

VAR src : EXCEPTIONS.ExceptionSource;

PROCEDURE Inner;
BEGIN
  EXCEPTIONS.RAISE(src, 7, "boom")
EXCEPT
  (* Note the exception, then propagate it to the caller's handler. *)
  STextIO.WriteString("inner ");
  NM2RT.Reraise
END Inner;

BEGIN
  EXCEPTIONS.AllocateSource(src);
  Inner
EXCEPT
  IF EXCEPTIONS.IsCurrentSource(src) AND
     (EXCEPTIONS.CurrentNumber(src) = 7) THEN
    STextIO.WriteString("outer7")
  ELSE
    STextIO.WriteString("lost")
  END;
  STextIO.WriteLn
END t70160.
