MODULE T60130Sem;
(* Group 60 — ISO Semaphores. Create/Claim/CondClaim/Release/Destroy.
   EXPECTED: n / y *)
IMPORT STextIO, Semaphores;
VAR s: Semaphores.SEMAPHORE; ok: BOOLEAN;
PROCEDURE show(b: BOOLEAN);
BEGIN
  IF b THEN STextIO.WriteString("y") ELSE STextIO.WriteString("n") END;
  STextIO.WriteLn;
END show;
BEGIN
  Semaphores.Create(s, 1);
  Semaphores.Claim(s);
  ok := Semaphores.CondClaim(s);
  show(ok);
  Semaphores.Release(s);
  ok := Semaphores.CondClaim(s);
  show(ok);
  Semaphores.Destroy(s);
END T60130Sem.
