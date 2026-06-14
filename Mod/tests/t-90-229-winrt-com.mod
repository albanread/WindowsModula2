MODULE T90229WinrtCom;
(*
 * Group 90 — M2WINRT: Com, COM/OLE lifecycle + activation over ole32,
 * called DIRECTLY from M2. Demonstrates the CLASS-as-COM-interface consumption
 * pattern: an ABSTRACT CLASS declares IMalloc's methods in vtable order, the raw
 * interface pointer from CoGetMalloc is assigned to it, and Alloc/Free dispatch
 * straight through the real OS COM object's vtable.
 *
 * EXPECTED:
 * init: Y
 * getmalloc: Y
 * alloc: Y
 * freed
 *)
FROM Com IMPORT Initialize, Uninitialize, GetMalloc;
FROM SYSTEM IMPORT ADDRESS;
FROM StrIO IMPORT WriteString, WriteLn;

ABSTRACT CLASS IMalloc;
  ABSTRACT PROCEDURE QueryInterface() : INTEGER;             (* slot 0 *)
  ABSTRACT PROCEDURE AddRef() : INTEGER;                     (* slot 1 *)
  ABSTRACT PROCEDURE Release() : INTEGER;                    (* slot 2 *)
  ABSTRACT PROCEDURE Alloc(cb : CARDINAL) : ADDRESS;         (* slot 3 *)
  ABSTRACT PROCEDURE Realloc(p : ADDRESS; cb : CARDINAL) : ADDRESS;
  ABSTRACT PROCEDURE Free(p : ADDRESS);
END IMalloc;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR mem: IMalloc; raw, p: ADDRESS; ok: BOOLEAN; refs: INTEGER;
BEGIN
  WriteString("init: "); YN(Initialize()); WriteLn;
  ok := GetMalloc(raw);
  WriteString("getmalloc: "); YN(ok); WriteLn;
  mem := raw;
  p := mem.Alloc(64);
  WriteString("alloc: "); YN(p # NIL); WriteLn;
  mem.Free(p);
  WriteString("freed"); WriteLn;
  refs := mem.Release();
  Uninitialize()
END T90229WinrtCom.
