IMPLEMENTATION MODULE Guid;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM System_Com IMPORT CLSIDFromString, CLSIDFromProgID, StringFromGUID2;

TYPE BytePtr = POINTER TO ARRAY [0 .. Bytes - 1] OF BYTE;

PROCEDURE FromString (s: ARRAY OF CHAR; VAR guid: ARRAY OF BYTE): BOOLEAN;
BEGIN
  RETURN CLSIDFromString(ADR(s), ADR(guid)) >= 0   (* S_OK = 0 *)
END FromString;

PROCEDURE FromProgID (progid: ARRAY OF CHAR; VAR clsid: ARRAY OF BYTE): BOOLEAN;
BEGIN
  RETURN CLSIDFromProgID(ADR(progid), ADR(clsid)) >= 0
END FromProgID;

PROCEDURE ToString (guid: ARRAY OF BYTE; VAR s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  (* StringFromGUID2(rguid, lpsz, cchMax): the def-pack parameter names are
     scrambled but the C order is (guid, out-buffer, capacity). Returns the
     char count written (incl. NUL), 0 if the buffer is too small. *)
  RETURN StringFromGUID2(ADR(guid), ADR(s), VAL(INTEGER32, HIGH(s) + 1)) > 0
END ToString;

PROCEDURE Equal (a, b: ADDRESS): BOOLEAN;
  VAR pa, pb: BytePtr; i: CARDINAL;
BEGIN
  pa := CAST(BytePtr, a); pb := CAST(BytePtr, b);
  FOR i := 0 TO Bytes - 1 DO
    IF pa^[i] # pb^[i] THEN RETURN FALSE END
  END;
  RETURN TRUE
END Equal;

END Guid.
