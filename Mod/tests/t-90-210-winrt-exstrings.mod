MODULE T90210WinrtExStrings;
(*
 * Group 90 — M2WINRT runtime library: ExStrings (extended NUL-terminated
 * string ops). Exercises CHAR-width-neutral open-array string handling, CAP,
 * case-insensitive compare/search, in-place case folding, the appenders, and
 * find/replace with a scratch buffer.
 *
 * EXPECTED:
 * Y
 * N
 * Y
 * Y
 * 6
 * mixedcase
 * MIXEDCASE
 * X42=00FF
 * Y
 * the dog sat
 * 11
 *)
FROM ExStrings IMPORT EqualI, CompareI, CompareResults, FindNextI,
                      Lowercase, Uppercase, AppendChar, AppendNum, AppendHex,
                      FindAndReplaceI, Length;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

PROCEDURE YN (b: BOOLEAN);
BEGIN
  IF b THEN WriteString("Y") ELSE WriteString("N") END;
  WriteLn
END YN;

VAR
  s     : ARRAY [0..63] OF CHAR;
  found : BOOLEAN;
  pos   : CARDINAL;
BEGIN
  YN(EqualI("Hello", "HELLO"));
  YN(EqualI("Hello", "World"));
  YN(CompareI("abc", "ABD") = less);

  FindNextI("WORLD", "hello world here", 0, found, pos);
  YN(found); WriteCard(pos, 1); WriteLn;

  s := "MixedCase";
  Lowercase(s); WriteString(s); WriteLn;
  Uppercase(s); WriteString(s); WriteLn;

  s := "";
  AppendChar('X', s);
  AppendNum(42, s);
  AppendChar('=', s);
  AppendHex(255, 4, s);
  WriteString(s); WriteLn;

  s := "the cat sat";
  found := FindAndReplaceI("CAT", "dog", s);
  YN(found); WriteString(s); WriteLn;
  WriteCard(Length(s), 1); WriteLn
END T90210WinrtExStrings.
