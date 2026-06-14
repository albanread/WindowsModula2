MODULE t90010;
(* Cross-module enum VAR-param store must not overrun the
   caller's open-array $high companion. This mirrors TextIO.ReadToken
   reading from a channel device (T90Feed = a miniature IOChan/device).

   `ReadTok` has a VAR open-array param `s`; its hidden `s$high`
   companion sits next to the enum local `res`. T90Feed.Look ->
   doLook writes `res` with an enum member that lowers at i64; if the
   store isn't narrowed to the enum's i32 slot it clobbers `s$high`,
   making HIGH(s) read 0 — the loop then copies a single char and the
   early-RETURN reports the wrong length. "hello len=5" proves HIGH(s)
   stayed intact. *)
IMPORT T90Feed, STextIO, WholeStr;

VAR tok: ARRAY [0..63] OF CHAR; o: ARRAY [0..15] OF CHAR;

PROCEDURE ReadTok(cid: T90Feed.DevPtr; VAR s: ARRAY OF CHAR): CARDINAL;
  VAR res: T90Feed.Res; ch: CHAR; i: CARDINAL; valid: BOOLEAN;
BEGIN
  REPEAT
    T90Feed.Look(cid, ch, res);
    IF res = T90Feed.rOk THEN valid := TRUE; T90Feed.Skip(cid); END;
  UNTIL ((res # T90Feed.rOk) OR valid);
  i := 0;
  WHILE (res = T90Feed.rOk) & valid & (i <= HIGH(s)) DO
    s[i] := ch; INC(i);
    T90Feed.Look(cid, ch, res);
    valid := res = T90Feed.rOk;
    IF (res = T90Feed.rOk) & valid THEN T90Feed.Skip(cid) END;
  END;
  IF i <= HIGH(s) THEN
    s[i] := 0C;
    IF i > 0 THEN RETURN i END;
  ELSIF (res = T90Feed.rOk) & valid THEN
    RETURN 888;
  END;
  RETURN 999;
END ReadTok;

VAR n: CARDINAL;
BEGIN
  n := ReadTok(T90Feed.chan(), tok);
  STextIO.WriteString(tok); STextIO.WriteString(" len=");
  WholeStr.CardToStr(n, o); STextIO.WriteString(o); STextIO.WriteLn;
END t90010.
