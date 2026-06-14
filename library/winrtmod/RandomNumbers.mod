IMPLEMENTATION MODULE RandomNumbers;

IMPORT SysClock;

CONST
  Top     = 55;     (* state size = lag k *)
  LagGap  = 31;     (* initial j; the constant index gap *)
  LcgMult = 9821;   (* seed-fill / stir LCG multiplier *)
  WarmUp  = 220;    (* 4*Top warm-up steps after the seed fill *)

VAR
  Table: RandomStream;   (* the global/implicit stream *)

(* All arithmetic here is intentionally overflow-WRAPPING modulo 2^64 — that
   wrap IS the generator's word modulus. NewM2 CARDINAL + / * wrap (they do not
   trap), so plain additions/multiplications are correct. *)

PROCEDURE GetSeed (): CARDINAL;
  (* Clock-derived seed, used only when the caller passes seed = 0. NOT secure. *)
  VAR dt: SysClock.DateTime; seed: CARDINAL;
BEGIN
  SysClock.GetClock(dt);
  seed := VAL(CARDINAL, dt.fractions)
          + 1000 * (VAL(CARDINAL, dt.second)
                    + 60 * (VAL(CARDINAL, dt.minute)
                            + 60 * VAL(CARDINAL, dt.hour)));
  seed := seed * VAL(CARDINAL, dt.day);
  seed := seed * VAL(CARDINAL, dt.month);
  seed := seed * VAL(CARDINAL, dt.year);
  seed := seed * LcgMult + 1;     (* two LCG stirs *)
  seed := seed * LcgMult + 1;
  IF seed = 0 THEN seed := 1 END; (* never hand SeedStream the auto-seed sentinel *)
  RETURN seed
END GetSeed;

PROCEDURE SeedStream (VAR s: RandomStream; seed: CARDINAL);
  VAR k, i, j: CARDINAL;
BEGIN
  IF seed = 0 THEN seed := GetSeed() END;
  (* LCG seed-fill of the state array *)
  s.oldStuff[1] := seed;
  FOR k := 2 TO Top DO
    s.oldStuff[k] := s.oldStuff[k - 1] * LcgMult + 1
  END;
  (* warm-up: diffuse the seed through the lag network before any output *)
  i := 0; j := LagGap;
  FOR k := 1 TO WarmUp DO
    INC(i); INC(j);
    IF i > Top THEN i := 1 END;
    IF j > Top THEN j := 1 END;
    s.oldStuff[i] := s.oldStuff[i] + s.oldStuff[j]
  END;
  s.i := i; s.j := j     (* stored state is i = Top, j = LagGap *)
END SeedStream;

PROCEDURE Draw (VAR s: RandomStream; range: CARDINAL): CARDINAL;
  (* Advance the lag indices, fold in the lagged word, return the new word. *)
BEGIN
  INC(s.i); INC(s.j);
  IF s.i > Top THEN s.i := 1 END;
  IF s.j > Top THEN s.j := 1 END;
  s.oldStuff[s.i] := s.oldStuff[s.i] + s.oldStuff[s.j];
  IF range = 0 THEN
    RETURN s.oldStuff[s.i]
  ELSE
    RETURN s.oldStuff[s.i] MOD range
  END
END Draw;

PROCEDURE RndStream (VAR s: RandomStream; range: CARDINAL): CARDINAL;
BEGIN
  RETURN Draw(s, range)
END RndStream;

PROCEDURE RangeStream (VAR s: RandomStream; low, high: CARDINAL): CARDINAL;
BEGIN
  RETURN low + Draw(s, high - low + 1)   (* span = 0 (full range) -> Draw raw *)
END RangeStream;

(* ---- global-stream wrappers ---- *)

PROCEDURE Randomize (seed: CARDINAL);
BEGIN
  SeedStream(Table, seed)
END Randomize;

PROCEDURE Rnd (range: CARDINAL): CARDINAL;
BEGIN
  RETURN Draw(Table, range)
END Rnd;

PROCEDURE Random (low, high: CARDINAL): CARDINAL;
BEGIN
  RETURN low + Draw(Table, high - low + 1)
END Random;

BEGIN
  SeedStream(Table, 0)   (* auto-seed the global stream at load *)
END RandomNumbers.
