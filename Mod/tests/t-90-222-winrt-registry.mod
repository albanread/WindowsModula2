MODULE T90222WinrtRegistry;
(*
 * Group 90 — M2WINRT: Registry, a typed wrapper over the advapi32
 * registry W-APIs called DIRECTLY from M2. Round-trips a string and a DWORD
 * value through a HKCU\Software\M2WINRT_Test subkey, then deletes the value and
 * the key (self-cleaning, per-user, needs no elevation — the P3 HKCU-default
 * security rule). Exercises POINTER TO HKEY out-params and ARRAY OF CHAR as the
 * wide value buffer.
 *
 * EXPECTED:
 * setstr Y
 * getstr Y [hello-registry]
 * setcard Y
 * getcard Y 12345
 * delval Y
 * getstr-after-del N
 * delkey Y
 *)
FROM Registry IMPORT Hive, CurrentUser, SetString, GetString, SetCard, GetCard,
  DeleteValue, DeleteKey;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

CONST Sub = "Software\M2WINRT_Test";
VAR s: ARRAY [0..255] OF CHAR; c: CARDINAL; ok: BOOLEAN;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

BEGIN
  ok := SetString(CurrentUser, Sub, "strval", "hello-registry");
  WriteString("setstr "); YN(ok); WriteLn;
  ok := GetString(CurrentUser, Sub, "strval", s);
  WriteString("getstr "); YN(ok); WriteString(" ["); WriteString(s); WriteString("]"); WriteLn;
  ok := SetCard(CurrentUser, Sub, "numval", 12345);
  WriteString("setcard "); YN(ok); WriteLn;
  ok := GetCard(CurrentUser, Sub, "numval", c);
  WriteString("getcard "); YN(ok); WriteString(" "); WriteCard(c, 1); WriteLn;
  ok := DeleteValue(CurrentUser, Sub, "strval");
  WriteString("delval "); YN(ok); WriteLn;
  ok := GetString(CurrentUser, Sub, "strval", s);
  WriteString("getstr-after-del "); YN(ok); WriteLn;
  ok := DeleteValue(CurrentUser, Sub, "numval");
  ok := DeleteKey(CurrentUser, Sub);
  WriteString("delkey "); YN(ok); WriteLn
END T90222WinrtRegistry.
