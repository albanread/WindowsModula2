MODULE Hello;

(* Minimal driver fixture for the Phase 2 module-graph test.
   IMPORTs from IOChan, which itself imports IOConsts, ChanConsts,
   and SYSTEM — yielding a 5-module graph rooted at Hello. *)

FROM IOChan IMPORT ChanId, InvalidChan;

BEGIN
END Hello.
