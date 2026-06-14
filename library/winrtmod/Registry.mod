IMPLEMENTATION MODULE Registry;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM System_Registry IMPORT
  RegCreateKeyExW, RegOpenKeyExW, RegSetValueExW, RegQueryValueExW,
  RegDeleteValueW, RegDeleteKeyW, RegCloseKey;
FROM WIN32 IMPORT DWORD, HKEY;

CONST
  NUL          = CHR(0);
  KEY_READ     = 131097;   (* 0x20019 *)
  KEY_WRITE    = 131078;   (* 0x20006 *)
  REG_SZ       = 1;
  REG_DWORD    = 4;
  HkcuBits     = 80000001H; (* HKEY_CURRENT_USER, unsigned (not sign-extended) *)
  HklmBits     = 80000002H; (* HKEY_LOCAL_MACHINE *)

PROCEDURE Root (hive: Hive): HKEY;
BEGIN
  IF hive = LocalMachine THEN RETURN CAST(HKEY, HklmBits) ELSE RETURN CAST(HKEY, HkcuBits) END
END Root;

PROCEDURE Length (s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # NUL) DO INC(i) END;
  RETURN i
END Length;

PROCEDURE OpenWrite (hive: Hive; VAR subkey: ARRAY OF CHAR; VAR hKey: HKEY): BOOLEAN;
BEGIN
  RETURN RegCreateKeyExW(Root(hive), ADR(subkey), 0, NIL, 0, KEY_WRITE, NIL,
                         ADR(hKey), NIL) = 0
END OpenWrite;

PROCEDURE OpenRead (hive: Hive; VAR subkey: ARRAY OF CHAR; VAR hKey: HKEY): BOOLEAN;
BEGIN
  RETURN RegOpenKeyExW(Root(hive), ADR(subkey), 0, KEY_READ, ADR(hKey)) = 0
END OpenRead;

PROCEDURE Close (hKey: HKEY);
  VAR rc: DWORD;
BEGIN
  rc := RegCloseKey(hKey)
END Close;

PROCEDURE SetString (hive: Hive; subkey, name, value: ARRAY OF CHAR): BOOLEAN;
  VAR hKey: HKEY; rc, bytes: DWORD;
BEGIN
  IF NOT OpenWrite(hive, subkey, hKey) THEN RETURN FALSE END;
  bytes := VAL(DWORD, (Length(value) + 1) * 2);   (* wide chars incl. NUL *)
  rc := RegSetValueExW(hKey, ADR(name), 0, REG_SZ, ADR(value), bytes);
  Close(hKey);
  RETURN rc = 0
END SetString;

PROCEDURE GetString (hive: Hive; subkey, name: ARRAY OF CHAR;
                     VAR value: ARRAY OF CHAR): BOOLEAN;
  VAR hKey: HKEY; rc, cb, regType: DWORD; chars: CARDINAL;
BEGIN
  value[0] := NUL;
  IF NOT OpenRead(hive, subkey, hKey) THEN RETURN FALSE END;
  cb := VAL(DWORD, (HIGH(value) + 1) * 2);
  regType := 0;
  rc := RegQueryValueExW(hKey, ADR(name), NIL, ADR(regType), ADR(value), ADR(cb));
  Close(hKey);
  IF (rc # 0) OR (regType # REG_SZ) THEN value[0] := NUL; RETURN FALSE END;
  (* RegQueryValueExW does not guarantee termination if the stored data lacked
     one; terminate at the reported length, clamped to capacity. *)
  chars := VAL(CARDINAL, cb) DIV 2;
  IF chars > HIGH(value) THEN chars := HIGH(value) END;
  IF (chars = 0) OR (value[chars - 1] # NUL) THEN value[chars] := NUL END;
  RETURN TRUE
END GetString;

PROCEDURE SetCard (hive: Hive; subkey, name: ARRAY OF CHAR; value: CARDINAL): BOOLEAN;
  VAR hKey: HKEY; rc: DWORD; dw: DWORD;
BEGIN
  IF NOT OpenWrite(hive, subkey, hKey) THEN RETURN FALSE END;
  dw := VAL(DWORD, value BAND 0FFFFFFFFH);
  rc := RegSetValueExW(hKey, ADR(name), 0, REG_DWORD, ADR(dw), 4);
  Close(hKey);
  RETURN rc = 0
END SetCard;

PROCEDURE GetCard (hive: Hive; subkey, name: ARRAY OF CHAR;
                   VAR value: CARDINAL): BOOLEAN;
  VAR hKey: HKEY; rc, cb, regType, dw: DWORD;
BEGIN
  value := 0;
  IF NOT OpenRead(hive, subkey, hKey) THEN RETURN FALSE END;
  cb := 4; regType := 0; dw := 0;
  rc := RegQueryValueExW(hKey, ADR(name), NIL, ADR(regType), ADR(dw), ADR(cb));
  Close(hKey);
  IF (rc # 0) OR (regType # REG_DWORD) THEN RETURN FALSE END;
  value := VAL(CARDINAL, dw);
  RETURN TRUE
END GetCard;

PROCEDURE DeleteValue (hive: Hive; subkey, name: ARRAY OF CHAR): BOOLEAN;
  VAR hKey: HKEY; rc: DWORD;
BEGIN
  IF NOT OpenWrite(hive, subkey, hKey) THEN RETURN FALSE END;
  rc := RegDeleteValueW(hKey, ADR(name));
  Close(hKey);
  RETURN rc = 0
END DeleteValue;

PROCEDURE DeleteKey (hive: Hive; subkey: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN RegDeleteKeyW(Root(hive), ADR(subkey)) = 0
END DeleteKey;

END Registry.
