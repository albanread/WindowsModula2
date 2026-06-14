MODULE T60040WideIO;
(*
 * Group 60 — Windows-wide strings internally, UTF-8 at the I/O boundary.
 * Non-ASCII source characters are stored as UTF-16 (CHAR = i16) and emitted
 * as UTF-8 by the text writers.
 *
 * EXPECTED:
 * café
 * ü
 *)
IMPORT STextIO;
BEGIN
  STextIO.WriteString("café");
  STextIO.WriteLn;
  STextIO.WriteChar('ü');
  STextIO.WriteLn;
END T60040WideIO.
