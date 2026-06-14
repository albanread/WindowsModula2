MODULE T90177FIO;
(*
 * Group 90 — library / I/O
 * Test: the clean-room FIO console surface — the StdOut handle (a module-global
 *       File, exercising cross-module globals) plus the buffered write
 *       operations delegating to the ISO simple modules. Uses qualified access
 *       (FIO.StdOut); the FROM-imported unqualified form of a module global is
 *       a separate, documented limitation.
 *
 * EXPECTED:
 * hello 42
 *)
IMPORT FIO;

BEGIN
  FIO.WriteString(FIO.StdOut, "hello");
  FIO.WriteChar(FIO.StdOut, ' ');
  FIO.WriteCardinal(FIO.StdOut, 42);
  FIO.WriteLine(FIO.StdOut);
  FIO.FlushBuffer(FIO.StdOut)
END T90177FIO.
