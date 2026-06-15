IMPLEMENTATION MODULE WavFile;

(* Canonical PCM RIFF/WAVE I/O (wav.rs). The writer builds the 44-byte header +
   interleaved i16 little-endian samples into one heap buffer and writes it in a
   single call. The reader slurps the file, walks the chunk list, and decodes the
   data chunk to REAL samples per the source bit-depth divisors. *)

FROM SYSTEM IMPORT ADDRESS, CAST;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
FROM NM2Math IMPORT truncToInt;
FROM Audio IMPORT Sound, PSampleBuf, MaxSamples, SampleRate;
IMPORT FileFunc;

CONST MaxWavBytes = 44 + MaxSamples*2;

TYPE
  ByteBuf  = ARRAY [0..MaxWavBytes-1] OF BYTE;
  PByteBuf = POINTER TO ByteBuf;

PROCEDURE PutU16 (b: PByteBuf; off, v: CARDINAL);
BEGIN
  b^[off]   := VAL(BYTE, v BAND 0FFH);
  b^[off+1] := VAL(BYTE, (v DIV 256) BAND 0FFH)
END PutU16;

PROCEDURE PutU32 (b: PByteBuf; off, v: CARDINAL);
BEGIN
  b^[off]   := VAL(BYTE, v BAND 0FFH);
  b^[off+1] := VAL(BYTE, (v DIV 256) BAND 0FFH);
  b^[off+2] := VAL(BYTE, (v DIV 65536) BAND 0FFH);
  b^[off+3] := VAL(BYTE, (v DIV 16777216) BAND 0FFH)
END PutU32;

PROCEDURE Put4 (b: PByteBuf; off: CARDINAL; c0, c1, c2, c3: CHAR);
BEGIN
  b^[off] := VAL(BYTE, ORD(c0)); b^[off+1] := VAL(BYTE, ORD(c1));
  b^[off+2] := VAL(BYTE, ORD(c2)); b^[off+3] := VAL(BYTE, ORD(c3))
END Put4;

PROCEDURE GetU16 (b: PByteBuf; off: CARDINAL): CARDINAL;
BEGIN RETURN VAL(CARDINAL, b^[off]) BAND 0FFH + (VAL(CARDINAL, b^[off+1]) BAND 0FFH) * 256 END GetU16;

PROCEDURE GetU32 (b: PByteBuf; off: CARDINAL): CARDINAL;
BEGIN
  RETURN (VAL(CARDINAL, b^[off]) BAND 0FFH)
       + (VAL(CARDINAL, b^[off+1]) BAND 0FFH) * 256
       + (VAL(CARDINAL, b^[off+2]) BAND 0FFH) * 65536
       + (VAL(CARDINAL, b^[off+3]) BAND 0FFH) * 16777216
END GetU32;

PROCEDURE Clamp (x, lo, hi: REAL): REAL;
BEGIN IF x < lo THEN RETURN lo ELSIF x > hi THEN RETURN hi ELSE RETURN x END END Clamp;

(* sample -> signed 16-bit, rounded half away from zero *)
PROCEDURE ToI16 (x, gain: REAL): INTEGER;
  VAR scaled: REAL;
BEGIN
  scaled := Clamp(x * gain, -1.0, 1.0) * 32767.0;
  IF scaled >= 0.0 THEN RETURN truncToInt(scaled + 0.5) ELSE RETURN truncToInt(scaled - 0.5) END
END ToI16;

PROCEDURE WriteWav (path: ARRAY OF CHAR; VAR s: Sound; volume: REAL): BOOLEAN;
  VAR b: PByteBuf; a: ADDRESS; f: FileFunc.File;
      dataSize, byteRate, blockAlign, total, i, off: CARDINAL; gain: REAL;
      v, u: INTEGER; wrote: CARDINAL;
BEGIN
  IF s.count = 0 THEN RETURN FALSE END;
  gain := volume; IF gain < 0.0 THEN gain := 0.0 END;
  dataSize := s.count * 2;
  byteRate := s.sampleRate * s.channels * 2;
  blockAlign := s.channels * 2;
  total := 44 + dataSize;
  ALLOCATE(a, total); IF a = NIL THEN RETURN FALSE END;
  b := CAST(PByteBuf, a);
  Put4(b, 0, 'R','I','F','F');   PutU32(b, 4, 36 + dataSize);
  Put4(b, 8, 'W','A','V','E');   Put4(b, 12, 'f','m','t',' ');
  PutU32(b, 16, 16);             PutU16(b, 20, 1);              (* PCM *)
  PutU16(b, 22, s.channels);     PutU32(b, 24, s.sampleRate);
  PutU32(b, 28, byteRate);       PutU16(b, 32, blockAlign);
  PutU16(b, 34, 16);             Put4(b, 36, 'd','a','t','a');
  PutU32(b, 40, dataSize);
  off := 44;
  FOR i := 0 TO s.count-1 DO
    v := ToI16(s.samples^[i], gain);
    IF v < 0 THEN u := v + 65536 ELSE u := v END;
    b^[off]   := VAL(BYTE, VAL(CARDINAL, u) BAND 0FFH);
    b^[off+1] := VAL(BYTE, (VAL(CARDINAL, u) DIV 256) BAND 0FFH);
    off := off + 2
  END;
  f := FileFunc.Create(path);
  IF NOT FileFunc.IsValid(f) THEN DEALLOCATE(a, total); RETURN FALSE END;
  wrote := FileFunc.WriteBytes(f, a, total);
  FileFunc.Close(f);
  DEALLOCATE(a, total);
  RETURN wrote = total
END WriteWav;

PROCEDURE ReadWav (path: ARRAY OF CHAR; VAR s: Sound): BOOLEAN;
  VAR f: FileFunc.File; b: PByteBuf; a, sa: ADDRESS;
      fsize, got, pos, chunkSize, fmtOff, dataOff, dataLen: CARDINAL;
      tag, channels, sr, bits, bytesPerSample, n, i: CARDINAL;
      haveFmt, haveData: BOOLEAN; val: INTEGER; c0, c1, c2: CARDINAL;
BEGIN
  f := FileFunc.OpenRead(path);
  IF NOT FileFunc.IsValid(f) THEN RETURN FALSE END;
  fsize := FileFunc.Size(f);
  IF (fsize < 44) OR (fsize > MaxWavBytes) THEN FileFunc.Close(f); RETURN FALSE END;
  ALLOCATE(a, fsize); IF a = NIL THEN FileFunc.Close(f); RETURN FALSE END;
  b := CAST(PByteBuf, a);
  got := FileFunc.ReadBytes(f, a, fsize);
  FileFunc.Close(f);
  IF got < 44 THEN DEALLOCATE(a, fsize); RETURN FALSE END;
  (* 'RIFF' .... 'WAVE' *)
  IF (b^[0] # VAL(BYTE, ORD('R'))) OR (b^[8] # VAL(BYTE, ORD('W'))) THEN DEALLOCATE(a, fsize); RETURN FALSE END;
  haveFmt := FALSE; haveData := FALSE; fmtOff := 0; dataOff := 0; dataLen := 0;
  pos := 12;
  WHILE pos + 8 <= got DO
    chunkSize := GetU32(b, pos + 4);
    IF (b^[pos] = VAL(BYTE, ORD('f'))) AND (b^[pos+1] = VAL(BYTE, ORD('m'))) THEN
      fmtOff := pos + 8; haveFmt := TRUE
    ELSIF (b^[pos] = VAL(BYTE, ORD('d'))) AND (b^[pos+1] = VAL(BYTE, ORD('a'))) THEN
      dataOff := pos + 8; dataLen := chunkSize; haveData := TRUE
    END;
    pos := pos + 8 + chunkSize + (chunkSize BAND 1)            (* honour odd-size pad *)
  END;
  IF NOT (haveFmt AND haveData) THEN DEALLOCATE(a, fsize); RETURN FALSE END;
  tag := GetU16(b, fmtOff); channels := GetU16(b, fmtOff + 2);
  sr := GetU32(b, fmtOff + 4); bits := GetU16(b, fmtOff + 14);
  IF (tag # 1) OR ((channels # 1) AND (channels # 2)) THEN DEALLOCATE(a, fsize); RETURN FALSE END;
  IF (bits # 8) AND (bits # 16) AND (bits # 24) AND (bits # 32) THEN DEALLOCATE(a, fsize); RETURN FALSE END;
  IF dataOff + dataLen > got THEN dataLen := got - dataOff END;
  bytesPerSample := bits DIV 8;
  n := dataLen DIV bytesPerSample;
  IF n > MaxSamples THEN n := MaxSamples END;
  ALLOCATE(sa, n * SIZE(REAL));
  IF sa = NIL THEN DEALLOCATE(a, fsize); RETURN FALSE END;
  s.sampleRate := sr; s.channels := channels; s.count := n;
  s.samples := CAST(PSampleBuf, sa);
  FOR i := 0 TO n-1 DO
    pos := dataOff + i * bytesPerSample;
    IF bits = 8 THEN
      s.samples^[i] := (VAL(REAL, VAL(CARDINAL, b^[pos]) BAND 0FFH) - 128.0) / 128.0
    ELSIF bits = 16 THEN
      val := VAL(INTEGER, GetU16(b, pos)); IF val >= 32768 THEN val := val - 65536 END;
      s.samples^[i] := VAL(REAL, val) / 32768.0
    ELSIF bits = 24 THEN
      c0 := VAL(CARDINAL, b^[pos]) BAND 0FFH; c1 := VAL(CARDINAL, b^[pos+1]) BAND 0FFH;
      c2 := VAL(CARDINAL, b^[pos+2]) BAND 0FFH;
      val := VAL(INTEGER, c0 + c1*256 + c2*65536);
      IF val >= 8388608 THEN val := val - 16777216 END;
      s.samples^[i] := VAL(REAL, val) / 8388608.0
    ELSE                                                       (* 32-bit *)
      val := VAL(INTEGER, GetU32(b, pos));
      s.samples^[i] := VAL(REAL, val) / 2147483648.0
    END
  END;
  s.duration := VAL(REAL, n DIV channels) / VAL(REAL, sr);
  DEALLOCATE(a, fsize);
  RETURN TRUE
END ReadWav;

END WavFile.
