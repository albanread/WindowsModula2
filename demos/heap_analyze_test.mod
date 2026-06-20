MODULE HeapAnalyzeTest;
(* Exercises the static `analyze` pass. Expect warnings for LeakIt, DoubleDispose,
   UseAfter; NO warnings for Clean or Escapes (the pointer is handed off). *)
TYPE P = POINTER TO INTEGER;

PROCEDURE LeakIt;          (* leak: NEW, used via ^, never DISPOSE, never escapes *)
  VAR p: P;
BEGIN
  NEW(p);
  p^ := 1
END LeakIt;

PROCEDURE DoubleDispose;
  VAR p: P;
BEGIN
  NEW(p);
  DISPOSE(p);
  DISPOSE(p)               (* double DISPOSE *)
END DoubleDispose;

PROCEDURE UseAfter;
  VAR p: P; x: INTEGER;
BEGIN
  NEW(p);
  DISPOSE(p);
  x := p^                  (* use after DISPOSE *)
END UseAfter;

PROCEDURE Clean;           (* no warnings: balanced *)
  VAR p: P;
BEGIN
  NEW(p);
  p^ := 5;
  DISPOSE(p)
END Clean;

PROCEDURE Escapes (): P;   (* no leak: the pointer is returned (escapes) *)
  VAR p: P;
BEGIN
  NEW(p);
  RETURN p
END Escapes;

BEGIN
END HeapAnalyzeTest.
