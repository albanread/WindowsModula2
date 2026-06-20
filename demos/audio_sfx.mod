MODULE AudioSfx;
(*
 * Audio SFX generator â renders the NewAudio-ported game sound library to .wav
 * files entirely in Modula-2 (no device needed), then you can play them. This is
 * Phase 1 of the M2 audio port: pure synthesis + WAV export, the headless-testable
 * core (the live waveOut player is Phase 2). A console program â run it and it
 * drops a pack of game SFX next to itself.
 *
 *   build: newm2 build demos/audio_sfx.mod   then run the .exe
 *)
IMPORT Audio, WavFile;
FROM STextIO IMPORT WriteString, WriteLn;

VAR n: CARDINAL;

PROCEDURE Save (name: ARRAY OF CHAR; VAR s: Audio.Sound);
  VAR ok: BOOLEAN;
BEGIN
  ok := WavFile.WriteWav(name, s, 1.0);
  Audio.FreeSound(s);
  IF ok THEN WriteString("  wrote "); WriteString(name); WriteLn; INC(n) END
END Save;

VAR s: Audio.Sound;
BEGIN
  n := 0;
  Audio.InitEngine(12345);
  WriteString("Rendering game SFX pack..."); WriteLn;

  Audio.Coin(s, 0.4);            Save("sfx_coin.wav", s);
  Audio.Beep(s, 660.0, 0.25);    Save("sfx_beep.wav", s);
  Audio.Blip(s, 1.5, 0.12);      Save("sfx_blip.wav", s);
  Audio.Jump(s, 0.3);            Save("sfx_jump.wav", s);
  Audio.Zap(s, 0.3);             Save("sfx_zap.wav", s);
  Audio.Shoot(s, 0.25);          Save("sfx_shoot.wav", s);
  Audio.Explode(s, 1.0, 0.7);    Save("sfx_explode.wav", s);
  Audio.Powerup(s, 0.5);         Save("sfx_powerup.wav", s);
  Audio.Hurt(s, 0.4);            Save("sfx_hurt.wav", s);
  Audio.Click(s, 0.06);          Save("sfx_click.wav", s);
  Audio.Bang(s, 0.4);            Save("sfx_bang.wav", s);
  Audio.Tone(s, 220.0, 0.5, Audio.WSaw);     Save("sfx_saw220.wav", s);
  Audio.Noise(s, 1, 0.6);        Save("sfx_pinknoise.wav", s);

  WriteString("Done. "); WriteLn
END AudioSfx.
