IMPLEMENTATION MODULE Abc;

(* ABC -> timed MIDI events (newaudio-abc parser.rs + midi.rs, single-voice path).
   Durations are rational (whole-note units); a running REAL ms cursor advances by
   dur * msPerWhole, where msPerWhole = timesigDenom * 60000 / bpm (so a tempo
   change just changes the rate for subsequent notes). Each note pushes a NoteOn at
   the cursor and a NoteOff at cursor+dur; events are sorted (time, then NoteOff
   before NoteOn) at the end. Accidentals follow ABC: key signature, then any
   explicit accidental persists to the rest of the bar, reset on each bar line. *)

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM NM2Math IMPORT truncToCard;

CONST
  MaxSrc = 16384; MaxLine = 2048;
  Velocity = 80;

CONST MaxVoices = 16;

TYPE
  PTune = POINTER TO Tune;
  (* saved per-voice state (the working globals snapshot a voice into/out of) *)
  VoiceState = RECORD
    used: BOOLEAN;
    name: ARRAY [0..15] OF CHAR;
    channel, instrument: INTEGER;
    curMs: REAL;
    keySharps, unitN, unitD, tsN, tsD, transpose: INTEGER;
    barAcc: ARRAY [0..6] OF INTEGER;  barSet: ARRAY [0..6] OF BOOLEAN;
  END;

VAR
  gSrc:  ARRAY [0..MaxSrc-1] OF CHAR;  gSrcLen: CARDINAL;
  gLine: ARRAY [0..MaxLine-1] OF CHAR;
  gExp:  ARRAY [0..MaxLine-1] OF CHAR;
  gT:    PTune;
  gInBody: BOOLEAN;
  gCurMs, gMsPerWhole: REAL;
  gBpm, gUnitN, gUnitD, gTsN, gTsD: INTEGER;          (* working = current voice *)
  gKeySharps, gTranspose: INTEGER;
  gChan, gInstrument: INTEGER;
  gBarAcc: ARRAY [0..6] OF INTEGER;  gBarSet: ARRAY [0..6] OF BOOLEAN;
  gTupN, gTupD, gTupRem: INTEGER;
  (* voices *)
  gVoices: ARRAY [0..MaxVoices-1] OF VoiceState;
  gNVoices, gCur, gNextChan: INTEGER;
  gDefKey, gDefUnitN, gDefUnitD, gDefTsN, gDefTsD, gDefInstr: INTEGER;

(* ---- char helpers ------------------------------------------------------ *)
PROCEDURE Up (c: CHAR): CHAR;
BEGIN IF (c >= 'a') AND (c <= 'z') THEN RETURN CHR(ORD(c)-32) ELSE RETURN c END END Up;
PROCEDURE IsDigit (c: CHAR): BOOLEAN; BEGIN RETURN (c >= '0') AND (c <= '9') END IsDigit;
PROCEDURE IsAlpha (c: CHAR): BOOLEAN;
BEGIN RETURN ((c>='A')AND(c<='Z')) OR ((c>='a')AND(c<='z')) END IsAlpha;
PROCEDURE IsNote (c: CHAR): BOOLEAN;
BEGIN RETURN ((c>='A')AND(c<='G')) OR ((c>='a')AND(c<='g')) END IsNote;
PROCEDURE IsBar (c: CHAR): BOOLEAN;
BEGIN RETURN (c='|') OR (c=':') OR (c='[') OR (c=']') END IsBar;
PROCEDURE IsAccM (c: CHAR): BOOLEAN; BEGIN RETURN (c='^') OR (c='_') OR (c='=') END IsAccM;

PROCEDURE Round (x: REAL): CARDINAL;
BEGIN IF x < 0.0 THEN RETURN 0 ELSE RETURN truncToCard(x + 0.5) END END Round;

(* ---- event output ------------------------------------------------------ *)
PROCEDURE Push (timeMs: CARDINAL; status, chan, d1, d2: CARDINAL);
BEGIN
  IF gT^.count < MaxEvents THEN
    gT^.ev[gT^.count].timeMs := timeMs; gT^.ev[gT^.count].status := status;
    gT^.ev[gT^.count].chan := chan; gT^.ev[gT^.count].d1 := d1; gT^.ev[gT^.count].d2 := d2;
    INC(gT^.count)
  END
END Push;

PROCEDURE EmitNote (midi: INTEGER; durWholes: REAL);
  VAR startMs, endMs: CARDINAL;
BEGIN
  startMs := Round(gCurMs); endMs := Round(gCurMs + durWholes * gMsPerWhole);
  Push(startMs, 90H, VAL(CARDINAL, gChan), VAL(CARDINAL, midi), Velocity);
  Push(endMs,   80H, VAL(CARDINAL, gChan), VAL(CARDINAL, midi), 0)
END EmitNote;

(* ---- pitch / duration -------------------------------------------------- *)
PROCEDURE PitchIndex (pUpper: CHAR): INTEGER;     (* A..G -> 0..6, else -1 *)
BEGIN
  CASE pUpper OF 'A':RETURN 0|'B':RETURN 1|'C':RETURN 2|'D':RETURN 3|'E':RETURN 4|'F':RETURN 5|'G':RETURN 6 ELSE RETURN -1 END
END PitchIndex;

(* sharp order FCGDAEB -> F=1..B=7;  flat order BEADGCF -> B=1..F=7 *)
PROCEDURE SharpPos (pu: CHAR): INTEGER;
BEGIN CASE pu OF 'F':RETURN 1|'C':RETURN 2|'G':RETURN 3|'D':RETURN 4|'A':RETURN 5|'E':RETURN 6|'B':RETURN 7 ELSE RETURN 99 END END SharpPos;
PROCEDURE FlatPos (pu: CHAR): INTEGER;
BEGIN CASE pu OF 'B':RETURN 1|'E':RETURN 2|'A':RETURN 3|'D':RETURN 4|'G':RETURN 5|'C':RETURN 6|'F':RETURN 7 ELSE RETURN 99 END END FlatPos;

PROCEDURE KeyAccidental (pUpper: CHAR): INTEGER;
BEGIN
  IF (gKeySharps > 0) AND (gKeySharps >= SharpPos(pUpper)) THEN RETURN 1 END;
  IF (gKeySharps < 0) AND ((-gKeySharps) >= FlatPos(pUpper)) THEN RETURN -1 END;
  RETURN 0
END KeyAccidental;

(* accidental (returns delta + how many chars consumed via VAR pos); -99 = none *)
PROCEDURE ParseAcc (VAR ln: ARRAY OF CHAR; len: CARDINAL; VAR pos: CARDINAL): INTEGER;
BEGIN
  IF pos >= len THEN RETURN -99 END;
  IF ln[pos] = '^' THEN
    IF (pos+1 < len) AND (ln[pos+1]='^') THEN pos := pos+2; RETURN 2 ELSE INC(pos); RETURN 1 END
  ELSIF ln[pos] = '_' THEN
    IF (pos+1 < len) AND (ln[pos+1]='_') THEN pos := pos+2; RETURN -2 ELSE INC(pos); RETURN -1 END
  ELSIF ln[pos] = '=' THEN INC(pos); RETURN 0
  END;
  RETURN -99
END ParseAcc;

(* duration: fills durN/durD (in whole-note units) from default unit *)
PROCEDURE ParseDur (VAR ln: ARRAY OF CHAR; len: CARDINAL; VAR pos: CARDINAL; VAR dn, dd: INTEGER);
  VAR numer, denom: INTEGER;
BEGIN
  dn := gUnitN; dd := gUnitD;
  IF (pos < len) AND IsDigit(ln[pos]) THEN
    numer := 0;
    WHILE (pos < len) AND IsDigit(ln[pos]) DO numer := numer*10 + (ORD(ln[pos])-ORD('0')); INC(pos) END;
    IF (pos < len) AND (ln[pos]='/') THEN
      INC(pos); denom := 2;
      IF (pos < len) AND IsDigit(ln[pos]) THEN
        denom := 0;
        WHILE (pos < len) AND IsDigit(ln[pos]) DO denom := denom*10 + (ORD(ln[pos])-ORD('0')); INC(pos) END
      END;
      dn := numer * gUnitN; dd := denom * gUnitD
    ELSE
      dn := numer * gUnitN; dd := gUnitD
    END
  ELSIF (pos < len) AND (ln[pos]='/') THEN
    INC(pos); denom := 2;
    IF (pos < len) AND IsDigit(ln[pos]) THEN
      denom := 0;
      WHILE (pos < len) AND IsDigit(ln[pos]) DO denom := denom*10 + (ORD(ln[pos])-ORD('0')); INC(pos) END
    END;
    dn := gUnitN; dd := gUnitD * denom
  END;
  WHILE (pos < len) AND (ln[pos]='.') DO dn := dn*3; dd := dd*2; INC(pos) END   (* dotted *)
END ParseDur;

(* parse a note at pos; returns TRUE + midi/dn/dd; updates bar accidentals *)
PROCEDURE ParseNote (VAR ln: ARRAY OF CHAR; len: CARDINAL; VAR pos: CARDINAL;
                     VAR midi, dn, dd: INTEGER): BOOLEAN;
  VAR probe: CARDINAL; explicit, acc, octave, idx, semi, base: INTEGER;
      p: CHAR; pu: CHAR; lower: BOOLEAN;
BEGIN
  IF pos >= len THEN RETURN FALSE END;
  probe := pos;
  explicit := ParseAcc(ln, len, probe);
  IF (probe >= len) OR (NOT IsNote(ln[probe])) THEN RETURN FALSE END;
  explicit := ParseAcc(ln, len, pos);
  p := ln[pos]; INC(pos);
  pu := Up(p); lower := (p >= 'a') AND (p <= 'g');
  octave := 0;
  WHILE (pos < len) AND (ln[pos]=CHR(39)) DO INC(octave); INC(pos) END;   (* ' = octave up *)
  WHILE (pos < len) AND (ln[pos]=',')  DO DEC(octave); INC(pos) END;
  ParseDur(ln, len, pos, dn, dd);
  idx := PitchIndex(pu);
  acc := KeyAccidental(pu);
  IF explicit # -99 THEN
    acc := explicit;
    IF idx >= 0 THEN gBarAcc[idx] := acc; gBarSet[idx] := TRUE END
  ELSIF (idx >= 0) AND gBarSet[idx] THEN
    acc := gBarAcc[idx]
  END;
  CASE pu OF 'A':semi:=9|'B':semi:=11|'C':semi:=0|'D':semi:=2|'E':semi:=4|'F':semi:=5|'G':semi:=7 ELSE semi:=0 END;
  base := 4; IF lower THEN base := 5 END;
  midi := base*12 + semi + acc + octave*12 + gTranspose;
  IF midi < 0 THEN midi := 0 ELSIF midi > 127 THEN midi := 127 END;
  RETURN TRUE
END ParseNote;

PROCEDURE ResetBar;
  VAR i: CARDINAL;
BEGIN FOR i := 0 TO 6 DO gBarSet[i] := FALSE END END ResetBar;

PROCEDURE ApplyTuplet (VAR dn, dd: INTEGER);
BEGIN
  IF gTupRem > 0 THEN
    dn := dn * gTupN; dd := dd * gTupD; DEC(gTupRem);
    IF gTupRem <= 0 THEN gTupN := 1; gTupD := 1 END
  END
END ApplyTuplet;

PROCEDURE SkipGrace (VAR ln: ARRAY OF CHAR; len: CARDINAL; VAR pos: CARDINAL): BOOLEAN;
BEGIN
  IF (pos >= len) OR (ln[pos] # '{') THEN RETURN FALSE END;
  INC(pos);
  WHILE (pos < len) AND (ln[pos] # '}') DO INC(pos) END;
  IF pos < len THEN INC(pos) END;
  RETURN TRUE
END SkipGrace;

(* ---- the note sequence loop (parser.rs:427-680, single voice) ---------- *)
PROCEDURE ParseSeq (VAR ln: ARRAY OF CHAR; len: CARDINAL);
  VAR pos, start, ie: CARDINAL; midi, dn, dd, p2, p3, q, r: INTEGER;
      durW: REAL; brokenLonger, hasBroken: BOOLEAN;
      nmidi, ndn, ndd: INTEGER; cnt: CARDINAL;
      cmidi: ARRAY [0..15] OF INTEGER; cn: CARDINAL;
BEGIN
  pos := 0;
  WHILE pos < len DO
    WHILE (pos < len) AND ((ln[pos]=' ') OR (ln[pos]=CHR(9))) DO INC(pos) END;
    IF pos >= len THEN RETURN END;

    IF ln[pos] = '{' THEN
      IF SkipGrace(ln, len, pos) THEN END
    ELSIF (ln[pos]='[') AND (pos+2 < len) AND IsAlpha(ln[pos+1]) AND (ln[pos+2]=':') THEN
      start := pos+3; pos := pos+3;
      IF Up(ln[start-2]) = 'V' THEN              (* [V:id] -> voice switch *)
        ie := pos; WHILE (ie<len) AND (ln[ie]#']') AND (ln[ie]#' ') AND (ln[ie]#CHR(9)) DO INC(ie) END;
        WHILE (pos < len) AND (ln[pos] # ']') DO INC(pos) END;
        SwitchVoice(ln, start, ie);
        IF pos < len THEN INC(pos) END
      ELSE                                       (* [K:..]/[Q:..]/[M:..]/[L:..] *)
        WHILE (pos < len) AND (ln[pos] # ']') DO INC(pos) END;
        ApplyInline(Up(ln[start-2]), ln, start, pos);
        IF pos < len THEN INC(pos) END
      END
    ELSIF ln[pos] = '"' THEN
      INC(pos);                                    (* guitar chord: skip "..." (silent) *)
      WHILE (pos < len) AND (ln[pos] # '"') DO INC(pos) END;
      IF pos < len THEN INC(pos) END
    ELSIF ln[pos] = '[' THEN                        (* chord [CEG] *)
      cn := 0; INC(pos);
      WHILE (pos < len) AND (ln[pos] # ']') DO
        WHILE (pos < len) AND ((ln[pos]=' ') OR (ln[pos]=CHR(9))) DO INC(pos) END;
        IF (pos < len) AND (ln[pos] # ']') THEN
          IF ParseNote(ln, len, pos, nmidi, ndn, ndd) THEN
            IF cn <= 15 THEN cmidi[cn] := nmidi; INC(cn) END
          ELSE INC(pos) END
        END
      END;
      IF (pos < len) AND (ln[pos]=']') THEN
        INC(pos); ParseDur(ln, len, pos, dn, dd);
        IF cn > 0 THEN
          durW := VAL(REAL, dn) / VAL(REAL, dd);
          cnt := 0; WHILE cnt < cn DO EmitNote(cmidi[cnt], durW); INC(cnt) END;
          gCurMs := gCurMs + durW * gMsPerWhole
        END
      END
    ELSIF IsBar(ln[pos]) THEN
      WHILE (pos < len) AND IsBar(ln[pos]) DO INC(pos) END;
      ResetBar
    ELSIF (ln[pos]='z') OR (ln[pos]='Z') THEN
      INC(pos); ParseDur(ln, len, pos, dn, dd);
      gCurMs := gCurMs + (VAL(REAL, dn)/VAL(REAL, dd)) * gMsPerWhole
    ELSIF ln[pos] = '(' THEN
      IF (pos+1 < len) AND IsDigit(ln[pos+1]) THEN ParseTuplet(ln, len, pos) ELSE INC(pos) END
    ELSIF ln[pos] = ')' THEN INC(pos)
    ELSIF IsNote(ln[pos]) OR IsAccM(ln[pos]) THEN
      IF ParseNote(ln, len, pos, midi, dn, dd) THEN
        hasBroken := FALSE; brokenLonger := FALSE;
        IF pos < len THEN
          IF ln[pos]='>' THEN hasBroken := TRUE; brokenLonger := TRUE; INC(pos)
          ELSIF ln[pos]='<' THEN hasBroken := TRUE; INC(pos) END
        END;
        IF hasBroken THEN
          IF brokenLonger THEN dn := dn*3; dd := dd*2 ELSE dn := dn*1; dd := dd*2 END
        END;
        ApplyTuplet(dn, dd);
        IF (pos < len) AND (ln[pos]='-') THEN INC(pos); MergeTie(ln, len, pos, midi, dn, dd) END;
        durW := VAL(REAL, dn)/VAL(REAL, dd);
        EmitNote(midi, durW); gCurMs := gCurMs + durW * gMsPerWhole;
        IF hasBroken THEN
          WHILE (pos < len) AND ((ln[pos]=' ') OR (ln[pos]=CHR(9))) DO INC(pos) END;
          IF (pos < len) AND IsNote(ln[pos]) THEN
            IF ParseNote(ln, len, pos, nmidi, ndn, ndd) THEN
              IF brokenLonger THEN ndn := ndn*1; ndd := ndd*2 ELSE ndn := ndn*3; ndd := ndd*2 END;
              ApplyTuplet(ndn, ndd);
              IF (pos < len) AND (ln[pos]='-') THEN INC(pos); MergeTie(ln, len, pos, nmidi, ndn, ndd) END;
              durW := VAL(REAL, ndn)/VAL(REAL, ndd);
              EmitNote(nmidi, durW); gCurMs := gCurMs + durW * gMsPerWhole
            END
          END
        END
      ELSE INC(pos) END
    ELSE INC(pos) END
  END
END ParseSeq;

(* tie merge: while tied, sum durations of same-pitch following notes *)
PROCEDURE MergeTie (VAR ln: ARRAY OF CHAR; len: CARDINAL; VAR pos: CARDINAL;
                    midi: INTEGER; VAR dn, dd: INTEGER);
  VAR scan: CARDINAL; nmidi, ndn, ndd: INTEGER; tied: BOOLEAN;
BEGIN
  tied := TRUE;
  WHILE tied DO
    scan := pos;
    WHILE (scan < len) AND ((ln[scan]=' ')OR(ln[scan]=CHR(9))OR(ln[scan]=CHR(13))OR(ln[scan]='|')OR(ln[scan]=':')) DO INC(scan) END;
    IF (scan >= len) OR (NOT IsNote(ln[scan])) THEN tied := FALSE
    ELSE
      IF NOT ParseNote(ln, len, scan, nmidi, ndn, ndd) THEN tied := FALSE
      ELSIF nmidi # midi THEN tied := FALSE
      ELSE
        dn := dn*ndd + ndn*dd; dd := dd*ndd;     (* fraction add *)
        pos := scan;
        IF (pos < len) AND (ln[pos]='-') THEN INC(pos) ELSE tied := FALSE END
      END
    END
  END
END MergeTie;

PROCEDURE ParseTuplet (VAR ln: ARRAY OF CHAR; len: CARDINAL; VAR pos: CARDINAL);
  VAR p, q, r, infq: INTEGER; compound: BOOLEAN;
BEGIN
  INC(pos);                                       (* '(' *)
  p := ORD(ln[pos]) - ORD('0'); INC(pos);
  q := -1; r := -1;
  IF (pos < len) AND (ln[pos]=':') THEN
    INC(pos);
    IF (pos < len) AND IsDigit(ln[pos]) THEN q := ORD(ln[pos])-ORD('0'); INC(pos) END;
    IF (pos < len) AND (ln[pos]=':') THEN
      INC(pos);
      IF (pos < len) AND IsDigit(ln[pos]) THEN r := ORD(ln[pos])-ORD('0'); INC(pos) END
    END
  END;
  compound := (gTsD = 8) AND ((gTsN=6) OR (gTsN=9) OR (gTsN=12));
  CASE p OF
    2: infq:=3 | 3: infq:=2 | 4: infq:=3 | 6: infq:=2 | 8: infq:=3
  ELSE IF compound THEN infq := 3 ELSE infq := 2 END END;
  IF q < 0 THEN q := infq END;
  IF r < 0 THEN r := p END;
  IF (p > 0) AND (q > 0) AND (r > 0) THEN gTupN := q; gTupD := p; gTupRem := r END
END ParseTuplet;

(* ---- headers / inline -------------------------------------------------- *)
PROCEDURE TrimLen (VAR s: ARRAY OF CHAR; VAR n: CARDINAL);
BEGIN WHILE (n > 0) AND ((s[n-1]=' ')OR(s[n-1]=CHR(9))OR(s[n-1]=CHR(13))) DO DEC(n) END END TrimLen;

PROCEDURE ParseMeter (VAR s: ARRAY OF CHAR; from, to: CARDINAL);
  VAR i, num, den: CARDINAL; slash: BOOLEAN;
BEGIN
  (* C / C| / n/d *)
  IF (from < to) AND (Up(s[from])='C') THEN
    IF (from+1 < to) AND (s[from+1]='|') THEN gTsN := 2; gTsD := 2 ELSE gTsN := 4; gTsD := 4 END;
    RETURN
  END;
  num := 0; den := 0; slash := FALSE;
  FOR i := from TO to-1 DO
    IF s[i]='/' THEN slash := TRUE
    ELSIF IsDigit(s[i]) THEN
      IF slash THEN den := den*10 + (ORD(s[i])-ORD('0')) ELSE num := num*10 + (ORD(s[i])-ORD('0')) END
    END
  END;
  IF (num > 0) AND (den > 0) THEN gTsN := VAL(INTEGER, num); gTsD := VAL(INTEGER, den) END
END ParseMeter;

PROCEDURE ParseFrac (VAR s: ARRAY OF CHAR; from, to: CARDINAL; VAR n, d: INTEGER);
  VAR i, num, den: CARDINAL; slash: BOOLEAN;
BEGIN
  num := 0; den := 0; slash := FALSE;
  FOR i := from TO to-1 DO
    IF s[i]='/' THEN slash := TRUE
    ELSIF IsDigit(s[i]) THEN
      IF slash THEN den := den*10 + (ORD(s[i])-ORD('0')) ELSE num := num*10 + (ORD(s[i])-ORD('0')) END
    END
  END;
  IF (num > 0) AND (den > 0) THEN n := VAL(INTEGER, num); d := VAL(INTEGER, den) END
END ParseFrac;

PROCEDURE ParseBpm (VAR s: ARRAY OF CHAR; from, to: CARDINAL): INTEGER;
  VAR i, start, num: CARDINAL;
BEGIN
  start := from;                                   (* after the last '=' *)
  FOR i := from TO to-1 DO IF s[i]='=' THEN start := i+1 END END;
  num := 0;
  FOR i := start TO to-1 DO IF IsDigit(s[i]) THEN num := num*10 + (ORD(s[i])-ORD('0')) END END;
  IF num = 0 THEN RETURN gBpm ELSE RETURN VAL(INTEGER, num) END
END ParseBpm;

PROCEDURE ParseKey (VAR s: ARRAY OF CHAR; from, to: CARDINAL): INTEGER;
  VAR c0, c1: CHAR;
BEGIN
  IF from >= to THEN RETURN 0 END;
  c0 := s[from]; IF from+1 < to THEN c1 := s[from+1] ELSE c1 := ' ' END;
  IF (c0='C') AND (c1='#') THEN RETURN 7 END;
  IF (c0='F') AND (c1='#') THEN RETURN 6 END;
  IF (c0='C') AND (c1='b') THEN RETURN -7 END;
  IF (c0='G') AND (c1='b') THEN RETURN -6 END;
  IF (c0='D') AND (c1='b') THEN RETURN -5 END;
  IF (c0='A') AND (c1='b') THEN RETURN -4 END;
  IF (c0='E') AND (c1='b') THEN RETURN -3 END;
  IF (c0='B') AND (c1='b') THEN RETURN -2 END;
  CASE c0 OF 'B':RETURN 5|'E':RETURN 4|'A':RETURN 3|'D':RETURN 2|'G':RETURN 1|'F':RETURN -1 ELSE RETURN 0 END
END ParseKey;

PROCEDURE Recompute;
BEGIN gMsPerWhole := VAL(REAL, gTsD) * 60000.0 / VAL(REAL, gBpm) END Recompute;

(* apply an inline field K/Q/M/L in the body (s[from..to) is the value) *)
PROCEDURE ApplyInline (field: CHAR; VAR s: ARRAY OF CHAR; from, to: CARDINAL);
BEGIN
  CASE field OF
    'K': gKeySharps := ParseKey(s, from, to)
  | 'Q': gBpm := ParseBpm(s, from, to); Recompute
  | 'M': ParseMeter(s, from, to); Recompute
  | 'L': ParseFrac(s, from, to, gUnitN, gUnitD)
  ELSE END
END ApplyInline;

PROCEDURE ParseHeader (VAR s: ARRAY OF CHAR; n: CARDINAL);
  VAR field: CHAR; from: CARDINAL;
BEGIN
  field := Up(s[0]); from := 2;
  WHILE (from < n) AND ((s[from]=' ')OR(s[from]=CHR(9))) DO INC(from) END;
  CASE field OF
    'M': ParseMeter(s, from, n)
  | 'L': ParseFrac(s, from, n, gUnitN, gUnitD)
  | 'Q': gBpm := ParseBpm(s, from, n)
  | 'K': gKeySharps := ParseKey(s, from, n)
  ELSE END
END ParseHeader;

(* %%MIDI program/channel/transpose/drum -> apply to the CURRENT voice *)
PROCEDURE ParseMidiDir (VAR s: ARRAY OF CHAR; n: CARDINAL);
  VAR i, num: CARDINAL; neg: BOOLEAN; c0, c1: CHAR;
BEGIN
  IF n < 6 THEN RETURN END;
  i := 6; WHILE (i < n) AND ((s[i]=' ')OR(s[i]=CHR(9))) DO INC(i) END;
  IF i >= n THEN RETURN END;
  c0 := Lower(s[i]); IF i+1 < n THEN c1 := Lower(s[i+1]) ELSE c1 := ' ' END;
  (* advance to the numeric argument *)
  WHILE (i < n) AND (s[i]#' ') AND (s[i]#CHR(9)) DO INC(i) END;
  WHILE (i < n) AND ((s[i]=' ')OR(s[i]=CHR(9))) DO INC(i) END;
  neg := FALSE; IF (i < n) AND (s[i]='-') THEN neg := TRUE; INC(i) END;
  num := 0; WHILE (i < n) AND IsDigit(s[i]) DO num := num*10 + (ORD(s[i])-ORD('0')); INC(i) END;
  IF (c0='p') AND (c1='r') THEN                              (* program *)
    IF num <= 127 THEN gInstrument := VAL(INTEGER, num) END
  ELSIF (c0='c') AND (c1='h') THEN                           (* channel (1..16) *)
    IF (num >= 1) AND (num <= 16) THEN gChan := VAL(INTEGER, num) - 1 END
  ELSIF (c0='t') THEN                                        (* transpose *)
    IF neg THEN gTranspose := -VAL(INTEGER, num) ELSE gTranspose := VAL(INTEGER, num) END
  ELSIF (c0='d') OR (c0='p') THEN                            (* drum / percussion *)
    gChan := 9
  END
END ParseMidiDir;

(* ---- per-line dispatch + repeat expansion ------------------------------ *)
PROCEDURE ExpandRepeat (VAR src: ARRAY OF CHAR; n: CARDINAL; VAR dst: ARRAY OF CHAR; VAR dn: CARDINAL);
  VAR i, s2, e2, k: CARDINAL; found: BOOLEAN;
BEGIN
  (* single-line |: inner :|  -> inner inner ; first occurrence only *)
  found := FALSE; i := 0;
  WHILE (i+1 < n) AND (NOT found) DO
    IF (src[i]='|') AND (src[i+1]=':') THEN found := TRUE ELSE INC(i) END
  END;
  IF NOT found THEN
    dn := n; FOR k := 0 TO n-1 DO dst[k] := src[k] END; RETURN
  END;
  s2 := i+2; e2 := s2;
  WHILE (e2+1 < n) AND (NOT ((src[e2]=':') AND (src[e2+1]='|'))) DO INC(e2) END;
  IF (e2+1 >= n) OR (NOT ((src[e2]=':') AND (src[e2+1]='|'))) THEN
    dn := n; FOR k := 0 TO n-1 DO dst[k] := src[k] END; RETURN
  END;
  dn := 0;
  FOR k := 0 TO i-1 DO dst[dn] := src[k]; INC(dn) END;          (* before |: *)
  FOR k := s2 TO e2-1 DO dst[dn] := src[k]; INC(dn) END;        (* inner *)
  dst[dn] := ' '; INC(dn);
  FOR k := s2 TO e2-1 DO dst[dn] := src[k]; INC(dn) END;        (* inner again *)
  FOR k := e2+2 TO n-1 DO dst[dn] := src[k]; INC(dn) END        (* after :| *)
END ExpandRepeat;

(* ---- voices ------------------------------------------------------------ *)
PROCEDURE SaveCur;
  VAR i: CARDINAL;
BEGIN
  IF (gCur >= 0) AND (gCur < gNVoices) THEN
    gVoices[gCur].curMs := gCurMs; gVoices[gCur].keySharps := gKeySharps;
    gVoices[gCur].unitN := gUnitN; gVoices[gCur].unitD := gUnitD;
    gVoices[gCur].tsN := gTsN; gVoices[gCur].tsD := gTsD;
    gVoices[gCur].transpose := gTranspose;
    gVoices[gCur].channel := gChan; gVoices[gCur].instrument := gInstrument;
    FOR i := 0 TO 6 DO gVoices[gCur].barAcc[i] := gBarAcc[i]; gVoices[gCur].barSet[i] := gBarSet[i] END
  END
END SaveCur;

PROCEDURE LoadCur;
  VAR i: CARDINAL;
BEGIN
  gCurMs := gVoices[gCur].curMs; gKeySharps := gVoices[gCur].keySharps;
  gUnitN := gVoices[gCur].unitN; gUnitD := gVoices[gCur].unitD;
  gTsN := gVoices[gCur].tsN; gTsD := gVoices[gCur].tsD;
  gTranspose := gVoices[gCur].transpose;
  gChan := gVoices[gCur].channel; gInstrument := gVoices[gCur].instrument;
  FOR i := 0 TO 6 DO gBarAcc[i] := gVoices[gCur].barAcc[i]; gBarSet[i] := gVoices[gCur].barSet[i] END;
  Recompute
END LoadCur;

PROCEDURE AssignChannel (): INTEGER;
  VAR ch: INTEGER;
BEGIN
  ch := gNextChan; IF ch = 9 THEN ch := 10 END; IF ch > 15 THEN ch := 15 END;
  gNextChan := ch + 1; IF gNextChan = 9 THEN gNextChan := 10 END;
  RETURN ch
END AssignChannel;

PROCEDURE NameEq (VAR vname: ARRAY OF CHAR; VAR ident: ARRAY OF CHAR; from, to: CARDINAL): BOOLEAN;
  VAR vlen, i: CARDINAL;
BEGIN
  vlen := 0; WHILE (vlen <= HIGH(vname)) AND (vname[vlen] # 0C) DO INC(vlen) END;
  IF vlen # (to - from) THEN RETURN FALSE END;
  IF vlen > 0 THEN FOR i := 0 TO vlen-1 DO IF vname[i] # ident[from+i] THEN RETURN FALSE END END END;
  RETURN TRUE
END NameEq;

PROCEDURE FindVoice (VAR ident: ARRAY OF CHAR; from, to: CARDINAL): INTEGER;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE i < VAL(CARDINAL, gNVoices) DO
    IF gVoices[i].used AND NameEq(gVoices[i].name, ident, from, to) THEN RETURN VAL(INTEGER, i) END;
    INC(i)
  END;
  RETURN -1
END FindVoice;

PROCEDURE CreateVoice (VAR ident: ARRAY OF CHAR; from, to: CARDINAL): INTEGER;
  VAR idx, k, i: CARDINAL;
BEGIN
  IF gNVoices >= MaxVoices THEN RETURN gCur END;
  idx := VAL(CARDINAL, gNVoices); INC(gNVoices);
  gVoices[idx].used := TRUE;
  k := 0; FOR i := from TO to-1 DO IF k < 15 THEN gVoices[idx].name[k] := ident[i]; INC(k) END END;
  gVoices[idx].name[k] := 0C;
  gVoices[idx].channel := AssignChannel(); gVoices[idx].instrument := gDefInstr;
  gVoices[idx].curMs := 0.0; gVoices[idx].keySharps := gDefKey;
  gVoices[idx].unitN := gDefUnitN; gVoices[idx].unitD := gDefUnitD;
  gVoices[idx].tsN := gDefTsN; gVoices[idx].tsD := gDefTsD; gVoices[idx].transpose := 0;
  FOR i := 0 TO 6 DO gVoices[idx].barSet[i] := FALSE; gVoices[idx].barAcc[i] := 0 END;
  RETURN VAL(INTEGER, idx)
END CreateVoice;

PROCEDURE SwitchVoice (VAR ident: ARRAY OF CHAR; from, to: CARDINAL);
  VAR i: INTEGER;
BEGIN
  IF to <= from THEN RETURN END;
  SaveCur;
  i := FindVoice(ident, from, to);
  IF i < 0 THEN i := CreateVoice(ident, from, to) END;
  gCur := i; LoadCur
END SwitchVoice;

PROCEDURE Lower (c: CHAR): CHAR;
BEGIN IF (c >= 'A') AND (c <= 'Z') THEN RETURN CHR(ORD(c)+32) ELSE RETURN c END END Lower;

PROCEDURE HandleVoiceLine (VAR ln: ARRAY OF CHAR; n: CARDINAL);
  VAR i, idStart, idEnd: CARDINAL;
BEGIN
  i := 2; WHILE (i < n) AND ((ln[i]=' ')OR(ln[i]=CHR(9))) DO INC(i) END;
  idStart := i;
  WHILE (i < n) AND (ln[i]#' ') AND (ln[i]#CHR(9)) DO INC(i) END;
  idEnd := i;
  SwitchVoice(ln, idStart, idEnd)
END HandleVoiceLine;

PROCEDURE SnapshotDefaults;
BEGIN
  gDefKey := gKeySharps; gDefUnitN := gUnitN; gDefUnitD := gUnitD;
  gDefTsN := gTsN; gDefTsD := gTsD; gDefInstr := gInstrument
END SnapshotDefaults;

PROCEDURE ProcessLine (VAR ln: ARRAY OF CHAR; n: CARDINAL);
  VAR en: CARDINAL;
BEGIN
  TrimLen(ln, n);
  IF n = 0 THEN RETURN END;
  IF (n >= 6) AND (ln[0]='%') AND (ln[1]='%') AND (Up(ln[2])='M') AND (Up(ln[3])='I') THEN
    ParseMidiDir(ln, n); RETURN
  END;
  IF ln[0] = '%' THEN RETURN END;
  IF (n >= 2) AND (Up(ln[0])='V') AND (ln[1]=':') THEN HandleVoiceLine(ln, n); RETURN END;
  IF (n >= 2) AND IsAlpha(ln[0]) AND (ln[1]=':') THEN
    IF gInBody THEN ApplyInline(Up(ln[0]), ln, 2, n)
    ELSE
      ParseHeader(ln, n);
      IF Up(ln[0]) = 'K' THEN gInBody := TRUE; SnapshotDefaults; Recompute END
    END;
    RETURN
  END;
  IF NOT gInBody THEN gInBody := TRUE; SnapshotDefaults; Recompute END;
  ExpandRepeat(ln, n, gExp, en);
  ParseSeq(gExp, en)
END ProcessLine;

PROCEDURE Sort;
  VAR i, j: CARDINAL; key: CARDINAL; tmp: MidiEvent;
  PROCEDURE Pri (st: CARDINAL): CARDINAL;
  BEGIN IF st=80H THEN RETURN 1 ELSIF st=0B0H THEN RETURN 2 ELSIF st=0C0H THEN RETURN 3 ELSE RETURN 4 END END Pri;
BEGIN
  (* insertion sort by (timeMs, priority) *)
  FOR i := 1 TO gT^.count-1 DO
    tmp := gT^.ev[i]; key := tmp.timeMs*16 + Pri(tmp.status); j := i;
    WHILE (j >= 1) AND (gT^.ev[j-1].timeMs*16 + Pri(gT^.ev[j-1].status) > key) DO
      gT^.ev[j] := gT^.ev[j-1]; DEC(j)
    END;
    gT^.ev[j] := tmp
  END
END Sort;

PROCEDURE ParseTune (text: ARRAY OF CHAR; VAR t: Tune): BOOLEAN;
  VAR i, ls, ll: CARDINAL; c: CHAR; maxEnd: CARDINAL;
BEGIN
  gT := CAST(PTune, ADR(t));
  gT^.count := 0;
  gInBody := FALSE; gCurMs := 0.0; gMsPerWhole := 2000.0;
  gBpm := 120; gUnitN := 1; gUnitD := 8; gTsN := 4; gTsD := 4;
  gKeySharps := 0; gTranspose := 0; gChan := 0; gInstrument := 0;
  gDefKey := 0; gDefUnitN := 1; gDefUnitD := 8; gDefTsN := 4; gDefTsD := 4; gDefInstr := 0;
  ResetBar; gTupN := 1; gTupD := 1; gTupRem := 0;
  gNVoices := 1; gCur := 0; gNextChan := 1;          (* default voice "1" on channel 0 *)
  gVoices[0].used := TRUE; gVoices[0].name[0] := '1'; gVoices[0].name[1] := 0C;
  gVoices[0].channel := 0; gVoices[0].instrument := 0;
  (* copy source *)
  gSrcLen := 0;
  i := 0;
  WHILE (i <= HIGH(text)) AND (text[i] # 0C) AND (gSrcLen < MaxSrc-1) DO
    gSrc[gSrcLen] := text[i]; INC(gSrcLen); INC(i)
  END;
  (* walk lines *)
  ls := 0;
  WHILE ls <= gSrcLen DO
    ll := 0;
    WHILE (ls < gSrcLen) AND (gSrc[ls] # CHR(10)) DO
      IF ll < MaxLine-1 THEN gLine[ll] := gSrc[ls]; INC(ll) END; INC(ls)
    END;
    ProcessLine(gLine, ll);
    INC(ls)                                        (* skip the newline *)
  END;
  SaveCur;                                           (* flush current voice's instrument *)
  FOR i := 0 TO VAL(CARDINAL, gNVoices)-1 DO
    Push(0, 0C0H, VAL(CARDINAL, gVoices[i].channel), VAL(CARDINAL, gVoices[i].instrument), 0)
  END;
  Sort;
  maxEnd := 0;
  FOR i := 0 TO gT^.count-1 DO IF gT^.ev[i].timeMs > maxEnd THEN maxEnd := gT^.ev[i].timeMs END END;
  t.bpm := VAL(CARDINAL, gBpm); t.endMs := maxEnd;
  RETURN gT^.count > 0
END ParseTune;

BEGIN
  gSrcLen := 0; gNVoices := 1; gCur := 0
END Abc.
