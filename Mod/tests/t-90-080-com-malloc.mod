MODULE t90080;
(* COM interop: NewM2's class object layout and virtual dispatch are the COM
   ABI, so an M2 class declaring an interface's methods (in IUnknown order) can
   consume a real OS COM object. Here IMalloc (the process task allocator from
   CoGetMalloc) is called through ordinary virtual dispatch. *)
IMPORT STextIO, NM2RT;
FROM SYSTEM IMPORT ADDRESS;

ABSTRACT CLASS IMalloc;
  ABSTRACT PROCEDURE QueryInterface() : INTEGER;             (* slot 0 *)
  ABSTRACT PROCEDURE AddRef() : INTEGER;                     (* slot 1 *)
  ABSTRACT PROCEDURE Release() : INTEGER;                    (* slot 2 *)
  ABSTRACT PROCEDURE Alloc(cb : CARDINAL) : ADDRESS;         (* slot 3 *)
  ABSTRACT PROCEDURE Realloc(p : ADDRESS; cb : CARDINAL) : ADDRESS; (* slot 4 *)
  ABSTRACT PROCEDURE Free(p : ADDRESS);                      (* slot 5 *)
END IMalloc;

VAR mem : IMalloc; p : ADDRESS; hr : INTEGER;

BEGIN
  hr := NM2RT.ComInit();
  mem := NM2RT.ComGetMalloc();           (* real OS IMalloc *)
  IF mem = EMPTY THEN
    STextIO.WriteString("no-malloc"); STextIO.WriteLn
  ELSE
    p := mem.Alloc(64);                  (* virtual dispatch -> OS Alloc *)
    IF p # NIL THEN
      STextIO.WriteString("alloc-ok")
    ELSE
      STextIO.WriteString("alloc-fail")
    END;
    STextIO.WriteLn;
    mem.Free(p);                         (* virtual dispatch -> OS Free *)
    STextIO.WriteString("freed"); STextIO.WriteLn
  END;
  NM2RT.ComUninit()
END t90080.
