MODULE T91021DupImportReject;
(*
 * Group 91 — diagnostics (negative): this module MUST be rejected.
 * WriteString is imported twice from StrIO (duplicate import of the same
 * name in one import list).
 *)
FROM StrIO IMPORT WriteString, WriteLn;
FROM StrIO IMPORT WriteString;
BEGIN
  WriteString("x"); WriteLn
END T91021DupImportReject.
