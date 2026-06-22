MODULE t90277;
(* SYSTEM.CAST where one operand is an aggregate (RECORD / closed ARRAY) is a
   memory reinterpret — regression test for the "undefined ValueId" / StructValue
   codegen panics. Covers scalar<->record, record<->ADDRESS, scalar<->array. *)
FROM SYSTEM IMPORT ADDRESS, CAST;
FROM STextIO IMPORT WriteString, WriteLn;
FROM SWholeIO IMPORT WriteInt;
TYPE Handle = RECORD Value: ADDRESS END;
     MinStr = ARRAY [0..0] OF CHAR;
VAR h: Handle; a, a2: ADDRESS; n: CARDINAL; s: MinStr; c: CHAR;
BEGIN
  a  := CAST(ADDRESS, 12345);
  h  := CAST(Handle, a);            (* scalar/ptr -> RECORD *)
  a2 := CAST(ADDRESS, h);           (* RECORD -> ptr *)
  n  := CAST(CARDINAL, a2);
  WriteInt(VAL(INTEGER, n), 0); WriteLn;     (* 12345 *)
  s  := CAST(MinStr, 'A');          (* scalar -> ARRAY *)
  c  := CAST(CHAR, s);              (* ARRAY -> scalar *)
  WriteInt(VAL(INTEGER, ORD(c)), 0); WriteLn (* 65 *)
END t90277.
