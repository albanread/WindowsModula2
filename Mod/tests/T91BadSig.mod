IMPLEMENTATION MODULE T91BadSig;

(* Signature disagrees with the DEFINITION (CARDINAL vs CHAR) -> must reject. *)
PROCEDURE foo (c: CARDINAL);
BEGIN
END foo;

END T91BadSig.
