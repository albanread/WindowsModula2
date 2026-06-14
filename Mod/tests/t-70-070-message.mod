MODULE T70070Message;
(*
 * Group 70 — Exceptions
 * Test: a multi-character exception message round-trips through RAISE and
 *       EXCEPTIONS.GetMessage (wide UTF-16, not truncated at the first byte).
 *
 * EXPECTED:
 * file not found
 *)
IMPORT STextIO, EXCEPTIONS;
VAR src: EXCEPTIONS.ExceptionSource;
    buf: ARRAY [0..63] OF CHAR;
BEGIN
  EXCEPTIONS.AllocateSource(src);
  EXCEPTIONS.RAISE(src, 1, "file not found");
EXCEPT
  EXCEPTIONS.GetMessage(buf);
  STextIO.WriteString(buf);
  STextIO.WriteLn;
END T70070Message.
