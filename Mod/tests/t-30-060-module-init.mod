MODULE T30060ModuleInit;
(*
 * Group 30 — Modules / imports
 * Test: an imported module's initialization body (BEGIN ... END) runs before
 *       the importing module's body.
 *
 * EXPECTED:
 * 100
 *)
IMPORT STextIO, SWholeIO, T30060Counter;
BEGIN
  SWholeIO.WriteCard(T30060Counter.Get(), 0);
  STextIO.WriteLn;
END T30060ModuleInit.
