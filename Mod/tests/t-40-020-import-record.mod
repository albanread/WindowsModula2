MODULE T40020ImportRecord;
(*
 * Group 40 — Records through imported helpers
 * Test: an imported helper can allocate and use a record internally, then
 * expose the observed field values through ordinary imported procedure calls.
 *
 * EXPECTED:
 * 8
 * 13
 * Q
 * 21
 *)
IMPORT STextIO, SWholeIO;
FROM T40020RecordHelper IMPORT WriteRecordValues;

BEGIN
  WriteRecordValues(8, 13, 'Q');
END T40020ImportRecord.