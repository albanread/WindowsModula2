MODULE T90274bCloseReentrancy;
(*
 * Group 90 — PaneShell S12 slice 2b hardening (post adversarial review). CloseWindow
 * raises EvWindowClosed before teardown; a handler that re-closes the SAME window from
 * inside that notification (the natural close-on-notified pattern) must be a safe
 * no-op, not a double-free / use-after-free. The fix: a `closing` re-entrancy guard +
 * detaching the handle and unregistering BEFORE notifying. Here the handler closes via
 * a SEPARATE alias (gwCopy) still holding the live pointer, so only the `closing` guard
 * can save it.
 *
 * EXPECTED:
 * closed-evt: Y
 * reentry-safe: Y
 * wins: 0
 *)
FROM Surface IMPORT NewRaster;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvWindowClosed,
  LeafPane, Init, OpenWindow, CloseWindow, WindowCount;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

VAR ws: Workspace; gw, gwCopy: PaneWindow; sawClosed, reentrySafe: BOOLEAN;

PROCEDURE On (VAR e: Event): BOOLEAN;
BEGIN
  IF e.kind = EvWindowClosed THEN
    sawClosed := TRUE;
    CloseWindow(gwCopy);          (* re-close the SAME window from its own close notice -> must no-op *)
    reentrySafe := TRUE           (* reached here => the re-entrant close did not corrupt/crash *)
  END;
  RETURN FALSE
END On;

PROCEDURE YN (b: BOOLEAN);
BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END; WriteLn END YN;

BEGIN
  sawClosed := FALSE; reentrySafe := FALSE;
  ws := Init();
  gw := OpenWindow(ws, "x", 200, 200, LeafPane("x", NewRaster(8, 8)), On);
  gwCopy := gw;                   (* a second alias holding the live pointer *)
  CloseWindow(gw);                (* -> EvWindowClosed -> handler re-closes via gwCopy *)
  WriteString("closed-evt: ");   YN(sawClosed);
  WriteString("reentry-safe: ");  YN(reentrySafe);
  WriteString("wins: ");          WriteCard(WindowCount(ws), 1); WriteLn
END T90274bCloseReentrancy.
