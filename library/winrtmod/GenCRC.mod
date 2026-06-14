IMPLEMENTATION MODULE GenCRC;

FROM SYSTEM IMPORT ADDRESS, CAST;

CONST
  Magic   = 0EDB88320H;   (* the reflected CRC-32 polynomial *)
  Mask32  = 0FFFFFFFFH;   (* low-32-bit mask (CARDINAL is 64-bit here) *)

TYPE
  BytePtr = POINTER TO ARRAY [0 .. MAX(CARDINAL) - 1] OF BYTE;

VAR
  Table: ARRAY [0 .. 255] OF Crc32;   (* built once at init, read-only after *)

PROCEDURE CrcByte (b: BYTE; crc: Crc32): Crc32;
  VAR idx: CARDINAL;
BEGIN
  idx := (ORD(b) BXOR crc) BAND 0FFH;
  RETURN ((crc SHR 8) BXOR Table[idx]) BAND Mask32
END CrcByte;

PROCEDURE CrcBlock (data: ARRAY OF BYTE; crc: Crc32): Crc32;
  VAR i: CARDINAL;
BEGIN
  FOR i := 0 TO HIGH(data) DO
    crc := CrcByte(data[i], crc)
  END;
  RETURN crc
END CrcBlock;

PROCEDURE CrcBytes (data: ADDRESS; numBytes: CARDINAL; crc: Crc32): Crc32;
  VAR p: BytePtr; i: CARDINAL;
BEGIN
  p := CAST(BytePtr, data);
  i := 0;
  WHILE i < numBytes DO
    crc := CrcByte(p^[i], crc);
    INC(i)
  END;
  RETURN crc
END CrcBytes;

PROCEDURE CrcPostcondition (crc: Crc32): Crc32;
BEGIN
  RETURN (crc BXOR Mask32) BAND Mask32
END CrcPostcondition;

PROCEDURE GenCRC (data: ADDRESS; numBytes: CARDINAL): Crc32;
BEGIN
  RETURN CrcPostcondition(CrcBytes(data, numBytes, CrcPrecondition))
END GenCRC;

PROCEDURE InitCrcTable;
  VAR i, j, val: CARDINAL;
BEGIN
  FOR i := 0 TO 255 DO
    val := i;
    FOR j := 1 TO 8 DO
      IF (val BAND 1) # 0 THEN
        val := (val SHR 1) BXOR Magic
      ELSE
        val := val SHR 1
      END
    END;
    Table[i] := val BAND Mask32
  END
END InitCrcTable;

BEGIN
  InitCrcTable
END GenCRC.
