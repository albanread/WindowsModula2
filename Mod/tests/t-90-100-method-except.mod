MODULE t90100;
(* EXCEPT / FINALLY inside a CLASS method.
   - SafeDiv: protected body raises on divide-by-zero; the EXCEPT handler
     writes a sentinel into a bare field (implicit WITH SELF) and RETURNs.
   - Touch:   a FINALLY part runs on the normal path and bumps a field via
     explicit SELF.field.
   Exercises SELF + params threaded through the protected exception frame and
   the implicit WITH SELF re-established in both the protected fn and handler. *)
IMPORT STextIO, SWholeIO, NM2RT;
VAR src : NM2RT.ExceptionSource;

CLASS Calc;
  VAR last : INTEGER;   (* records the last result / sentinel *)
  VAR hits : INTEGER;   (* bumped by the FINALLY part *)

  PROCEDURE SafeDiv(a, b : INTEGER) : INTEGER;
  VAR q : INTEGER;
  BEGIN
    IF b = 0 THEN
      NM2RT.Raise(src, 99, "div by zero")
    END;
    q := a DIV b;
    SELF.last := q;          (* explicit SELF.field in protected body *)
    RETURN q
  EXCEPT
    last := -1;              (* bare field in the handler *)
    RETURN -1
  END SafeDiv;

  PROCEDURE Touch(d : INTEGER) : INTEGER;
  BEGIN
    RETURN d + 1
  FINALLY
    SELF.hits := SELF.hits + 1   (* FINALLY runs on the normal path *)
  END Touch;

  PROCEDURE Hits() : INTEGER;
  BEGIN RETURN hits END Hits;
END Calc;

VAR c : Calc;

BEGIN
  src := NM2RT.AllocateExceptionSource();
  NEW(c);
  c.last := 0; c.hits := 0;
  SWholeIO.WriteInt(c.SafeDiv(20, 4), 0); STextIO.WriteLn;   (* 5 *)
  SWholeIO.WriteInt(c.SafeDiv(20, 0), 0); STextIO.WriteLn;   (* -1 (caught) *)
  SWholeIO.WriteInt(c.last, 0); STextIO.WriteLn;             (* -1 (sentinel) *)
  SWholeIO.WriteInt(c.Touch(41), 0); STextIO.WriteLn;        (* 42 *)
  SWholeIO.WriteInt(c.Touch(7), 0); STextIO.WriteLn;         (* 8 *)
  SWholeIO.WriteInt(c.Hits(), 0); STextIO.WriteLn            (* 2 (FINALLY ran twice) *)
END t90100.
