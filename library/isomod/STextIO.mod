(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-05-14 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - Replaces the previous "def-only port with runtime stubs" approach
       — this is the real ISO 10514-1 channel-based STextIO that
       dispatches through `StdChans.{In,Out}Chan` for every operation.
     - Dropped the constant-parameter modifier (`s-: ARRAY OF CHAR`
       → plain `s: ARRAY OF CHAR`).
     - When this module is linked in, the runtime `bind` calls in
       `newm2-llvm::bind_runtime_helpers` see that `STextIO.WriteString`
       already has a body and skip the legacy direct-to-stdout shim
       binding — so the channel path is in force.
*)
IMPLEMENTATION MODULE STextIO;

IMPORT TextIO, StdChans;

PROCEDURE ReadChar(VAR ch: CHAR);
BEGIN
  TextIO.ReadChar(StdChans.InChan(), ch);
END ReadChar;

PROCEDURE ReadRestLine(VAR s: ARRAY OF CHAR);
BEGIN
  TextIO.ReadRestLine(StdChans.InChan(), s);
END ReadRestLine;

PROCEDURE ReadString(VAR s: ARRAY OF CHAR);
BEGIN
  TextIO.ReadString(StdChans.InChan(), s);
END ReadString;

PROCEDURE ReadToken(VAR s: ARRAY OF CHAR);
BEGIN
  TextIO.ReadToken(StdChans.InChan(), s);
END ReadToken;

PROCEDURE SkipLine;
BEGIN
  TextIO.SkipLine(StdChans.InChan());
END SkipLine;

PROCEDURE WriteChar(ch: CHAR);
BEGIN
  TextIO.WriteChar(StdChans.OutChan(), ch);
END WriteChar;

PROCEDURE WriteLn;
BEGIN
  TextIO.WriteLn(StdChans.OutChan());
END WriteLn;

PROCEDURE WriteString(s: ARRAY OF CHAR);
BEGIN
  TextIO.WriteString(StdChans.OutChan(), s);
END WriteString;

END STextIO.
