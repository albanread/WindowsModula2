MODULE T90208WinrtCrc;
(*
 * Group 90 — M2WINRT runtime library: GenCRC (reflected CRC-32, zip/gzip/PNG).
 * Known-answer vector: CRC-32("123456789") = 0CBF43926H = 3421780262. Both the
 * one-shot GenCRC and the incremental CrcByte/CrcPostcondition path must agree
 * bit-for-bit. Exercises the module-init table build, BXOR/SHR/BAND, hex
 * literals, 32-bit-in-64-bit masking, and raw byte access via SYSTEM.
 *
 * EXPECTED:
 * 3421780262
 * 3421780262
 *)
FROM SYSTEM IMPORT ADR;
FROM GenCRC IMPORT GenCRC, CrcByte, CrcPostcondition, CrcPrecondition, Crc32;
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteLn;

VAR
  data : ARRAY [0..8] OF BYTE;
  i    : CARDINAL;
  crc  : Crc32;
BEGIN
  FOR i := 0 TO 8 DO
    data[i] := VAL(BYTE, 49 + i)            (* '1'..'9' = codes 49..57 *)
  END;
  crc := GenCRC(ADR(data), 9);
  WriteCard(crc, 1); WriteLn;               (* one-shot *)
  crc := CrcPrecondition;
  FOR i := 0 TO 8 DO
    crc := CrcByte(data[i], crc)
  END;
  crc := CrcPostcondition(crc);
  WriteCard(crc, 1); WriteLn                (* incremental — same value *)
END T90208WinrtCrc.
