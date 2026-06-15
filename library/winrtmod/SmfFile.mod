IMPLEMENTATION MODULE SmfFile;

(* Format-0 Standard MIDI File writer (midi.rs write_smf). Header MThd {format 0,
   1 track, division 480 ppq}; one MTrk = a Set-Tempo meta at delta 0, then every
   event as VLQ(delta-ticks) + status/data (full status byte each time, no running
   status), then End-of-Track. Absolute ms -> ticks via tick = round(ms*bpm/125)
   (480 ticks/quarter recovered exactly), deltas from consecutive absolute ticks. *)

FROM SYSTEM IMPORT ADDRESS, ADR;
FROM NM2Math IMPORT truncToCard;
FROM Abc IMPORT Tune;
IMPORT FileFunc;

CONST MaxSmf = 262144;

VAR gBuf: ARRAY [0..MaxSmf-1] OF BYTE;

PROCEDURE PutB (VAR pos: CARDINAL; b: CARDINAL);
BEGIN gBuf[pos] := VAL(BYTE, b BAND 0FFH); INC(pos) END PutB;

PROCEDURE PutU16BE (VAR pos: CARDINAL; v: CARDINAL);
BEGIN PutB(pos, v DIV 256); PutB(pos, v) END PutU16BE;

PROCEDURE PutU32BE (VAR pos: CARDINAL; v: CARDINAL);
BEGIN PutB(pos, v DIV 16777216); PutB(pos, v DIV 65536); PutB(pos, v DIV 256); PutB(pos, v) END PutU32BE;

PROCEDURE PutU32BEat (at: CARDINAL; v: CARDINAL);
BEGIN
  gBuf[at]   := VAL(BYTE, (v DIV 16777216) BAND 0FFH);
  gBuf[at+1] := VAL(BYTE, (v DIV 65536) BAND 0FFH);
  gBuf[at+2] := VAL(BYTE, (v DIV 256) BAND 0FFH);
  gBuf[at+3] := VAL(BYTE, v BAND 0FFH)
END PutU32BEat;

PROCEDURE Put4 (VAR pos: CARDINAL; c0, c1, c2, c3: CHAR);
BEGIN PutB(pos, ORD(c0)); PutB(pos, ORD(c1)); PutB(pos, ORD(c2)); PutB(pos, ORD(c3)) END Put4;

(* variable-length quantity: 7-bit big-endian groups, continuation bit on all but last *)
PROCEDURE PutVLQ (VAR pos: CARDINAL; value: CARDINAL);
  VAR buf: ARRAY [0..3] OF CARDINAL; i: INTEGER; v: CARDINAL;
BEGIN
  v := value; i := 0; buf[0] := v BAND 7FH; v := v DIV 128;
  WHILE v > 0 DO INC(i); buf[i] := (v BAND 7FH) BOR 80H; v := v DIV 128 END;
  WHILE i >= 0 DO PutB(pos, buf[VAL(CARDINAL, i)]); DEC(i) END
END PutVLQ;

PROCEDURE TickOf (ms, bpm: CARDINAL): CARDINAL;
BEGIN RETURN truncToCard(VAL(REAL, ms) * VAL(REAL, bpm) / 125.0 + 0.5) END TickOf;

PROCEDURE WriteSmf (path: ARRAY OF CHAR; VAR t: Tune): BOOLEAN;
  VAR pos, lenAt, trkStart, i, lastTick, tk, delta, mpq, bpm: CARDINAL;
      st, ch, statusByte: CARDINAL; f: FileFunc.File; wrote: CARDINAL;
BEGIN
  IF t.count = 0 THEN RETURN FALSE END;
  bpm := t.bpm; IF bpm = 0 THEN bpm := 120 END;
  pos := 0;
  (* MThd: format 0, 1 track, 480 ppq *)
  Put4(pos, 'M','T','h','d'); PutU32BE(pos, 6);
  PutU16BE(pos, 0); PutU16BE(pos, 1); PutU16BE(pos, 480);
  (* MTrk *)
  Put4(pos, 'M','T','r','k');
  lenAt := pos; PutU32BE(pos, 0);                  (* length backpatched below *)
  trkStart := pos;
  (* tempo meta at delta 0: FF 51 03 mpq(3 BE) *)
  mpq := 60000000 DIV bpm;
  PutVLQ(pos, 0); PutB(pos, 0FFH); PutB(pos, 51H); PutB(pos, 3);
  PutB(pos, mpq DIV 65536); PutB(pos, mpq DIV 256); PutB(pos, mpq);
  (* events *)
  lastTick := 0;
  FOR i := 0 TO t.count-1 DO
    tk := TickOf(t.ev[i].timeMs, bpm);
    delta := tk - lastTick; lastTick := tk;       (* events are time-sorted *)
    PutVLQ(pos, delta);
    st := t.ev[i].status; ch := t.ev[i].chan;
    statusByte := st BOR (ch BAND 0FH);
    PutB(pos, statusByte);
    PutB(pos, t.ev[i].d1);
    IF st # 0C0H THEN PutB(pos, t.ev[i].d2) END    (* program change has no data2 *)
  END;
  (* end of track *)
  PutVLQ(pos, 0); PutB(pos, 0FFH); PutB(pos, 2FH); PutB(pos, 0);
  PutU32BEat(lenAt, pos - trkStart);
  (* write file *)
  f := FileFunc.Create(path);
  IF NOT FileFunc.IsValid(f) THEN RETURN FALSE END;
  wrote := FileFunc.WriteBytes(f, ADR(gBuf), pos);
  FileFunc.Close(f);
  RETURN wrote = pos
END WriteSmf;

END SmfFile.
