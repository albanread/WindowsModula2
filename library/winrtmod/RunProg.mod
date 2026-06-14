IMPLEMENTATION MODULE RunProg;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST, SIZE;
FROM System_Threading IMPORT
  STARTUPINFOW, PROCESS_INFORMATION, CreateProcessW, WaitForSingleObject,
  GetExitCodeProcess, TerminateProcess,
  CREATE_NEW_PROCESS_GROUP, NORMAL_PRIORITY_CLASS, IDLE_PRIORITY_CLASS,
  HIGH_PRIORITY_CLASS, DETACHED_PROCESS, STARTF_USESHOWWINDOW, INFINITE;
FROM Foundation IMPORT CloseHandle, GetLastError, STILL_ACTIVE;
FROM UI_WindowsAndMessaging IMPORT
  SW_HIDE, SW_SHOWMINNOACTIVE, SW_SHOWMAXIMIZED, SW_SHOWDEFAULT;
FROM WIN32 IMPORT DWORD, BOOL, WORD;
FROM MemUtils IMPORT ZeroMem;
FROM Environment IMPORT GetVar;

TYPE
  PExecRec = POINTER TO ExecRec;
  ExecRec  = RECORD info: PROCESS_INFORMATION END;

(* ---- small string builders (NUL-terminated, bounded) ---- *)
PROCEDURE PutC (VAR dst: ARRAY OF CHAR; VAR j: CARDINAL; c: CHAR);
BEGIN
  IF j < HIGH(dst) THEN dst[j] := c; INC(j) END
END PutC;

PROCEDURE CopyZ (VAR dst: ARRAY OF CHAR; VAR j: CARDINAL; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (j < HIGH(dst)) DO
    dst[j] := src[i]; INC(i); INC(j)
  END
END CopyZ;

(* The shared launch helper. Builds the quoted command line `"name" command`,
   fills STARTUPINFOW (show-state) and the creation flags (priority + group +
   detached), then CreateProcessW. *)
PROCEDURE DoIt (name, command, defaultPath: ARRAY OF CHAR;
                flags: ExecFlagSet; VAR info: PROCESS_INFORMATION): BOOL;
  VAR si: STARTUPINFOW; cmd, dir: ARRAY [0..1023] OF CHAR;
      cflags: DWORD; j: CARDINAL; dirPtr: ADDRESS;
BEGIN
  j := 0;
  PutC(cmd, j, '"'); CopyZ(cmd, j, name); PutC(cmd, j, '"'); PutC(cmd, j, ' ');
  CopyZ(cmd, j, command); cmd[j] := 0C;

  j := 0; CopyZ(dir, j, defaultPath); dir[j] := 0C;
  IF dir[0] = 0C THEN dirPtr := NIL ELSE dirPtr := ADR(dir) END;

  ZeroMem(ADR(si), SIZE(si));
  si.cb := VAL(DWORD, SIZE(si));
  si.dwFlags := STARTF_USESHOWWINDOW;
  si.wShowWindow := VAL(WORD, SW_SHOWDEFAULT);
  IF ExecMinimized IN flags THEN si.wShowWindow := VAL(WORD, SW_SHOWMINNOACTIVE)
  ELSIF ExecMaximized IN flags THEN si.wShowWindow := VAL(WORD, SW_SHOWMAXIMIZED)
  ELSIF ExecHidden IN flags THEN si.wShowWindow := VAL(WORD, SW_HIDE)
  END;

  cflags := CREATE_NEW_PROCESS_GROUP;
  IF ExecHighPriority IN flags THEN cflags := cflags BOR HIGH_PRIORITY_CLASS
  ELSIF ExecIdlePriority IN flags THEN cflags := cflags BOR IDLE_PRIORITY_CLASS
  ELSE cflags := cflags BOR NORMAL_PRIORITY_CLASS
  END;
  IF ExecDetached IN flags THEN cflags := cflags BOR DETACHED_PROCESS END;

  info.hProcess := NIL;
  RETURN CreateProcessW(NIL, ADR(cmd), NIL, NIL, VAL(BOOL, 1), cflags,
                        NIL, dirPtr, ADR(si), ADR(info))
END DoIt;

PROCEDURE RunProgram (name, command, defaultPath: ARRAY OF CHAR;
                      flags: ExecFlagSet; VAR status: CARDINAL): BOOLEAN;
  VAR info: PROCESS_INFORMATION; ok: BOOL; code, wr: DWORD;
BEGIN
  ok := DoIt(name, command, defaultPath, flags, info);
  IF ok = 0 THEN
    status := VAL(CARDINAL, GetLastError());
    RETURN FALSE
  END;
  IF NOT (ExecAsync IN flags) THEN
    wr := WaitForSingleObject(info.hProcess, INFINITE)
  END;
  code := 0;
  ok := GetExitCodeProcess(info.hProcess, ADR(code));
  status := VAL(CARDINAL, code);
  ok := CloseHandle(info.hThread);
  ok := CloseHandle(info.hProcess);
  RETURN TRUE
END RunProgram;

PROCEDURE RunProgramEx (name, command, defaultPath: ARRAY OF CHAR;
                        flags: ExecFlagSet; VAR handle: ExecHandle): BOOLEAN;
  VAR info: PROCESS_INFORMATION; ok: BOOL; p: PExecRec;
BEGIN
  handle := NIL;
  IF NOT (ExecAsync IN flags) THEN RETURN FALSE END;
  ok := DoIt(name, command, defaultPath, flags, info);
  IF ok = 0 THEN RETURN FALSE END;
  NEW(p);
  p^.info := info;
  handle := CAST(ExecHandle, p);
  RETURN TRUE
END RunProgramEx;

PROCEDURE GetProgramExitStatus (handle: ExecHandle): CARDINAL;
  VAR p: PExecRec; code: DWORD; ok: BOOL;
BEGIN
  IF handle = NIL THEN RETURN MAX(CARDINAL) END;
  p := CAST(PExecRec, handle);
  code := 0;
  ok := GetExitCodeProcess(p^.info.hProcess, ADR(code));
  IF code = STILL_ACTIVE THEN RETURN MAX(CARDINAL) END;
  RETURN VAL(CARDINAL, code)
END GetProgramExitStatus;

PROCEDURE TerminateProgram (VAR handle: ExecHandle);
  VAR p: PExecRec; ok: BOOL;
BEGIN
  IF handle = NIL THEN RETURN END;
  p := CAST(PExecRec, handle);
  IF GetProgramExitStatus(handle) = MAX(CARDINAL) THEN
    ok := TerminateProcess(p^.info.hProcess, 0)
  END;
  ok := CloseHandle(p^.info.hThread);
  ok := CloseHandle(p^.info.hProcess);
  DISPOSE(p);
  handle := NIL
END TerminateProgram;

PROCEDURE PerformCommand (com: ARRAY OF CHAR; flags: ExecFlagSet;
                          VAR status: CARDINAL): BOOLEAN;
  VAR comspec: ARRAY [0..259] OF CHAR; cmd: ARRAY [0..1023] OF CHAR; j: CARDINAL;
BEGIN
  IF NOT GetVar("COMSPEC", comspec) THEN
    comspec := "cmd.exe"
  END;
  j := 0; CopyZ(cmd, j, "/C "); CopyZ(cmd, j, com); cmd[j] := 0C;
  RETURN RunProgram(comspec, cmd, "", flags, status)
END PerformCommand;

END RunProg.
