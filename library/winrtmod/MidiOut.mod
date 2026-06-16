IMPLEMENTATION MODULE MidiOut;

(* WinMM midiOut scheduler (midi_runtime.rs). One worker thread, timeBeginPeriod(1)
   for ~1ms resolution. It plays SEVERAL concurrent tracks: track 0 is the "music"
   track (Play); tracks 1..NTrk-1 are one-shot SFX voices (PlaySfx). A sound effect
   therefore layers OVER the music instead of replacing it.

   Each track remembers the notes it currently holds and, when it is restarted or
   finishes, sends note-off only for ITS OWN held notes (precise, per track). So a
   cue switch leaves nothing droning, yet never silences the other tracks or the
   sustained Drone (channel 15). The shared state is guarded by a critical section. *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM WIN32 IMPORT DWORD;
FROM Abc IMPORT Tune;
FROM System_Threading IMPORT Sleep;
IMPORT Threads;
FROM Media_Audio IMPORT midiOutOpen, midiOutShortMsg, midiOutClose, midiOutReset, HMIDIOUT;
FROM Media IMPORT timeGetTime, timeBeginPeriod, timeEndPeriod;

CONST
  NTrk      = 4;     (* track 0 = music; 1..NTrk-1 = SFX voices *)
  MaxHeld   = 24;    (* notes a single track may hold at once *)
  DroneChan = 15;    (* reserved channel for the sustained pad *)

TYPE PTune = POINTER TO Tune;

VAR
  gOut:     HMIDIOUT;
  gLock:    Threads.Lock;
  gThread:  Threads.Thread;
  gShutdown, gReady: BOOLEAN;
  gDroneOn: BOOLEAN; gDroneNote: CARDINAL;
  gTune:    ARRAY [0..NTrk-1] OF PTune;
  gIdx:     ARRAY [0..NTrk-1] OF CARDINAL;
  gStart:   ARRAY [0..NTrk-1] OF CARDINAL;
  gOn:      ARRAY [0..NTrk-1] OF BOOLEAN;
  gHeld:    ARRAY [0..NTrk-1] OF ARRAY [0..MaxHeld-1] OF CARDINAL;  (* 0=empty, else chan*128+note+1 *)
  gNextSfx: CARDINAL;

PROCEDURE Raw (status, chan, d1, d2: CARDINAL);
  VAR msg, r: DWORD;
BEGIN
  msg := VAL(DWORD, (status BOR (chan BAND 0FH)) + d1 * 256 + d2 * 65536);
  r := midiOutShortMsg(gOut, msg)
END Raw;

(* fire one event for a track, keeping that track's held-note set up to date *)
PROCEDURE Emit (trk, status, chan, d1, d2: CARDINAL);
  VAR i, key, st: CARDINAL;
BEGIN
  Raw(status, chan, d1, d2);
  st  := status BAND 0F0H;
  key := (chan BAND 0FH) * 128 + (d1 BAND 7FH) + 1;
  IF (st = 090H) AND (d2 > 0) THEN                 (* note on *)
    i := 0;
    WHILE (i < MaxHeld) AND (gHeld[trk][i] # 0) DO INC(i) END;
    IF i < MaxHeld THEN gHeld[trk][i] := key END
  ELSIF (st = 080H) OR ((st = 090H) AND (d2 = 0)) THEN   (* note off *)
    FOR i := 0 TO MaxHeld-1 DO IF gHeld[trk][i] = key THEN gHeld[trk][i] := 0 END END
  END
END Emit;

(* send note-off for everything a track still holds, then forget it *)
PROCEDURE SilenceTrack (trk: CARDINAL);
  VAR i, key, chan, note: CARDINAL;
BEGIN
  FOR i := 0 TO MaxHeld-1 DO
    key := gHeld[trk][i];
    IF key # 0 THEN
      DEC(key); chan := key DIV 128; note := key MOD 128;
      Raw(080H, chan, note, 0); gHeld[trk][i] := 0
    END
  END
END SilenceTrack;

PROCEDURE AllNotesOff;
  VAR ch: CARDINAL;
BEGIN
  FOR ch := 0 TO 15 DO
    Raw(0B0H, ch, 123, 0);    (* all notes off *)
    Raw(0B0H, ch, 120, 0);    (* all sound off *)
    Raw(0B0H, ch, 64, 0)      (* sustain off *)
  END
END AllNotesOff;

PROCEDURE StartTrack (trk: CARDINAL; VAR t: Tune);
BEGIN
  SilenceTrack(trk);                       (* kill notes this track left ringing *)
  gTune[trk]  := CAST(PTune, ADR(t));
  gIdx[trk]   := 0;
  gStart[trk] := VAL(CARDINAL, timeGetTime());
  gOn[trk]    := TRUE
END StartTrack;

PROCEDURE SchedThread (param: ADDRESS): CARDINAL;
  VAR nowMs, trk: CARDINAL; any: BOOLEAN;
BEGIN
  WHILE NOT gShutdown DO
    Threads.Acquire(gLock);
    any := FALSE;
    FOR trk := 0 TO NTrk-1 DO
      IF gOn[trk] AND (gTune[trk] # NIL) THEN
        nowMs := VAL(CARDINAL, timeGetTime()) - gStart[trk];     (* DWORD wrap is fine *)
        WHILE (gIdx[trk] < gTune[trk]^.count) AND (gTune[trk]^.ev[gIdx[trk]].timeMs <= nowMs) DO
          Emit(trk, gTune[trk]^.ev[gIdx[trk]].status, gTune[trk]^.ev[gIdx[trk]].chan,
               gTune[trk]^.ev[gIdx[trk]].d1, gTune[trk]^.ev[gIdx[trk]].d2);
          INC(gIdx[trk])
        END;
        IF gIdx[trk] >= gTune[trk]^.count THEN gOn[trk] := FALSE; SilenceTrack(trk) END;
        IF gOn[trk] THEN any := TRUE END
      END
    END;
    Threads.Release(gLock);
    IF any THEN Sleep(VAL(DWORD, 1)) ELSE Sleep(VAL(DWORD, 10)) END
  END;
  RETURN 0
END SchedThread;

PROCEDURE Startup (): BOOLEAN;
  VAR r: DWORD; i, j: CARDINAL;
BEGIN
  IF gReady THEN RETURN TRUE END;
  r := timeBeginPeriod(VAL(DWORD, 1));
  gOut.Value := NIL;
  r := midiOutOpen(ADR(gOut), VAL(DWORD, 0FFFFFFFFH), 0, 0, VAL(DWORD, 0));   (* MIDI_MAPPER *)
  IF r # 0 THEN r := timeEndPeriod(VAL(DWORD, 1)); RETURN FALSE END;
  gShutdown := FALSE; gDroneOn := FALSE; gNextSfx := 1;
  FOR i := 0 TO NTrk-1 DO
    gOn[i] := FALSE; gTune[i] := NIL; gIdx[i] := 0;
    FOR j := 0 TO MaxHeld-1 DO gHeld[i][j] := 0 END
  END;
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

PROCEDURE Play (VAR t: Tune);          (* music: the dedicated music track *)
BEGIN
  IF NOT gReady THEN RETURN END;
  Threads.Acquire(gLock);
  StartTrack(0, t);
  Threads.Release(gLock)
END Play;

PROCEDURE PlaySfx (VAR t: Tune);       (* one-shot effect: a free SFX voice; music keeps playing *)
  VAR trk, i: CARDINAL;
BEGIN
  IF NOT gReady THEN RETURN END;
  Threads.Acquire(gLock);
  trk := 0;
  FOR i := 1 TO NTrk-1 DO IF (trk = 0) AND (NOT gOn[i]) THEN trk := i END END;
  IF trk = 0 THEN                       (* none idle -> round-robin a voice *)
    trk := gNextSfx; INC(gNextSfx); IF gNextSfx >= NTrk THEN gNextSfx := 1 END
  END;
  StartTrack(trk, t);
  Threads.Release(gLock)
END PlaySfx;

PROCEDURE Stop;
  VAR r: DWORD; trk: CARDINAL;
BEGIN
  IF NOT gReady THEN RETURN END;
  Threads.Acquire(gLock);
  FOR trk := 0 TO NTrk-1 DO gOn[trk] := FALSE; gIdx[trk] := 0; SilenceTrack(trk) END;
  AllNotesOff;
  r := midiOutReset(gOut);
  Threads.Release(gLock)
END Stop;

PROCEDURE IsPlaying (): BOOLEAN;
BEGIN RETURN gReady AND gOn[0] END IsPlaying;

(* A sustained "pad" note held on the reserved DroneChan. It is NOT a track, so no
   cue switch ever silences it; it rings until DroneOff (or Stop/Shutdown). *)
PROCEDURE Drone (prog, note, vel: CARDINAL);
BEGIN
  IF NOT gReady THEN RETURN END;
  Threads.Acquire(gLock);
  IF gDroneOn THEN Raw(080H, DroneChan, gDroneNote, 0) END;   (* release old pad note *)
  Raw(0C0H, DroneChan, prog, 0);          (* program change *)
  Raw(090H, DroneChan, note, vel);        (* note on *)
  gDroneOn := TRUE; gDroneNote := note;
  Threads.Release(gLock)
END Drone;

PROCEDURE DroneOff;
BEGIN
  IF NOT gReady THEN RETURN END;
  Threads.Acquire(gLock);
  IF gDroneOn THEN Raw(080H, DroneChan, gDroneNote, 0); gDroneOn := FALSE END;
  Threads.Release(gLock)
END DroneOff;

BEGIN
  gReady := FALSE; gShutdown := FALSE; gDroneOn := FALSE
END MidiOut.
