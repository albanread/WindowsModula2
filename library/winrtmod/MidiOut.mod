IMPLEMENTATION MODULE MidiOut;

(* WinMM midiOut scheduler (midi_runtime.rs). One worker thread, timeBeginPeriod(1)
   for ~1ms resolution: each tick it reads timeGetTime(), and for the playing tune
   fires every event whose absolute timeMs <= (now - startMs) via midiOutShortMsg,
   then advances the cursor. Events are pre-sorted by Abc, so the worker stops at
   the first not-yet-due event. The shared state is guarded by a critical section,
   exactly like WaveOut. *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM WIN32 IMPORT DWORD;
FROM Abc IMPORT Tune;
FROM System_Threading IMPORT Sleep;
IMPORT Threads;
FROM Media_Audio IMPORT midiOutOpen, midiOutShortMsg, midiOutClose, midiOutReset, HMIDIOUT;
FROM Media IMPORT timeGetTime, timeBeginPeriod, timeEndPeriod;

TYPE PTune = POINTER TO Tune;

VAR
  gOut:     HMIDIOUT;
  gLock:    Threads.Lock;
  gThread:  Threads.Thread;
  gTune:    PTune;
  gIdx:     CARDINAL;
  gStartMs: CARDINAL;
  gPlaying, gShutdown, gReady: BOOLEAN;

PROCEDURE SendShort (status, chan, d1, d2: CARDINAL);
  VAR msg: DWORD; r: DWORD;
BEGIN
  msg := VAL(DWORD, (status BOR (chan BAND 0FH)) + d1 * 256 + d2 * 65536);
  r := midiOutShortMsg(gOut, msg)
END SendShort;

PROCEDURE AllNotesOff;
  VAR ch: CARDINAL;
BEGIN
  FOR ch := 0 TO 15 DO
    SendShort(0B0H, ch, 123, 0);    (* all notes off *)
    SendShort(0B0H, ch, 120, 0);    (* all sound off *)
    SendShort(0B0H, ch, 64, 0)      (* sustain off *)
  END
END AllNotesOff;

PROCEDURE SchedThread (param: ADDRESS): CARDINAL;
  VAR nowMs: CARDINAL;
BEGIN
  WHILE NOT gShutdown DO
    Threads.Acquire(gLock);
    IF gPlaying AND (gTune # NIL) THEN
      nowMs := VAL(CARDINAL, timeGetTime()) - gStartMs;     (* DWORD wrap is fine *)
      WHILE (gIdx < gTune^.count) AND (gTune^.ev[gIdx].timeMs <= nowMs) DO
        SendShort(gTune^.ev[gIdx].status, gTune^.ev[gIdx].chan,
                  gTune^.ev[gIdx].d1, gTune^.ev[gIdx].d2);
        INC(gIdx)
      END;
      IF gIdx >= gTune^.count THEN gPlaying := FALSE END
    END;
    Threads.Release(gLock);
    IF gPlaying THEN Sleep(VAL(DWORD, 1)) ELSE Sleep(VAL(DWORD, 10)) END
  END;
  RETURN 0
END SchedThread;

PROCEDURE Startup (): BOOLEAN;
  VAR r: DWORD;
BEGIN
  IF gReady THEN RETURN TRUE END;
  r := timeBeginPeriod(VAL(DWORD, 1));
  gOut.Value := NIL;
  r := midiOutOpen(ADR(gOut), VAL(DWORD, 0FFFFFFFFH), 0, 0, VAL(DWORD, 0));   (* MIDI_MAPPER *)
  IF r # 0 THEN r := timeEndPeriod(VAL(DWORD, 1)); RETURN FALSE END;
  gPlaying := FALSE; gShutdown := FALSE; gTune := NIL; gIdx := 0;
  Threads.InitLock(gLock);
  gThread := Threads.Spawn(SchedThread, NIL);
  gReady := TRUE;
  RETURN TRUE
END Startup;

PROCEDURE Shutdown;
  VAR r: DWORD; ok: BOOLEAN;
BEGIN
  IF NOT gReady THEN RETURN END;
  gShutdown := TRUE;
  ok := Threads.Join(gThread, 2000);
  Threads.CloseThread(gThread);
  AllNotesOff;
  r := midiOutReset(gOut);
  r := midiOutClose(gOut);
  r := timeEndPeriod(VAL(DWORD, 1));
  Threads.DestroyLock(gLock);
  gReady := FALSE
END Shutdown;

PROCEDURE Play (VAR t: Tune);
BEGIN
  IF NOT gReady THEN RETURN END;
  Threads.Acquire(gLock);
  gTune := CAST(PTune, ADR(t));
  gIdx := 0;
  gStartMs := VAL(CARDINAL, timeGetTime());
  gPlaying := TRUE;
  Threads.Release(gLock)
END Play;

PROCEDURE Stop;
  VAR r: DWORD;
BEGIN
  IF NOT gReady THEN RETURN END;
  Threads.Acquire(gLock);
  gPlaying := FALSE; gIdx := 0;
  AllNotesOff;
  r := midiOutReset(gOut);
  Threads.Release(gLock)
END Stop;

PROCEDURE IsPlaying (): BOOLEAN;
BEGIN RETURN gReady AND gPlaying END IsPlaying;

BEGIN
  gReady := FALSE; gPlaying := FALSE; gShutdown := FALSE; gTune := NIL
END MidiOut.
