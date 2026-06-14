(* Copyright (c) xTech 1993. All Rights Reserved. *)
(* Ported to NewM2 2026-06-07 from XDS 2.60 lib/src/isoimp. Apache-2.0.
   Integration notes:
     - The XDS source uses `xDevData` / `xlibOS` to back the standard
       channels with the OS file system. NewM2 doesn't ship those
       internals; this port points the DeviceTable procedure-pointer
       fields at the runtime's `NM2IO.*` shims (stdout/stderr/stdin).
     - NewModula2's CHAR is a wide (UTF-16) cell, so the text path uses
       `NM2IO.WriteText` / `PeekChar` / `ReadText` (CHAR-cell counts;
       the runtime converts to/from UTF-8). The raw path keeps
       `NM2IO.WriteBytes` (byte counts).
     - Standard and default channels share their underlying DeviceTable
       slot initially; user code may redirect the default channels.
     - `Synchronize` is a no-op here.
*)
IMPLEMENTATION MODULE StdChans;

IMPORT SYSTEM, IOChan, IOLink, IOConsts, NM2IO;

VAR stdinp, stdout, stderr: ChanId;
    inp, out, err: ChanId;
    null: ChanId;
    did: IOLink.DeviceId;

(*----------------------------------------------------------------*)
(* Device-table procedure-pointer backings.                       *)

(* `null` channel: writes succeed silently; reads report endOfInput. *)
PROCEDURE nullLook(x: IOLink.DeviceTablePtr; VAR ch: CHAR;
                   VAR res: IOConsts.ReadResults);
BEGIN
  ch := 0C;
  res := IOConsts.endOfInput;
  x^.result := res;
END nullLook;

PROCEDURE nullSkip(x: IOLink.DeviceTablePtr);
BEGIN
  x^.result := IOConsts.endOfInput;
END nullSkip;

PROCEDURE nullRead(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                  max: CARDINAL; VAR n: CARDINAL);
BEGIN
  n := 0;
  x^.result := IOConsts.endOfInput;
END nullRead;

PROCEDURE nullWrite(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                    n: CARDINAL);
BEGIN
END nullWrite;

PROCEDURE nullWriteLn(x: IOLink.DeviceTablePtr);
BEGIN
END nullWriteLn;

(* stdin: backed by NM2IO.PeekChar / ConsumeChar / ReadText. *)
PROCEDURE stdinLook(x: IOLink.DeviceTablePtr; VAR ch: CHAR;
                    VAR res: IOConsts.ReadResults);
  VAR r: INTEGER;
BEGIN
  NM2IO.PeekChar(ch, r);
  res := VAL(IOConsts.ReadResults, r);
  x^.result := res;
END stdinLook;

PROCEDURE stdinSkip(x: IOLink.DeviceTablePtr);
BEGIN
  NM2IO.ConsumeChar();
  x^.result := IOConsts.allRight;
END stdinSkip;

PROCEDURE stdinSkipLook(x: IOLink.DeviceTablePtr; VAR ch: CHAR;
                        VAR res: IOConsts.ReadResults);
BEGIN
  NM2IO.ConsumeChar();
  stdinLook(x, ch, res);
END stdinSkipLook;

PROCEDURE stdinTextRead(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                        max: CARDINAL; VAR n: CARDINAL);
BEGIN
  NM2IO.ReadText(a, max, n);
  IF n = 0 THEN
    x^.result := IOConsts.endOfInput;
  ELSE
    x^.result := IOConsts.allRight;
  END;
END stdinTextRead;

(* stdout: text via NM2IO.WriteText (CHAR cells), raw via WriteBytes. *)
PROCEDURE stdoutTextWrite(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                          n: CARDINAL);
BEGIN
  NM2IO.WriteText(a, n);
END stdoutTextWrite;

PROCEDURE stdoutRawWrite(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                         n: CARDINAL);
BEGIN
  NM2IO.WriteBytes(a, n);
END stdoutRawWrite;

PROCEDURE stdoutWriteLn(x: IOLink.DeviceTablePtr);
  VAR nl: ARRAY [0..0] OF CHAR;
BEGIN
  nl[0] := 12C;  (* LF *)
  NM2IO.WriteText(SYSTEM.ADR(nl), 1);
END stdoutWriteLn;

PROCEDURE stdoutFlush(x: IOLink.DeviceTablePtr);
BEGIN
  NM2IO.Flush();
END stdoutFlush;

(* stderr: backed by NM2IO.WriteErrText / FlushErr. *)
PROCEDURE stderrTextWrite(x: IOLink.DeviceTablePtr; a: SYSTEM.ADDRESS;
                          n: CARDINAL);
BEGIN
  NM2IO.WriteErrText(a, n);
END stderrTextWrite;

PROCEDURE stderrWriteLn(x: IOLink.DeviceTablePtr);
  VAR nl: ARRAY [0..0] OF CHAR;
BEGIN
  nl[0] := 12C;
  NM2IO.WriteErrText(SYSTEM.ADR(nl), 1);
END stderrWriteLn;

PROCEDURE stderrFlush(x: IOLink.DeviceTablePtr);
BEGIN
  NM2IO.FlushErr();
END stderrFlush;

(* No-op for Reset/GetName on standard channels. *)
PROCEDURE noopReset(x: IOLink.DeviceTablePtr);
BEGIN
END noopReset;

PROCEDURE noopGetName(x: IOLink.DeviceTablePtr; VAR s: ARRAY OF CHAR);
BEGIN
  IF HIGH(s) >= 0 THEN s[0] := 0C END;
END noopGetName;

(*----------------------------------------------------------------*)

PROCEDURE StdInChan(): ChanId;
BEGIN
  RETURN stdinp;
END StdInChan;

PROCEDURE StdOutChan(): ChanId;
BEGIN
  RETURN stdout;
END StdOutChan;

PROCEDURE StdErrChan(): ChanId;
BEGIN
  RETURN stderr;
END StdErrChan;

PROCEDURE NullChan(): ChanId;
BEGIN
  RETURN null;
END NullChan;

PROCEDURE InChan(): ChanId;
BEGIN
  RETURN inp;
END InChan;

PROCEDURE OutChan(): ChanId;
BEGIN
  RETURN out;
END OutChan;

PROCEDURE ErrChan(): ChanId;
BEGIN
  RETURN err;
END ErrChan;

PROCEDURE SetInChan(cid: ChanId);
BEGIN
  inp := cid;
END SetInChan;

PROCEDURE SetOutChan(cid: ChanId);
BEGIN
  out := cid;
END SetOutChan;

PROCEDURE SetErrChan(cid: ChanId);
BEGIN
  err := cid;
END SetErrChan;

PROCEDURE Synchronize(): BOOLEAN;
BEGIN
  RETURN TRUE;
END Synchronize;

(*----------------------------------------------------------------*)
(* Initialisation. *)

PROCEDURE wireNull(cid: ChanId);
  VAR x: IOLink.DeviceTablePtr;
BEGIN
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x = NIL THEN RETURN END;
  x^.doLook       := nullLook;
  x^.doSkip       := nullSkip;
  x^.doSkipLook   := nullLook;
  x^.doLnWrite    := nullWriteLn;
  x^.doTextRead   := nullRead;
  x^.doTextWrite  := nullWrite;
  x^.doRawRead    := nullRead;
  x^.doRawWrite   := nullWrite;
  x^.doGetName    := noopGetName;
  x^.doReset      := noopReset;
  x^.doFlush      := noopReset;
END wireNull;

PROCEDURE wireStdin(cid: ChanId);
  VAR x: IOLink.DeviceTablePtr;
BEGIN
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x = NIL THEN RETURN END;
  x^.doLook       := stdinLook;
  x^.doSkip       := stdinSkip;
  x^.doSkipLook   := stdinSkipLook;
  x^.doLnWrite    := nullWriteLn;
  x^.doTextRead   := stdinTextRead;
  x^.doTextWrite  := nullWrite;
  x^.doRawRead    := stdinTextRead;
  x^.doRawWrite   := nullWrite;
  x^.doGetName    := noopGetName;
  x^.doReset      := noopReset;
  x^.doFlush      := noopReset;
END wireStdin;

PROCEDURE wireStdout(cid: ChanId);
  VAR x: IOLink.DeviceTablePtr;
BEGIN
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x = NIL THEN RETURN END;
  x^.doLook       := nullLook;
  x^.doSkip       := nullSkip;
  x^.doSkipLook   := nullLook;
  x^.doLnWrite    := stdoutWriteLn;
  x^.doTextRead   := nullRead;
  x^.doTextWrite  := stdoutTextWrite;
  x^.doRawRead    := nullRead;
  x^.doRawWrite   := stdoutRawWrite;
  x^.doGetName    := noopGetName;
  x^.doReset      := noopReset;
  x^.doFlush      := stdoutFlush;
END wireStdout;

PROCEDURE wireStderr(cid: ChanId);
  VAR x: IOLink.DeviceTablePtr;
BEGIN
  x := SYSTEM.CAST(IOLink.DeviceTablePtr, cid);
  IF x = NIL THEN RETURN END;
  x^.doLook       := nullLook;
  x^.doSkip       := nullSkip;
  x^.doSkipLook   := nullLook;
  x^.doLnWrite    := stderrWriteLn;
  x^.doTextRead   := nullRead;
  x^.doTextWrite  := stderrTextWrite;
  x^.doRawRead    := nullRead;
  x^.doRawWrite   := stderrTextWrite;
  x^.doGetName    := noopGetName;
  x^.doReset      := noopReset;
  x^.doFlush      := stderrFlush;
END wireStderr;

BEGIN
  IOLink.AllocateDeviceId(did);
  IOLink.MakeChan(did, null);
  wireNull(null);
  IOLink.MakeChan(did, stdinp);
  wireStdin(stdinp);
  IOLink.MakeChan(did, stdout);
  wireStdout(stdout);
  IOLink.MakeChan(did, stderr);
  wireStderr(stderr);
  inp := stdinp;
  out := stdout;
  err := stderr;
END StdChans.
