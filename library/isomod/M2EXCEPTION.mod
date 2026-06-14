(* Thin NewM2 implementation of ISO 10514-1 M2EXCEPTION over the NM2RT runtime
   primitives. Language exceptions carry the fixed NM2RT.M2Source() source id;
   their number is the M2Exceptions ordinal. *)
IMPLEMENTATION MODULE M2EXCEPTION;

IMPORT NM2RT;

PROCEDURE M2Exception (): M2Exceptions;
BEGIN
  RETURN VAL(M2Exceptions, NM2RT.CurrentExceptionNumber());
END M2Exception;

PROCEDURE IsM2Exception (): BOOLEAN;
BEGIN
  RETURN NM2RT.IsCurrentExceptionSource(NM2RT.M2Source());
END IsM2Exception;

END M2EXCEPTION.
