IMPLEMENTATION MODULE Com;

FROM SYSTEM IMPORT ADDRESS, ADR;
FROM System_Com IMPORT
  CoInitializeEx, CoUninitialize, CoGetMalloc, CoCreateInstance, CoTaskMemFree;
FROM WIN32 IMPORT DWORD;

CONST
  COINIT_APARTMENTTHREADED = 2;
  CLSCTX_INPROC_SERVER     = 1;
  MEMCTX_TASK              = 1;

PROCEDURE Initialize (): BOOLEAN;
  VAR hr: INTEGER;
BEGIN
  hr := CoInitializeEx(NIL, COINIT_APARTMENTTHREADED);
  RETURN hr >= 0   (* SUCCEEDED: S_OK (0) or S_FALSE (1, already initialized) *)
END Initialize;

PROCEDURE Uninitialize ();
BEGIN
  CoUninitialize()
END Uninitialize;

PROCEDURE GetMalloc (VAR malloc: ADDRESS): BOOLEAN;
  VAR hr: INTEGER;
BEGIN
  malloc := NIL;
  hr := CoGetMalloc(MEMCTX_TASK, ADR(malloc));
  RETURN (hr >= 0) AND (malloc # NIL)
END GetMalloc;

PROCEDURE CreateInstance (clsid, iid: ADDRESS; VAR obj: ADDRESS): BOOLEAN;
  VAR hr: INTEGER;
BEGIN
  obj := NIL;
  hr := CoCreateInstance(clsid, NIL, CLSCTX_INPROC_SERVER, iid, ADR(obj));
  RETURN (hr >= 0) AND (obj # NIL)
END CreateInstance;

PROCEDURE TaskFree (p: ADDRESS);
BEGIN
  CoTaskMemFree(p)
END TaskFree;

END Com.
