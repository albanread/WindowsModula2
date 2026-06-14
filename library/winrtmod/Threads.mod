IMPLEMENTATION MODULE Threads;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
FROM System_Threading IMPORT
  InitializeCriticalSection, EnterCriticalSection, LeaveCriticalSection,
  DeleteCriticalSection, CreateThread, WaitForSingleObject;
FROM Foundation IMPORT CloseHandle;
FROM WIN32 IMPORT DWORD, BOOL, HANDLE;

CONST WAIT_OBJECT_0 = 0;

PROCEDURE InitLock (VAR l: Lock);
BEGIN InitializeCriticalSection(ADR(l)) END InitLock;

PROCEDURE Acquire (VAR l: Lock);
BEGIN EnterCriticalSection(ADR(l)) END Acquire;

PROCEDURE Release (VAR l: Lock);
BEGIN LeaveCriticalSection(ADR(l)) END Release;

PROCEDURE DestroyLock (VAR l: Lock);
BEGIN DeleteCriticalSection(ADR(l)) END DestroyLock;

PROCEDURE Spawn (proc: ThreadProc; param: ADDRESS): Thread;
  VAR tid: DWORD;
BEGIN
  (* lpThreadAttributes=NIL, dwStackSize=0 (default), the proc as the start
     address, param, no creation flags, out thread id. *)
  RETURN CreateThread(NIL, 0, CAST(ADDRESS, proc), param, 0, ADR(tid))
END Spawn;

PROCEDURE Join (t: Thread; timeoutMs: CARDINAL): BOOLEAN;
  VAR r: DWORD;
BEGIN
  r := WaitForSingleObject(t, VAL(DWORD, timeoutMs));
  RETURN r = WAIT_OBJECT_0
END Join;

PROCEDURE CloseThread (t: Thread);
  VAR ok: BOOL;
BEGIN
  ok := CloseHandle(t)
END CloseThread;

END Threads.
