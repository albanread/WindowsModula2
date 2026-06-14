IMPLEMENTATION MODULE SecureRandom;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM Security_Cryptography IMPORT
  BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG, BCRYPT_ALG_HANDLE;
FROM WIN32 IMPORT DWORD;

CONST ChunkMax = 40000000H;   (* 1 GiB per BCryptGenRandom call (cbBuffer is DWORD) *)

PROCEDURE FillBytes (buf: ADDRESS; count: CARDINAL): BOOLEAN;
  VAR h: BCRYPT_ALG_HANDLE; p: ADDRESS; remaining, chunk: CARDINAL; status: INTEGER;
BEGIN
  h.Value := NIL;                              (* NULL alg handle = system-preferred RNG *)
  p := buf; remaining := count;
  WHILE remaining > 0 DO
    IF remaining > ChunkMax THEN chunk := ChunkMax ELSE chunk := remaining END;
    status := BCryptGenRandom(h, p, VAL(DWORD, chunk), BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    IF status # 0 THEN RETURN FALSE END;       (* STATUS_SUCCESS = 0 *)
    p := CAST(ADDRESS, CAST(CARDINAL, p) + chunk);
    remaining := remaining - chunk
  END;
  RETURN TRUE
END FillBytes;

PROCEDURE NextCard (): CARDINAL;
  VAR w: CARDINAL;
BEGIN
  IF NOT FillBytes(ADR(w), 8) THEN HALT END;   (* fail closed — never return predictable bytes *)
  RETURN w
END NextCard;

PROCEDURE NextBelow (bound: CARDINAL): CARDINAL;
  VAR rem, threshold, w: CARDINAL;
BEGIN
  IF bound = 0 THEN RETURN 0 END;              (* defensive; caller contract is bound > 0 *)
  (* 2^64 MOD bound, computed without 2^64: (MAX MOD bound) + 1, folded. *)
  rem := (MAX(CARDINAL) MOD bound + 1) MOD bound;
  IF rem = 0 THEN
    RETURN NextCard() MOD bound                (* bound divides 2^64 -> already unbiased *)
  END;
  (* threshold = largest multiple of bound <= 2^64 = 2^64 - rem = MAX - (rem-1) *)
  threshold := MAX(CARDINAL) - (rem - 1);
  REPEAT w := NextCard() UNTIL w < threshold;  (* reject the biased tail *)
  RETURN w MOD bound
END NextBelow;

PROCEDURE NextRange (low, high: CARDINAL): CARDINAL;
  VAR span: CARDINAL;
BEGIN
  span := high - low + 1;
  IF span = 0 THEN RETURN NextCard() END;      (* full CARDINAL range *)
  RETURN low + NextBelow(span)
END NextRange;

END SecureRandom.
