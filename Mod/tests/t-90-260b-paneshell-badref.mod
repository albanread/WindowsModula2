MODULE T90260BPaneShellBadRef;
(*
 * Group 90 — PaneShell Sprint 0 negative scaffolding test. The zero-config
 * discovery story hinges on real file presence (the def/mod suffix +
 * basename==module-name rules), not on any per-family magic: importing a
 * module that does NOT exist in the UI family must FAIL to resolve through the
 * loader's search path. Proving auto-discovery by a deliberate mis-step as well
 * as the happy path (t-90-260).
 *
 * EXPECTED: a loader resolution error containing "not found in search path".
 *)
IMPORT UiPhantom;                  (* no such module exists in library/uidef *)
FROM StrIO IMPORT WriteString, WriteLn;

BEGIN
  WriteString("should-not-link"); WriteLn
END T90260BPaneShellBadRef.
