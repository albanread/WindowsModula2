MODULE T90248InterfaceDispatch;
(*
 * Group 90 — COM INTERFACE: a vtable-only class whose slot ordinals the compiler
 * assigns by walking the INHERIT chain (see docs/design/com-interfaces.md). We
 * build a synthetic COM object (a record whose field 0 points to a
 * function-pointer vtable) and dispatch through interface-typed variables. The
 * printed results prove each method landed on the compiler-computed slot:
 * IUnknown occupies 0/1/2, then derived methods are appended in declaration
 * order across the chain (DoThing=3, Extra=4, Compute=5). No hand-counted
 * placeholders, no +N-shift to get wrong.
 *
 * EXPECTED:
 * 50
 * 107
 *)
FROM SYSTEM IMPORT ADDRESS, ADR, CAST;
IMPORT STextIO, SWholeIO;

INTERFACE IUnknown ["00000000-0000-0000-c000-000000000046"];
  PROCEDURE QueryInterface (riid, ppv: ADDRESS): INTEGER <* @0 *>;
  PROCEDURE AddRef (): INTEGER <* @1 *>;
  PROCEDURE Release (): INTEGER <* @2 *>;
END IUnknown;

INTERFACE IFoo;
  INHERIT IUnknown;
  PROCEDURE DoThing (x: INTEGER): INTEGER <* @3 *>;          (* @N is machine-checked *)
END IFoo;

INTERFACE IBar;
  INHERIT IFoo;
  PROCEDURE Extra (): INTEGER <* @4 *>;
  PROCEDURE Compute (x: INTEGER): INTEGER <* @5 *>;
END IBar;

PROCEDURE Stub (self: ADDRESS): INTEGER;
BEGIN RETURN 0 END Stub;
PROCEDURE MyDoThing (self: ADDRESS; x: INTEGER): INTEGER;
BEGIN RETURN x * 10 END MyDoThing;
PROCEDURE MyCompute (self: ADDRESS; x: INTEGER): INTEGER;
BEGIN RETURN x + 100 END MyCompute;

VAR
  vt:  ARRAY [0..5] OF ADDRESS;
  obj: RECORD vptr: ADDRESS END;
  foo: IFoo;
  bar: IBar;
  r:   INTEGER;
BEGIN
  vt[0] := CAST(ADDRESS, Stub);
  vt[1] := CAST(ADDRESS, Stub);
  vt[2] := CAST(ADDRESS, Stub);
  vt[3] := CAST(ADDRESS, MyDoThing);
  vt[4] := CAST(ADDRESS, Stub);
  vt[5] := CAST(ADDRESS, MyCompute);
  obj.vptr := ADR(vt);

  foo := ADR(obj);                 (* ADDRESS -> INTERFACE, the consumer mechanic *)
  r := foo.DoThing(5);             (* slot 3: MyDoThing(obj,5) = 50 *)
  SWholeIO.WriteInt(r, 0); STextIO.WriteLn;

  bar := ADR(obj);
  r := bar.Compute(7);             (* slot 5, three levels deep: MyCompute(obj,7) = 107 *)
  SWholeIO.WriteInt(r, 0); STextIO.WriteLn;
END T90248InterfaceDispatch.
