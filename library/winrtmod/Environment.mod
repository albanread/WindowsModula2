IMPLEMENTATION MODULE Environment;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM System_Environment IMPORT
  GetEnvironmentVariableW, SetEnvironmentVariableW, GetCommandLineW;
FROM System_LibraryLoader IMPORT GetModuleFileNameW;
FROM WIN32 IMPORT DWORD, BOOL, HMODULE;

CONST NUL = CHR(0);

TYPE StrPtr = POINTER TO ARRAY [0 .. MAX(CARDINAL) - 1] OF CHAR;

PROCEDURE GetVar (name: ARRAY OF CHAR; VAR value: ARRAY OF CHAR): BOOLEAN;
  VAR n: DWORD; cap: CARDINAL;
BEGIN
  cap := HIGH(value) + 1;
  n := GetEnvironmentVariableW(ADR(name), ADR(value), VAL(DWORD, cap));
  (* 0 -> not found; >= cap -> buffer too small (n is required size incl NUL);
     otherwise n chars were copied and NUL-terminated. *)
  IF (n = 0) OR (VAL(CARDINAL, n) >= cap) THEN
    value[0] := NUL;
    RETURN FALSE
  END;
  RETURN TRUE
END GetVar;

PROCEDURE SetVar (name, value: ARRAY OF CHAR): BOOLEAN;
  VAR ok: BOOL;
BEGIN
  ok := SetEnvironmentVariableW(ADR(name), ADR(value));
  RETURN ok # 0
END SetVar;

PROCEDURE RemoveVar (name: ARRAY OF CHAR): BOOLEAN;
  VAR ok: BOOL;
BEGIN
  ok := SetEnvironmentVariableW(ADR(name), NIL);   (* NULL value deletes the var *)
  RETURN ok # 0
END RemoveVar;

PROCEDURE GetExePath (VAR path: ARRAY OF CHAR): BOOLEAN;
  VAR n: DWORD; cap: CARDINAL; nullMod: HMODULE;
BEGIN
  cap := HIGH(path) + 1;
  nullMod := NIL;                                  (* NULL module = the current exe *)
  n := GetModuleFileNameW(nullMod, ADR(path), VAL(DWORD, cap));
  (* On truncation n = cap (and the buffer is filled but not reliably
     terminated); treat that as failure. *)
  IF (n = 0) OR (VAL(CARDINAL, n) >= cap) THEN
    path[0] := NUL;
    RETURN FALSE
  END;
  path[VAL(CARDINAL, n)] := NUL;
  RETURN TRUE
END GetExePath;

PROCEDURE GetCommandLine (VAR cmd: ARRAY OF CHAR);
  VAR p: StrPtr; i, cap: CARDINAL;
BEGIN
  p := CAST(StrPtr, GetCommandLineW());
  cap := HIGH(cmd) + 1; i := 0;
  WHILE (i + 1 < cap) AND (p^[i] # NUL) DO cmd[i] := p^[i]; INC(i) END;
  cmd[i] := NUL
END GetCommandLine;

END Environment.
