IMPLEMENTATION MODULE Audio;

(* Port of NewAudio newaudio-core. Synthesis is done in REAL (f64) throughout —
   the Rust reference uses f32, so our output is audibly identical but not
   bit-identical; correctness here means the right algorithm, not matching f32
   rounding. The pipeline (Render) mirrors engine.rs:218-313 exactly: oscillator
   stack, gliding pitch-sweep sine, noise blend, ADSR, tanh distortion, the x0.5
   write, echo taps, peak-normalise to 0.9. *)

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM NM2Math IMPORT sin, tanh, pow, floor, truncToCard;

CONST
  Pi    = 3.14159265358979;
  TwoPi = 6.28318530717959;

TYPE
  Adsr = RECORD attack, decay, sustain, release: REAL END;
  Oscillator = RECORD wave: Waveform; frequency, amplitude, phase, pulseWidth: REAL END;
  Effect = RECORD
    duration: REAL;
    osc: ARRAY [0..3] OF Oscillator; oscCount: CARDINAL;
    env: Adsr;
    sweepStart, sweepEnd, noiseMix, distortion: REAL;
    echoCount: CARDINAL; echoDelay, echoDecay: REAL;
  END;

VAR gState: CARDINAL;            (* the LCG state *)

(* ---- LCG (waveform.rs:33-56). u32 wrap forced via MOD 2^32. ------------- *)

PROCEDURE InitEngine (seed: CARDINAL); BEGIN gState := seed END InitEngine;

PROCEDURE StepLcg (): CARDINAL;
BEGIN
  gState := (gState * 1103515245 + 12345) MOD 100000000H;   (* MOD 2^32 *)
  RETURN gState
END StepLcg;

PROCEDURE NextSigned (): REAL;
  VAR st: CARDINAL;
BEGIN st := StepLcg(); RETURN VAL(REAL, (st DIV 65536) MOD 32768) / 16384.0 - 1.0 END NextSigned;

PROCEDURE NextUnit (): REAL;
  VAR st: CARDINAL;
BEGIN st := StepLcg(); RETURN VAL(REAL, (st DIV 65536) MOD 32768) / 32768.0 END NextUnit;

PROCEDURE NextRange (lo, hi: REAL): REAL;
BEGIN RETURN lo + NextUnit() * (hi - lo) END NextRange;

(* ---- helpers ----------------------------------------------------------- *)

PROCEDURE RAbs (x: REAL): REAL; BEGIN IF x < 0.0 THEN RETURN -x ELSE RETURN x END END RAbs;

(* Euclidean remainder: always non-negative (Rust rem_euclid). *)
PROCEDURE RemEuclid (x, m: REAL): REAL;
BEGIN RETURN x - m * floor(x / m) END RemEuclid;

PROCEDURE Clamp (x, lo, hi: REAL): REAL;
BEGIN IF x < lo THEN RETURN lo ELSIF x > hi THEN RETURN hi ELSE RETURN x END END Clamp;

PROCEDURE WaveSample (wave: Waveform; phase, pw: REAL): REAL;
  VAR n, t: REAL;
BEGIN
  CASE wave OF
    WSine:     RETURN sin(phase)
  | WSquare:   IF RemEuclid(phase, TwoPi) < Pi THEN RETURN 1.0 ELSE RETURN -1.0 END
  | WSaw:      n := phase / TwoPi; RETURN 2.0 * (n - floor(n + 0.5))
  | WTriangle: t := RemEuclid(phase / TwoPi, 1.0); RETURN 4.0 * RAbs(t - 0.5) - 1.0
  | WNoise:    RETURN NextSigned()
  | WPulse:    t := RemEuclid(phase, TwoPi) / TwoPi; IF t < pw THEN RETURN 1.0 ELSE RETURN -1.0 END
  END
END WaveSample;

PROCEDURE AdsrValueAt (VAR e: Adsr; time, noteDur: REAL): REAL;
  VAR total, sustainTime, t: REAL;
BEGIN
  IF time < 0.0 THEN RETURN 0.0 END;
  total := e.attack + e.decay + e.release;
  sustainTime := noteDur - total; IF sustainTime < 0.0 THEN sustainTime := 0.0 END;
  t := time;
  IF t <= e.attack THEN IF e.attack <= 0.0 THEN RETURN 1.0 ELSE RETURN t / e.attack END END;
  t := t - e.attack;
  IF t <= e.decay THEN
    IF e.decay <= 0.0 THEN RETURN e.sustain ELSE RETURN 1.0 - (t / e.decay) * (1.0 - e.sustain) END
  END;
  t := t - e.decay;
  IF t <= sustainTime THEN RETURN e.sustain END;
  t := t - sustainTime;
  IF t <= e.release THEN IF e.release <= 0.0 THEN RETURN 0.0 ELSE RETURN e.sustain * (1.0 - t / e.release) END END;
  RETURN 0.0
END AdsrValueAt;

(* ---- buffer + normalize ------------------------------------------------ *)

PROCEDURE NewSound (VAR s: Sound; sr, ch: CARDINAL; dur: REAL);
  VAR n, i: CARDINAL; a: ADDRESS;
BEGIN
  s.sampleRate := sr; s.channels := ch; s.duration := dur;
  n := truncToCard(VAL(REAL, sr) * dur) * ch;
  IF n > MaxSamples THEN n := MaxSamples END;
  IF n = 0 THEN n := ch END;
  s.count := n;
  ALLOCATE(a, n * SIZE(REAL));
  s.samples := CAST(PSampleBuf, a);
  FOR i := 0 TO n-1 DO s.samples^[i] := 0.0 END
END NewSound;

PROCEDURE FreeSound (VAR s: Sound);
  VAR a: ADDRESS;
BEGIN
  IF s.samples # NIL THEN
    a := CAST(ADDRESS, s.samples);
    DEALLOCATE(a, s.count * SIZE(REAL));
    s.samples := NIL; s.count := 0
  END
END FreeSound;

PROCEDURE Normalize (VAR s: Sound; target: REAL);
  VAR i: CARDINAL; peak, a, scale: REAL;
BEGIN
  peak := 0.0;
  FOR i := 0 TO s.count-1 DO a := RAbs(s.samples^[i]); IF a > peak THEN peak := a END END;
  IF peak > 1.0 THEN
    scale := Clamp(target, 0.0, 1.0) / peak;
    FOR i := 0 TO s.count-1 DO s.samples^[i] := s.samples^[i] * scale END
  END
END Normalize;

(* ---- the render pipeline (engine.rs:218-313) --------------------------- *)

PROCEDURE Render (VAR s: Sound; VAR e: Effect);
  VAR frameCount, f, i, ch, delayFrames, echo, echoStart, frame, idx: CARDINAL;
      clamped, dt, time, sample, phase, sweepT, freq, drive, denom, env, n, amp: REAL;
BEGIN
  clamped := Clamp(e.duration, 0.0, 10.0);
  IF clamped <= 0.0 THEN clamped := 0.01 END;
  NewSound(s, SampleRate, 2, clamped);
  frameCount := s.count DIV s.channels;
  dt := 1.0 / VAL(REAL, SampleRate);
  FOR f := 0 TO frameCount-1 DO
    time := VAL(REAL, f) * dt;
    sample := 0.0;
    IF e.oscCount > 0 THEN
      FOR i := 0 TO e.oscCount-1 DO
        phase := TwoPi * e.osc[i].frequency * time + e.osc[i].phase;
        sample := sample + WaveSample(e.osc[i].wave, phase, e.osc[i].pulseWidth) * e.osc[i].amplitude
      END
    END;
    IF e.sweepStart # e.sweepEnd THEN
      sweepT := 0.0; IF clamped > 0.0 THEN sweepT := time / clamped END;
      freq := e.sweepStart + (e.sweepEnd - e.sweepStart) * sweepT;
      sample := sample + WaveSample(WSine, TwoPi * freq * time, 0.5) * 0.5
    END;
    IF e.noiseMix > 0.0 THEN
      n := NextSigned();
      sample := sample * (1.0 - e.noiseMix) + n * e.noiseMix
    END;
    env := AdsrValueAt(e.env, time, e.duration);          (* unclamped duration *)
    sample := sample * env;
    IF e.distortion > 0.0 THEN
      drive := 1.0 + e.distortion * 10.0; denom := tanh(drive);
      IF denom # 0.0 THEN sample := tanh(sample * drive) / denom END
    END;
    FOR ch := 0 TO s.channels-1 DO s.samples^[f * s.channels + ch] := sample * 0.5 END
  END;
  IF (e.echoCount > 0) AND (e.echoDelay > 0.0) THEN
    delayFrames := truncToCard(e.echoDelay * VAL(REAL, SampleRate));
    FOR echo := 0 TO e.echoCount-1 DO
      echoStart := delayFrames * (echo + 1); amp := pow(e.echoDecay, VAL(REAL, echo + 1));
      IF echoStart < frameCount THEN
        FOR frame := 0 TO frameCount - echoStart - 1 DO
          FOR ch := 0 TO s.channels-1 DO
            idx := (frame + echoStart) * s.channels + ch;
            s.samples^[idx] := s.samples^[idx] + s.samples^[frame * s.channels + ch] * amp
          END
        END
      END
    END
  END;
  Normalize(s, 0.9)
END Render;

(* ---- effect builders --------------------------------------------------- *)

PROCEDURE ClearEffect (VAR e: Effect; dur: REAL);
BEGIN
  e.duration := dur; e.oscCount := 0;
  e.env.attack := 0.01; e.env.decay := 0.1; e.env.sustain := 0.7; e.env.release := 0.2;
  e.sweepStart := 0.0; e.sweepEnd := 0.0; e.noiseMix := 0.0; e.distortion := 0.0;
  e.echoCount := 0; e.echoDelay := 0.0; e.echoDecay := 0.0
END ClearEffect;

PROCEDURE AddOsc (VAR e: Effect; wave: Waveform; freq, amp: REAL);
BEGIN
  IF e.oscCount <= 3 THEN
    e.osc[e.oscCount].wave := wave; e.osc[e.oscCount].frequency := freq;
    e.osc[e.oscCount].amplitude := amp; e.osc[e.oscCount].phase := 0.0;
    e.osc[e.oscCount].pulseWidth := 0.5; INC(e.oscCount)
  END
END AddOsc;

PROCEDURE SetEnv (VAR e: Effect; a, d, sus, r: REAL);
BEGIN e.env.attack := a; e.env.decay := d; e.env.sustain := sus; e.env.release := r END SetEnv;

(* ---- presets (presets.rs) ---------------------------------------------- *)

PROCEDURE Beep (VAR s: Sound; freq, dur: REAL);
  VAR e: Effect;
BEGIN ClearEffect(e, dur); AddOsc(e, WSine, freq, 0.5); SetEnv(e, 0.01, 0.05, 0.7, 0.1); Render(s, e) END Beep;

PROCEDURE Coin (VAR s: Sound; dur: REAL);
  VAR e: Effect;
BEGIN
  ClearEffect(e, dur); AddOsc(e, WSine, 987.77, 0.5); AddOsc(e, WSine, 1318.51, 0.3);
  SetEnv(e, 0.01, 0.1, 0.3, 0.15); Render(s, e)
END Coin;

PROCEDURE Jump (VAR s: Sound; dur: REAL);
  VAR e: Effect;
BEGIN
  ClearEffect(e, dur); e.sweepStart := 300.0; e.sweepEnd := 600.0;
  SetEnv(e, 0.01, 0.05, 0.5, 0.1); Render(s, e)
END Jump;

PROCEDURE Zap (VAR s: Sound; dur: REAL);
  VAR e: Effect;
BEGIN
  ClearEffect(e, dur); e.sweepStart := 1000.0; e.sweepEnd := 100.0; e.noiseMix := 0.2;
  SetEnv(e, 0.01, 0.05, 0.3, 0.08); Render(s, e)
END Zap;

PROCEDURE Shoot (VAR s: Sound; dur: REAL);
  VAR e: Effect;
BEGIN
  ClearEffect(e, dur); e.sweepStart := 800.0; e.sweepEnd := 200.0; e.noiseMix := 0.3;
  SetEnv(e, 0.01, 0.05, 0.4, 0.08); Render(s, e)
END Shoot;

PROCEDURE Explode (VAR s: Sound; size, dur: REAL);
  VAR e: Effect;
BEGIN
  ClearEffect(e, dur);
  AddOsc(e, WSine, 58.0, 0.95); AddOsc(e, WTriangle, 86.0, 0.28);
  e.noiseMix := Clamp(0.06 * size, 0.0, 0.12);
  e.sweepStart := 135.0; e.sweepEnd := 32.0; e.distortion := 0.08;
  SetEnv(e, 0.0015, 0.14, 0.0, 0.10); Render(s, e)
END Explode;

PROCEDURE Powerup (VAR s: Sound; dur: REAL);
  VAR e: Effect;
BEGIN
  ClearEffect(e, dur); AddOsc(e, WSquare, 400.0, 0.4); e.sweepStart := 200.0; e.sweepEnd := 800.0;
  SetEnv(e, 0.1, 0.1, 0.8, 0.2); Render(s, e)
END Powerup;

PROCEDURE Hurt (VAR s: Sound; dur: REAL);
  VAR e: Effect;
BEGIN
  ClearEffect(e, dur); e.sweepStart := 600.0; e.sweepEnd := 200.0; e.noiseMix := 0.4;
  SetEnv(e, 0.01, 0.1, 0.2, 0.15); Render(s, e)
END Hurt;

PROCEDURE Click (VAR s: Sound; dur: REAL);
  VAR e: Effect;
BEGIN
  ClearEffect(e, dur); AddOsc(e, WNoise, 440.0, 0.3); SetEnv(e, 0.001, 0.01, 0.0, 0.03); Render(s, e)
END Click;

PROCEDURE Bang (VAR s: Sound; dur: REAL);
  VAR e: Effect;
BEGIN
  ClearEffect(e, dur); e.noiseMix := 0.8; SetEnv(e, 0.01, 0.05, 0.0, 0.1); Render(s, e)
END Bang;

PROCEDURE Blip (VAR s: Sound; pitch, dur: REAL);
BEGIN Beep(s, 800.0 * pitch, dur) END Blip;

PROCEDURE Tone (VAR s: Sound; freq, dur: REAL; wave: Waveform);
  VAR e: Effect; pw: REAL;
BEGIN
  ClearEffect(e, dur); SetEnv(e, 0.01, 0.05, 0.8, 0.1);
  IF freq < 1.0 THEN freq := 1.0 END;
  AddOsc(e, wave, freq, 0.75);
  IF wave = WPulse THEN pw := 0.25 ELSE pw := 0.5 END;
  e.osc[0].pulseWidth := pw;
  Render(s, e)
END Tone;

(* coloured noise (synth.rs:93-128) *)
PROCEDURE Noise (VAR s: Sound; kind: CARDINAL; dur: REAL);
  VAR frameCount, f, ch: CARDINAL;
      p0, p1, p2, brown, value, t, env: REAL;
BEGIN
  IF dur < 0.01 THEN dur := 0.01 END;
  NewSound(s, SampleRate, 2, dur);
  frameCount := s.count DIV s.channels;
  p0 := 0.0; p1 := 0.0; p2 := 0.0; brown := 0.0;
  FOR f := 0 TO frameCount-1 DO
    value := NextSigned();
    IF kind = 1 THEN                                   (* pink (Paul Kellet) *)
      p0 := 0.99765 * p0 + value * 0.0990460;
      p1 := 0.96300 * p1 + value * 0.2965164;
      p2 := 0.57000 * p2 + value * 1.0526913;
      value := (p0 + p1 + p2 + value * 0.1848) * 0.25
    ELSIF kind = 2 THEN                                (* brown *)
      brown := brown + value * 0.02; brown := Clamp(brown, -1.0, 1.0); value := brown
    END;
    t := VAL(REAL, f) / VAL(REAL, frameCount); env := (1.0 - t) * (1.0 - t);
    value := value * env * 0.6;
    FOR ch := 0 TO s.channels-1 DO s.samples^[f * s.channels + ch] := value END
  END;
  Normalize(s, 0.95)
END Noise;

PROCEDURE NoteToFrequency (midi: INTEGER): REAL;
BEGIN RETURN 440.0 * pow(2.0, VAL(REAL, midi - 69) / 12.0) END NoteToFrequency;

BEGIN
  gState := 12345
END Audio.
