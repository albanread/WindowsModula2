MODULE T60120Storage;
(* Group 60 — ISO Storage. ALLOCATE/DEALLOCATE + SYSTEM.CAST to a record
   pointer, write/read fields. EXPECTED: 42 *)
IMPORT STextIO, WholeStr, Storage, SYSTEM;
TYPE
  Rec = RECORD a, b: CARDINAL; END;
  P   = POINTER TO Rec;
VAR p: P; addr: SYSTEM.ADDRESS; s: ARRAY [0..31] OF CHAR;
BEGIN
  Storage.ALLOCATE(addr, SYSTEM.TSIZE(Rec));
  p := SYSTEM.CAST(P, addr);
  p^.a := 11;
  p^.b := 31;
  WholeStr.CardToStr(p^.a + p^.b, s);
  STextIO.WriteString(s); STextIO.WriteLn;
  Storage.DEALLOCATE(addr, SYSTEM.TSIZE(Rec));
END T60120Storage.
