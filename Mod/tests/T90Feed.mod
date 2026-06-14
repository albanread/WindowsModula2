IMPLEMENTATION MODULE T90Feed;
(* Emits "hello" one char at a time, then rEnd — dispatched through a
   device record's procedure pointer, exactly like IOChan.Look. The
   `res := rEnd` / `res := rOk` stores in doLook exercise store-width
   coercion: an enum member lowers at the default i64 width but `res`
   (VAR Res) is a 4-byte slot in the caller; without a store-width
   coercion the 8-byte store overruns and clobbers the caller's adjacent
   open-array $high companion. *)
IMPORT SYSTEM;

TYPE
  LookP = PROCEDURE(DevPtr, VAR CHAR, VAR Res);
  SkipP = PROCEDURE(DevPtr);
  Dev   = RECORD doLook: LookP; doSkip: SkipP; END;

VAR
  dev: Dev;
  src: ARRAY [0..9] OF CHAR;
  p, n: CARDINAL;
  started: BOOLEAN;

PROCEDURE prime;
BEGIN
  IF started THEN RETURN END;
  started := TRUE;
  src[0]:='h'; src[1]:='e'; src[2]:='l'; src[3]:='l'; src[4]:='o';
  n := 5; p := 0;
END prime;

PROCEDURE doLook(d: DevPtr; VAR ch: CHAR; VAR res: Res);
BEGIN
  IF p >= n THEN res := rEnd; ch := ' ';
  ELSE res := rOk; ch := src[p]; END;
END doLook;

PROCEDURE doSkip(d: DevPtr);
BEGIN INC(p); END doSkip;

PROCEDURE chan(): DevPtr;
BEGIN
  prime;
  dev.doLook := doLook; dev.doSkip := doSkip;
  RETURN SYSTEM.ADR(dev);
END chan;

PROCEDURE Look(d: DevPtr; VAR ch: CHAR; VAR res: Res);
BEGIN d^.doLook(d, ch, res); END Look;

PROCEDURE Skip(d: DevPtr);
BEGIN d^.doSkip(d); END Skip;

BEGIN started := FALSE; END T90Feed.
