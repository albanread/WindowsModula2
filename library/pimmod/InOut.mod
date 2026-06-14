IMPLEMENTATION MODULE InOut;

IMPORT STextIO, SWholeIO;

(* --- output ----------------------------------------------------------- *)

PROCEDURE Write (ch: CHAR);
BEGIN
  STextIO.WriteChar(ch)
END Write;

PROCEDURE WriteLn;
BEGIN
  STextIO.WriteLn
END WriteLn;

PROCEDURE WriteString (s: ARRAY OF CHAR);
BEGIN
  STextIO.WriteString(s)
END WriteString;

PROCEDURE WriteInt (n: INTEGER; w: CARDINAL);
BEGIN
  SWholeIO.WriteInt(n, w)
END WriteInt;

PROCEDURE WriteCard (n: CARDINAL; w: CARDINAL);
BEGIN
  SWholeIO.WriteCard(n, w)
END WriteCard;

PROCEDURE Digit (d: CARDINAL): CHAR;
BEGIN
  IF d < 10 THEN
    RETURN CHR(ORD('0') + d)
  ELSE
    RETURN CHR(ORD('A') + (d - 10))
  END
END Digit;

(* Format `n` in `base` into a buffer (most-significant digit first), pad with
   leading spaces to field width `w`, then write it. *)
PROCEDURE WriteRadix (n: CARDINAL; base: CARDINAL; w: CARDINAL);
VAR
  buf: ARRAY [0..63] OF CHAR;
  len, i: CARDINAL;
BEGIN
  len := 0;
  REPEAT
    buf[len] := Digit(n MOD base);
    n := n DIV base;
    INC(len)
  UNTIL n = 0;
  WHILE w > len DO
    STextIO.WriteChar(' ');
    DEC(w)
  END;
  i := len;
  REPEAT
    DEC(i);
    STextIO.WriteChar(buf[i])
  UNTIL i = 0
END WriteRadix;

PROCEDURE WriteOct (n: CARDINAL; w: CARDINAL);
BEGIN
  WriteRadix(n, 8, w)
END WriteOct;

PROCEDURE WriteHex (n: CARDINAL; w: CARDINAL);
BEGIN
  WriteRadix(n, 16, w)
END WriteHex;

(* --- input ------------------------------------------------------------ *)

PROCEDURE Read (VAR ch: CHAR);
BEGIN
  STextIO.ReadChar(ch);
  termCH := ch;
  Done := TRUE
END Read;

PROCEDURE ReadString (VAR s: ARRAY OF CHAR);
BEGIN
  STextIO.ReadString(s);
  Done := TRUE
END ReadString;

PROCEDURE ReadInt (VAR n: INTEGER);
BEGIN
  SWholeIO.ReadInt(n);
  Done := TRUE
END ReadInt;

PROCEDURE ReadCard (VAR n: CARDINAL);
BEGIN
  SWholeIO.ReadCard(n);
  Done := TRUE
END ReadCard;

BEGIN
  Done := TRUE;
  termCH := CHR(0)
END InOut.
