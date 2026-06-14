MODULE T91028InterfaceSlotMismatch;
(*
 * Group 91 — negatives. The @ordinal machine-check (docs/design/com-interfaces.md):
 * a method annotated `<* @N *>` must land on exactly the slot the compiler
 * computes from the INHERIT chain. Here DoThing is the first method after
 * IUnknown (so it is slot 3) but is annotated @5 — the compiler must REJECT it.
 * This is what turns "the generator transcribed the vtable" into "the build fails
 * if a slot is off by one".
 *
 * EXPECT-ERROR: annotated slot @5 but the compiler computed slot 3
 *)
INTERFACE IUnknown;
  PROCEDURE QueryInterface (): INTEGER;
  PROCEDURE AddRef (): INTEGER;
  PROCEDURE Release (): INTEGER;
END IUnknown;

INTERFACE IFoo;
  INHERIT IUnknown;
  PROCEDURE DoThing (): INTEGER <* @5 *>;     (* really slot 3 — must error *)
END IFoo;

BEGIN
END T91028InterfaceSlotMismatch.
