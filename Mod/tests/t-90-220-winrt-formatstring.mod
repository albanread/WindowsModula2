MODULE T90220WinrtFormatString;
(*
 * Group 90 — M2WINRT: FormatString, printf-style formatting with a
 * NON-variadic typed-argument vector (NewM2 can't iterate C varargs). Exercises
 * the %-spec grammar: signed/unsigned/hex/bool/char/string, width with
 * right/left justification and sign-aware zero-padding, %% and escapes, and the
 * "fewer args than specs -> returns FALSE" contract.
 *
 * EXPECTED:
 * int=-42
 * u=7
 * hex=deadbeef HEX=DEADBEEF
 * hi world!
 * [    5][5    ][-0042]
 * ch=Q TRUE FALSE
 * 100% done
 * n=1 s=world h=FF
 * missing-arg ok=N out=[a=1 b=]
 *)
FROM FormatString IMPORT FormatArg, Format, ArgCard, ArgInt, ArgHex, ArgBool,
  ArgChar, ArgStr;
FROM StrIO IMPORT WriteString, WriteLn;

VAR dest: ARRAY [0..127] OF CHAR; args: ARRAY [0..7] OF FormatArg;
    name: ARRAY [0..31] OF CHAR; ok: BOOLEAN;

PROCEDURE Line (fmt: ARRAY OF CHAR; n: CARDINAL);
BEGIN
  ok := Format(fmt, dest, args, n); WriteString(dest); WriteLn
END Line;

BEGIN
  name := "world";
  args[0] := ArgInt(-42);                       Line("int=%d", 1);
  args[0] := ArgCard(7);                        Line("u=%u", 1);
  args[0] := ArgHex(3735928559); args[1] := ArgHex(3735928559); Line("hex=%x HEX=%X", 2);
  args[0] := ArgStr(name);                      Line("hi %s!", 1);
  args[0] := ArgInt(5); args[1] := ArgInt(5); args[2] := ArgInt(-42); Line("[%5d][%-5d][%05d]", 3);
  args[0] := ArgChar('Q'); args[1] := ArgBool(TRUE); args[2] := ArgBool(FALSE); Line("ch=%c %b %b", 3);
  Line("100%% done", 0);
  args[0] := ArgInt(1); args[1] := ArgStr(name); args[2] := ArgHex(255); Line("n=%d s=%s h=%X", 3);
  (* fewer args than specs -> FALSE, partial output *)
  args[0] := ArgInt(1);
  ok := Format("a=%d b=%d", dest, args, 1);
  WriteString("missing-arg ok=");
  IF ok THEN WriteString("Y") ELSE WriteString("N") END;
  WriteString(" out=["); WriteString(dest); WriteString("]"); WriteLn
END T90220WinrtFormatString.
