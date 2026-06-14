(* Thin NewM2 implementation of ISO 10514-1 EXCEPTIONS over the NM2RT runtime
   primitives. ExceptionSource is completed here as the runtime source id. *)
IMPLEMENTATION MODULE EXCEPTIONS;

IMPORT NM2RT;

TYPE
  ExceptionSource = NM2RT.ExceptionSource;

PROCEDURE AllocateSource (VAR newSource: ExceptionSource);
BEGIN
  newSource := NM2RT.AllocateExceptionSource();
END AllocateSource;

PROCEDURE RAISE (source: ExceptionSource; number: ExceptionNumber; message: ARRAY OF CHAR);
BEGIN
  NM2RT.Raise(source, number, message);
END RAISE;

PROCEDURE CurrentNumber (source: ExceptionSource): ExceptionNumber;
BEGIN
  RETURN NM2RT.CurrentExceptionNumber();
END CurrentNumber;

PROCEDURE GetMessage (VAR text: ARRAY OF CHAR);
BEGIN
  NM2RT.GetExceptionMessage(text);
END GetMessage;

PROCEDURE IsCurrentSource (source: ExceptionSource): BOOLEAN;
BEGIN
  RETURN NM2RT.IsCurrentExceptionSource(source);
END IsCurrentSource;

PROCEDURE IsExceptionalExecution (): BOOLEAN;
BEGIN
  RETURN NM2RT.IsExceptionalExecution();
END IsExceptionalExecution;

END EXCEPTIONS.
