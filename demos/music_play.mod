MODULE MusicPlay;
(*
 * ABC music playback — Phase 3 of the M2 audio port. Parses ABC notation with the
 * Abc module and plays it live through WinMM midiOut (a background scheduler thread,
 * direct from Modula-2). The timing-critical part: each note fires at its precomputed
 * millisecond deadline, no GC pauses between notes. Run it and you should hear the
 * opening of Beethoven's "Ode to Joy".
 *
 *   build: newm2 build demos/music_play.mod   then run the .exe
 *)
IMPORT Abc, MidiOut;
FROM System_Threading IMPORT Sleep;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
FROM WIN32 IMPORT DWORD;

VAR abc: ARRAY [0..4095] OF CHAR;
    tune: Abc.Tune;
    n: CARDINAL;

PROCEDURE App (line: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(line)) AND (line[i] # 0C) DO abc[n] := line[i]; INC(n); INC(i) END;
  abc[n] := CHR(10); INC(n); abc[n] := 0C
END App;

BEGIN
  n := 0;
  App("X:1");
  App("T:Ode to Joy");
  App("M:4/4");
  App("L:1/4");
  App("Q:140");
  App("%%MIDI program 0");
  App("K:C");
  App("EEFG GFED|CCDE E2D2|");

  WriteString("Parsing ABC..."); WriteLn;
  IF NOT Abc.ParseTune(abc, tune) THEN WriteString("parse produced no notes"); WriteLn; HALT END;
  WriteString("  events="); WriteInt(VAL(INTEGER, tune.count), 1);
  WriteString("  bpm="); WriteInt(VAL(INTEGER, tune.bpm), 1);
  WriteString("  length="); WriteInt(VAL(INTEGER, tune.endMs), 1); WriteString("ms"); WriteLn;

  IF NOT MidiOut.Startup() THEN WriteString("midiOut open failed"); WriteLn; HALT END;
  WriteString("Playing through midiOut (GM synth)..."); WriteLn;
  MidiOut.Play(tune);
  WHILE MidiOut.IsPlaying() DO Sleep(VAL(DWORD, 50)) END;
  Sleep(VAL(DWORD, 300));                 (* let the last note ring *)
  MidiOut.Stop;
  MidiOut.Shutdown;
  WriteString("Done."); WriteLn
END MusicPlay.
