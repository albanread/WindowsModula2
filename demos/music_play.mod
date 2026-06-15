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
FROM SYSTEM IMPORT ADR;
IMPORT Abc, MidiOut, SmfFile, FileFunc;
FROM System_Threading IMPORT Sleep;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
FROM WIN32 IMPORT DWORD;

PROCEDURE CheckMThd (path: ARRAY OF CHAR);
  VAR f: FileFunc.File; h: ARRAY [0..13] OF BYTE; got: CARDINAL;
  PROCEDURE Bv (i: CARDINAL): CARDINAL; BEGIN RETURN VAL(CARDINAL, h[i]) BAND 0FFH END Bv;
BEGIN
  f := FileFunc.OpenRead(path);
  IF NOT FileFunc.IsValid(f) THEN RETURN END;
  got := FileFunc.ReadBytes(f, ADR(h), 14); FileFunc.Close(f);
  WriteString("  MThd: format="); WriteInt(VAL(INTEGER, Bv(8)*256 + Bv(9)), 1);
  WriteString(" ntracks="); WriteInt(VAL(INTEGER, Bv(10)*256 + Bv(11)), 1);
  WriteString(" division="); WriteInt(VAL(INTEGER, Bv(12)*256 + Bv(13)), 1);
  WriteString(" ticks/quarter (480 = a quarter on the grid)"); WriteLn
END CheckMThd;

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

VAR i, chMask: CARDINAL;

BEGIN
  n := 0;
  App("X:1");
  App("T:Ode to Joy (2 voices)");
  App("M:4/4");
  App("L:1/4");
  App("Q:135");
  App("K:C");
  App("V:1");                                  (* melody on a piano *)
  App("%%MIDI program 0");
  App("EEFG GFED|CCDE E2D2|");
  App("V:2");                                  (* bass on a different channel + instrument *)
  App("%%MIDI program 32");
  App("C,2C,2 G,,2G,,2|C,2C,2 G,,2C,2|");

  WriteString("Parsing ABC..."); WriteLn;
  IF NOT Abc.ParseTune(abc, tune) THEN WriteString("parse produced no notes"); WriteLn; HALT END;
  WriteString("  events="); WriteInt(VAL(INTEGER, tune.count), 1);
  WriteString("  bpm="); WriteInt(VAL(INTEGER, tune.bpm), 1);
  WriteString("  length="); WriteInt(VAL(INTEGER, tune.endMs), 1); WriteString("ms"); WriteLn;
  (* report channels that have note-ons + the program changes *)
  chMask := 0;
  FOR i := 0 TO tune.count-1 DO
    IF tune.ev[i].status = 90H THEN chMask := chMask BOR (1 SHL tune.ev[i].chan) END;
    IF tune.ev[i].status = 0C0H THEN
      WriteString("  channel "); WriteInt(VAL(INTEGER, tune.ev[i].chan), 1);
      WriteString(" -> program "); WriteInt(VAL(INTEGER, tune.ev[i].d1), 1); WriteLn
    END
  END;
  WriteString("  channels with notes mask="); WriteInt(VAL(INTEGER, chMask), 1); WriteLn;

  IF SmfFile.WriteSmf("ode_to_joy.mid", tune) THEN
    WriteString("Wrote ode_to_joy.mid"); WriteLn; CheckMThd("ode_to_joy.mid")
  END;

  IF NOT MidiOut.Startup() THEN WriteString("midiOut open failed"); WriteLn; HALT END;
  WriteString("Playing through midiOut (GM synth)..."); WriteLn;
  MidiOut.Play(tune);
  WHILE MidiOut.IsPlaying() DO Sleep(VAL(DWORD, 50)) END;
  Sleep(VAL(DWORD, 300));                 (* let the last note ring *)
  MidiOut.Stop;
  MidiOut.Shutdown;
  WriteString("Done."); WriteLn
END MusicPlay.
