IMPLEMENTATION MODULE WaveOut;

(* WinMM waveOut double-buffer player + software voice mixer (pcm_runtime.rs). Open
   the device with CALLBACK_NULL, prepare 4 blocks of 2048 frames, and run a worker
   thread that every ~2 ms re-fills any block not flagged WHDR_INQUEUE: it sums the
   active voices (per-voice L/R gain + fade) in REAL, applies master gain, clamps to
   i16, and waveOutWrites it. Voice-list reads/writes are guarded by a critical
   section. No WOM_DONE callback — polling WHDR_INQUEUE is the lowest-risk path. *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM WIN32 IMPORT DWORD, PSTR;
FROM Audio IMPORT Sound;
FROM MemUtils IMPORT ZeroMem;
FROM NM2Math IMPORT truncToInt;
FROM System_Threading IMPORT Sleep;
IMPORT Threads;
FROM Media_Audio IMPORT waveOutOpen, waveOutPrepareHeader, waveOutWrite,
  waveOutUnprepareHeader, waveOutReset, waveOutClose,
  WAVEFORMATEX, WAVEHDR, HWAVEOUT, WAVE_FORMAT_PCM, WAVE_MAPPER, WHDR_INQUEUE, CALLBACK_NULL;

CONST
  NumBlocks = 4; FramesPerBlock = 2048;
  BlockBytes = FramesPerBlock * 2 * 2;         (* stereo, 16-bit *)
  MaxVoices = 32;
  Rate = 44100;

TYPE
  PSound = POINTER TO Sound;
  Voice = RECORD
    active, looping, fading: BOOLEAN;
    handle: CARDINAL;
    snd: PSound;
    framePos: CARDINAL;
    gainL, gainR, fadeGain, fadeDec: REAL;
  END;

VAR
  gHwo:    HWAVEOUT;
  gFmt:    WAVEFORMATEX;
  gBlocks: ARRAY [0..NumBlocks-1] OF WAVEHDR;
  gData:   ARRAY [0..NumBlocks-1] OF ARRAY [0..BlockBytes-1] OF BYTE;
  gVoices: ARRAY [0..MaxVoices-1] OF Voice;
  gLock:   Threads.Lock;
  gThread: Threads.Thread;
  gMaster: REAL;
  gNextHandle: CARDINAL;
  gShutdown, gReady: BOOLEAN;

(* clamp REAL sample -> 2 little-endian i16 bytes in block k at byte offset off *)
PROCEDURE PutI16 (k, off: CARDINAL; x: REAL);
  VAR v: INTEGER; u: CARDINAL;
BEGIN
  IF x < -1.0 THEN x := -1.0 ELSIF x > 1.0 THEN x := 1.0 END;
  x := x * 32767.0;
  IF x >= 0.0 THEN v := truncToInt(x + 0.5) ELSE v := truncToInt(x - 0.5) END;
  IF v < 0 THEN u := VAL(CARDINAL, v + 65536) ELSE u := VAL(CARDINAL, v) END;
  gData[k][off]   := VAL(BYTE, u BAND 0FFH);
  gData[k][off+1] := VAL(BYTE, (u DIV 256) BAND 0FFH)
END PutI16;

PROCEDURE FillBlock (k: CARDINAL);
  VAR wf, vi, src, total, ch, off: CARDINAL;
      mixL, mixR, l, r, fg, gg: REAL;
BEGIN
  gg := gMaster; off := 0;
  FOR wf := 0 TO FramesPerBlock-1 DO
    mixL := 0.0; mixR := 0.0;
    FOR vi := 0 TO MaxVoices-1 DO
      IF gVoices[vi].active AND (gVoices[vi].snd # NIL) AND (gVoices[vi].snd^.count > 0) THEN
        ch := gVoices[vi].snd^.channels;
        total := gVoices[vi].snd^.count DIV ch;
        IF gVoices[vi].framePos >= total THEN
          IF gVoices[vi].looping THEN gVoices[vi].framePos := 0 ELSE gVoices[vi].active := FALSE END
        END;
        IF gVoices[vi].active THEN
          src := gVoices[vi].framePos * ch;
          l := gVoices[vi].snd^.samples^[src];
          IF ch > 1 THEN r := gVoices[vi].snd^.samples^[src+1] ELSE r := l END;
          IF gVoices[vi].fading THEN fg := gVoices[vi].fadeGain ELSE fg := 1.0 END;
          mixL := mixL + l * gVoices[vi].gainL * fg;
          mixR := mixR + r * gVoices[vi].gainR * fg;
          IF gVoices[vi].fading THEN
            gVoices[vi].fadeGain := gVoices[vi].fadeGain - gVoices[vi].fadeDec;
            IF gVoices[vi].fadeGain <= 0.0 THEN gVoices[vi].active := FALSE END
          END;
          INC(gVoices[vi].framePos)
        END
      END
    END;
    PutI16(k, off, mixL * gg); off := off + 2;
    PutI16(k, off, mixR * gg); off := off + 2
  END
END FillBlock;

PROCEDURE MixerThread (param: ADDRESS): CARDINAL;
  VAR k: CARDINAL; r: DWORD;
BEGIN
  WHILE NOT gShutdown DO
    Threads.Acquire(gLock);
    FOR k := 0 TO NumBlocks-1 DO
      IF (gBlocks[k].dwFlags BAND WHDR_INQUEUE) = 0 THEN
        FillBlock(k);
        r := waveOutWrite(gHwo, ADR(gBlocks[k]), VAL(DWORD, SIZE(WAVEHDR)))
      END
    END;
    Threads.Release(gLock);
    Sleep(VAL(DWORD, 2))
  END;
  RETURN 0
END MixerThread;

PROCEDURE Startup (): BOOLEAN;
  VAR k: CARDINAL; r: DWORD;
BEGIN
  IF gReady THEN RETURN TRUE END;
  ZeroMem(ADR(gFmt), SIZE(gFmt));
  gFmt.wFormatTag := VAL(WORD, WAVE_FORMAT_PCM);
  gFmt.nChannels := VAL(WORD, 2);
  gFmt.nSamplesPerSec := VAL(DWORD, Rate);
  gFmt.wBitsPerSample := VAL(WORD, 16);
  gFmt.nBlockAlign := VAL(WORD, 4);
  gFmt.nAvgBytesPerSec := VAL(DWORD, Rate * 4);
  gFmt.cbSize := VAL(WORD, 0);
  gHwo.Value := NIL;
  r := waveOutOpen(ADR(gHwo), VAL(DWORD, WAVE_MAPPER), ADR(gFmt), 0, 0, VAL(DWORD, CALLBACK_NULL));
  IF r # 0 THEN RETURN FALSE END;
  FOR k := 0 TO NumBlocks-1 DO
    ZeroMem(ADR(gBlocks[k]), SIZE(WAVEHDR));
    gBlocks[k].lpData := CAST(PSTR, ADR(gData[k][0]));
    gBlocks[k].dwBufferLength := VAL(DWORD, BlockBytes);
    r := waveOutPrepareHeader(gHwo, ADR(gBlocks[k]), VAL(DWORD, SIZE(WAVEHDR)))
  END;
  FOR k := 0 TO MaxVoices-1 DO gVoices[k].active := FALSE END;
  gMaster := 1.0; gNextHandle := 1; gShutdown := FALSE;
  Threads.InitLock(gLock);
  gThread := Threads.Spawn(MixerThread, NIL);
  gReady := TRUE;
  RETURN TRUE
END Startup;

PROCEDURE Shutdown;
  VAR k: CARDINAL; r: DWORD; ok: BOOLEAN;
BEGIN
  IF NOT gReady THEN RETURN END;
  gShutdown := TRUE;
  ok := Threads.Join(gThread, 2000);
  Threads.CloseThread(gThread);
  r := waveOutReset(gHwo);
  FOR k := 0 TO NumBlocks-1 DO r := waveOutUnprepareHeader(gHwo, ADR(gBlocks[k]), VAL(DWORD, SIZE(WAVEHDR))) END;
  r := waveOutClose(gHwo);
  Threads.DestroyLock(gLock);
  gReady := FALSE
END Shutdown;

PROCEDURE AddVoice (VAR s: Sound; volume, pan: REAL; loop: BOOLEAN): CARDINAL;
  VAR i, h: CARDINAL; p: REAL;
BEGIN
  IF NOT gReady THEN RETURN 0 END;
  Threads.Acquire(gLock);
  i := 0; WHILE (i < MaxVoices) AND gVoices[i].active DO INC(i) END;
  IF i >= MaxVoices THEN Threads.Release(gLock); RETURN 0 END;
  p := pan; IF p < -1.0 THEN p := -1.0 ELSIF p > 1.0 THEN p := 1.0 END;
  gVoices[i].snd := CAST(PSound, ADR(s));
  gVoices[i].framePos := 0;
  IF p <= 0.0 THEN gVoices[i].gainL := volume ELSE gVoices[i].gainL := volume * (1.0 - p) END;
  IF p >= 0.0 THEN gVoices[i].gainR := volume ELSE gVoices[i].gainR := volume * (1.0 + p) END;
  gVoices[i].looping := loop;
  gVoices[i].fading := FALSE; gVoices[i].fadeGain := 1.0; gVoices[i].fadeDec := 0.0;
  h := gNextHandle; INC(gNextHandle); gVoices[i].handle := h;
  gVoices[i].active := TRUE;
  Threads.Release(gLock);
  RETURN h
END AddVoice;

PROCEDURE Play (VAR s: Sound; volume, pan: REAL): CARDINAL;
BEGIN RETURN AddVoice(s, volume, pan, FALSE) END Play;

PROCEDURE PlayLooped (VAR s: Sound; volume, pan: REAL): CARDINAL;
BEGIN RETURN AddVoice(s, volume, pan, TRUE) END PlayLooped;

PROCEDURE StopVoice (handle: CARDINAL; fadeSecs: REAL);
  VAR i: CARDINAL; frames: REAL;
BEGIN
  IF NOT gReady THEN RETURN END;
  Threads.Acquire(gLock);
  FOR i := 0 TO MaxVoices-1 DO
    IF gVoices[i].active AND (gVoices[i].handle = handle) THEN
      IF fadeSecs <= 0.0 THEN gVoices[i].active := FALSE
      ELSE
        frames := fadeSecs * VAL(REAL, Rate); IF frames < 1.0 THEN frames := 1.0 END;
        gVoices[i].fading := TRUE; gVoices[i].fadeGain := 1.0;
        gVoices[i].fadeDec := 1.0 / frames; gVoices[i].looping := FALSE
      END
    END
  END;
  Threads.Release(gLock)
END StopVoice;

PROCEDURE StopAll;
  VAR i: CARDINAL;
BEGIN
  IF NOT gReady THEN RETURN END;
  Threads.Acquire(gLock);
  FOR i := 0 TO MaxVoices-1 DO gVoices[i].active := FALSE END;
  Threads.Release(gLock)
END StopAll;

PROCEDURE SetMasterVolume (v: REAL);
BEGIN
  IF v < 0.0 THEN v := 0.0 ELSIF v > 1.0 THEN v := 1.0 END;
  gMaster := v
END SetMasterVolume;

PROCEDURE ActiveVoices (): CARDINAL;
  VAR i, n: CARDINAL;
BEGIN
  n := 0;
  IF gReady THEN
    Threads.Acquire(gLock);
    FOR i := 0 TO MaxVoices-1 DO IF gVoices[i].active THEN INC(n) END END;
    Threads.Release(gLock)
  END;
  RETURN n
END ActiveVoices;

BEGIN
  gReady := FALSE; gShutdown := FALSE; gMaster := 1.0; gNextHandle := 1
END WaveOut.
