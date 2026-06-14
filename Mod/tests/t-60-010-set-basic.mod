MODULE T60010SetBasic;
(*
 * Group 60 — SET (256-bit). SET OF CHAR over the full 0..255 range with
 * range and singleton constructors and IN membership — the parser use case.
 *
 * EXPECTED:
 * 1
 * 0
 * 1
 * 1
 * 1
 * 0
 *)
IMPORT STextIO, SWholeIO;

TYPE CharSet = SET OF CHAR;

VAR digits, vowels : CharSet;

PROCEDURE Yes(b : BOOLEAN);
BEGIN
  IF b THEN SWholeIO.WriteInt(1, 0) ELSE SWholeIO.WriteInt(0, 0) END;
  STextIO.WriteLn
END Yes;

BEGIN
  digits := CharSet{'0'..'9'};
  vowels := CharSet{'a', 'e', 'i', 'o', 'u'};
  Yes('5' IN digits);   (* 1 *)
  Yes('A' IN digits);   (* 0 *)
  Yes('9' IN digits);   (* 1 *)
  Yes('e' IN vowels);   (* 1 *)
  Yes('a' IN vowels);   (* 1 *)
  Yes('b' IN vowels);   (* 0 *)
END T60010SetBasic.
