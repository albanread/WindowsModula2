MODULE T90169InOut;
(*
 * Group 90 — library / I/O
 * Test: the clean-room InOut module — text/whole output delegating to the ISO
 *       simple modules, plus the directly-formatted WriteOct / WriteHex.
 *
 * EXPECTED:
 * hello
 *    42
 * -7
 * 10
 *   FF
 *)
FROM InOut IMPORT WriteString, WriteLn, WriteInt, WriteCard, WriteOct, WriteHex;

BEGIN
  WriteString("hello"); WriteLn;
  WriteCard(42, 5); WriteLn;     (* "   42" *)
  WriteInt(-7, 0); WriteLn;      (* "-7" *)
  WriteOct(8, 0); WriteLn;       (* 8 decimal = 10 octal *)
  WriteHex(255, 4); WriteLn      (* "  FF" *)
END T90169InOut.
