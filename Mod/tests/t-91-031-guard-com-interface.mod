MODULE t91031;
(* GUARD / ISMEMBER on a COM INTERFACE: discrimination via QueryInterface on a
   REAL OS COM object — the process task allocator (IMalloc) from CoGetMalloc.
   QI for IMalloc's IID succeeds (it IS an IMalloc); QI for a bogus IID fails. *)
IMPORT STextIO, NM2RT;
FROM SYSTEM IMPORT ADDRESS;

INTERFACE IMalloc ["00000002-0000-0000-c000-000000000046"];
  ABSTRACT PROCEDURE QueryInterface () : INTEGER;            (* slot 0 *)
  ABSTRACT PROCEDURE AddRef () : INTEGER;                    (* slot 1 *)
  ABSTRACT PROCEDURE Release () : INTEGER;                   (* slot 2 *)
  ABSTRACT PROCEDURE Alloc (cb : CARDINAL) : ADDRESS;        (* slot 3 *)
  ABSTRACT PROCEDURE Realloc (p : ADDRESS; cb : CARDINAL) : ADDRESS;
  ABSTRACT PROCEDURE Free (p : ADDRESS);
END IMalloc;

(* a made-up IID no real interface implements -> QueryInterface returns failure *)
INTERFACE IBogus ["12345678-1234-1234-1234-123456789abc"];
  ABSTRACT PROCEDURE QueryInterface () : INTEGER;
  ABSTRACT PROCEDURE AddRef () : INTEGER;
  ABSTRACT PROCEDURE Release () : INTEGER;
END IBogus;

VAR mem : IMalloc; hr : INTEGER; p : ADDRESS;

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
    (* ISMEMBER via QI-probe: mem IS an IMalloc, mem is NOT an IBogus *)
    YN(ISMEMBER(mem, IMalloc));          (* Y *)
    YN(ISMEMBER(mem, IBogus));           (* N *)
    STextIO.WriteLn;
    (* GUARD: first-match-wins over QI; the IBogus arm fails, IMalloc matches *)
    GUARD mem AS
      b : IBogus  DO STextIO.WriteString("bogus")
    | m : IMalloc DO
        p := m.Alloc(32);                (* call through the narrowed IMalloc *)
        IF p # NIL THEN STextIO.WriteString("alloc-ok")
        ELSE STextIO.WriteString("alloc-fail") END;
        m.Free(p)
    ELSE
      STextIO.WriteString("none")
    END;
    STextIO.WriteLn
  END;
  NM2RT.ComUninit()
END t91031.
