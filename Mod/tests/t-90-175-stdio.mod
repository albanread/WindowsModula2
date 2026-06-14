MODULE T90175StdIO;
(*
 * Group 90 — library / I/O
 * Test: the clean-room StdIO module — Write delegates to the ISO simple text
 *       module, and the inert PushOutput/PopOutput redirection accepts a
 *       procedure value without changing where Write goes.
 *
 * EXPECTED:
 * hi
 *)
IMPORT StdIO;

PROCEDURE Emit (ch: CHAR);
BEGIN
  StdIO.Write(ch)
END Emit;

BEGIN
  StdIO.PushOutput(Emit);   (* inert, but accepts a ProcWrite *)
  StdIO.Write('h');
  StdIO.Write('i');
  StdIO.Write(CHR(10));
  StdIO.PopOutput
END T90175StdIO.
