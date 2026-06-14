MODULE T90196StorageAvailable;
(*
 * Group 90 — Storage
 * Test: Storage.Available probes the heap — a small request is available,
 *       and a zero-size request is trivially available.
 *
 * EXPECTED:
 * yes
 * yes
 *)
FROM Storage IMPORT Available;
FROM StrIO IMPORT WriteString, WriteLn;

PROCEDURE report (b: BOOLEAN);
BEGIN
  IF b THEN WriteString("yes") ELSE WriteString("no") END;
  WriteLn
END report;

BEGIN
  report(Available(100));
  report(Available(0))
END T90196StorageAvailable.
