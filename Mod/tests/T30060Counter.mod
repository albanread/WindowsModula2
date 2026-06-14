IMPLEMENTATION MODULE T30060Counter;
VAR n: CARDINAL;
PROCEDURE Get(): CARDINAL;
BEGIN
  RETURN n;
END Get;
BEGIN
  (* module initialization body: must run before the importer's body *)
  n := 100;
END T30060Counter.
