MODULE t90110;
(* COM *server* proof. The consuming direction (t90080) showed an M2
   class can call a real OS COM object because the class object layout
   { vtable, fields } and virtual dispatch ARE the COM ABI. This is the reverse:
   an M2 class IMPLEMENTS IUnknown (+ a custom Bump slot), and an external COM
   client — NM2RT.ComDrive, written in the runtime — loads the vtable from the
   object pointer and calls the slots with the object as `this`, exactly as any
   COM client would. So an M2 object IS a callable COM interface.

   QueryInterface here is permissive (S_OK + AddRef, ignoring riid/ppv) — the
   proof is that ref counting and dispatch survive an external client driving
   the vtable; IID-checking QI is a refinement. *)
IMPORT STextIO, SWholeIO, NM2RT;
FROM SYSTEM IMPORT ADDRESS;

CLASS Counter;          (* a COM coclass: IUnknown + Bump *)
  VAR refs  : INTEGER;
  VAR value : INTEGER;

  PROCEDURE QueryInterface(riid: ADDRESS; ppv: ADDRESS): INTEGER;  (* slot 0 *)
  BEGIN
    refs := refs + 1;           (* AddRef on successful QI *)
    RETURN 0                    (* S_OK *)
  END QueryInterface;

  PROCEDURE AddRef(): INTEGER;                                     (* slot 1 *)
  BEGIN
    refs := refs + 1;
    RETURN refs
  END AddRef;

  PROCEDURE Release(): INTEGER;                                    (* slot 2 *)
  BEGIN
    refs := refs - 1;
    RETURN refs
  END Release;

  PROCEDURE Bump(d: INTEGER): INTEGER;                            (* slot 3 *)
  BEGIN
    value := value + d;
    RETURN value
  END Bump;
END Counter;

VAR c : Counter; witness : INTEGER;

BEGIN
  NEW(c);
  c.refs := 1; c.value := 0;
  witness := NM2RT.ComDrive(c, 41);   (* external COM client drives the vtable *)
  SWholeIO.WriteInt(witness, 0); STextIO.WriteLn;   (* 1201: QI ok, AddRef->2, Release->1 *)
  SWholeIO.WriteInt(c.refs, 0); STextIO.WriteLn;    (* 1: balanced ref count *)
  SWholeIO.WriteInt(c.value, 0); STextIO.WriteLn;   (* 41: Bump mutated via COM call *)
  DISPOSE(c)
END t90110.
