MODULE T90202CharIndexedArray;
(*
 * Group 90 — arrays
 * Test: an array indexed by a bare built-in ordinal type (`ARRAY CHAR OF …`)
 *       is sized by that type's full cardinality, so indices across its range
 *       are in bounds and storage is allocated for them. (CHAR is wide here, so
 *       the array has 65536 cells.)
 *
 * EXPECTED:
 * 198
 * yes
 *)
FROM NumberIO IMPORT WriteCard;
FROM StrIO IMPORT WriteString, WriteLn;

VAR
  a: ARRAY CHAR OF CARDINAL;
  ch: CHAR;
BEGIN
  FOR ch := 'A' TO 'C' DO a[ch] := ORD(ch) END;
  WriteCard(a['A'] + a['B'] + a['C'], 0); WriteLn;   (* 65+66+67 = 198 *)
  (* high CHAR index is in bounds (was a 1-element array before the fix) *)
  a[377C] := 1;
  IF a[377C] = 1 THEN WriteString("yes") ELSE WriteString("no") END;
  WriteLn
END T90202CharIndexedArray.
