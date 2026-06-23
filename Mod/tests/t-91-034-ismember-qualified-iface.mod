MODULE t91034;
(* GUARD / ISMEMBER with a QUALIFIED interface name (T91MallocLib.IMalloc) — the
   realistic shape, since COM interfaces are imported from a module. Regression
   for the sema/lowering qualified-name classification fix. *)
IMPORT STextIO, NM2RT, T91MallocLib;
FROM SYSTEM IMPORT ADDRESS;

VAR mem : T91MallocLib.IMalloc; hr : INTEGER; p : ADDRESS;

PROCEDURE YN (b : BOOLEAN);
BEGIN
  IF b THEN STextIO.WriteString("Y") ELSE STextIO.WriteString("N") END
END YN;

BEGIN
  hr := NM2RT.ComInit();
  mem := NM2RT.ComGetMalloc();
  IF mem = EMPTY THEN
    STextIO.WriteString("no-malloc"); STextIO.WriteLn
  ELSE
    YN(ISMEMBER(mem, T91MallocLib.IMalloc));     (* qualified target -> Y *)
    STextIO.WriteLn;
    GUARD mem AS
      m : T91MallocLib.IMalloc DO                 (* qualified arm -> match *)
        p := m.Alloc(16);
        IF p # NIL THEN STextIO.WriteString("ok")
        ELSE STextIO.WriteString("fail") END;
        m.Free(p)
    ELSE
      STextIO.WriteString("none")
    END;
    STextIO.WriteLn
  END;
  NM2RT.ComUninit()
END t91034.
