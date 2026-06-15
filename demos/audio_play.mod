MODULE AudioPlay;
(*
 * Live audio playback — Phase 2 of the M2 audio port. Synthesizes game SFX with
 * the Audio library and plays them through WinMM waveOut (a background mixer thread,
 * direct from Modula-2), demonstrating one-shots, overlapping voices (software
 * mixing), and a looped tone with a fade-out. Run it and listen.
 *
 *   build: newm2 build demos/audio_play.mod   then run the .exe
 *)
IMPORT Audio, WaveOut;
FROM System_Threading IMPORT Sleep;
FROM STextIO IMPORT WriteString, WriteLn;
FROM WIN32 IMPORT DWORD;

VAR coin, jump, zap, explode, powerup, hum: Audio.Sound;
    i, v: CARDINAL;

PROCEDURE Wait (ms: CARDINAL); BEGIN Sleep(VAL(DWORD, ms)) END Wait;

PROCEDURE Say (msg: ARRAY OF CHAR); BEGIN WriteString(msg); WriteLn END Say;

BEGIN
  Audio.InitEngine(12345);
  Audio.Coin(coin, 0.4);
  Audio.Jump(jump, 0.3);
  Audio.Zap(zap, 0.3);
  Audio.Explode(explode, 1.0, 0.7);
  Audio.Powerup(powerup, 0.5);
  Audio.Tone(hum, 110.0, 1.0, Audio.WTriangle);

  IF NOT WaveOut.Startup() THEN Say("waveOut open failed"); HALT END;
  Say("Playing M2-synthesized SFX through waveOut...");

  Say("  coin");    v := WaveOut.Play(coin, 0.9, 0.0);    Wait(650);
  Say("  jump");    v := WaveOut.Play(jump, 0.9, -0.4);   Wait(650);
  Say("  zap");     v := WaveOut.Play(zap, 0.9, 0.4);     Wait(650);
  Say("  explode"); v := WaveOut.Play(explode, 1.0, 0.0); Wait(1000);
  Say("  powerup"); v := WaveOut.Play(powerup, 0.8, 0.0); Wait(800);

  Say("  five coins, overlapping (voice mixing)");
  FOR i := 0 TO 4 DO v := WaveOut.Play(coin, 0.5, 0.0); Wait(110) END;
  Wait(500);

  Say("  looped hum, then 0.5s fade-out");
  v := WaveOut.PlayLooped(hum, 0.35, 0.0);
  Wait(1600);
  WaveOut.StopVoice(v, 0.5);
  Wait(800);

  Say("Done.");
  WaveOut.Shutdown;
  Audio.FreeSound(coin); Audio.FreeSound(jump); Audio.FreeSound(zap);
  Audio.FreeSound(explode); Audio.FreeSound(powerup); Audio.FreeSound(hum)
END AudioPlay.
