MODULE t61040;
(* Conformance: Semaphores CondClaim count semantics (single-threaded port). *)
IMPORT STextIO, Semaphores;
VAR s : Semaphores.SEMAPHORE; ok : BOOLEAN;
BEGIN
  Semaphores.Create(s, 2);
  ok := Semaphores.CondClaim(s) AND Semaphores.CondClaim(s) AND (NOT Semaphores.CondClaim(s));
  Semaphores.Release(s); ok := ok AND Semaphores.CondClaim(s);
  Semaphores.Destroy(s);
  IF ok THEN STextIO.WriteString("PASS") ELSE STextIO.WriteString("FAIL") END; STextIO.WriteLn
END t61040.
