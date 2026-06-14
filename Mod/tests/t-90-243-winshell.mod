MODULE T90243WinShell;
(*
 * Group 90 — GUI shell foundation: WinShell. A Win32 window whose window
 * procedure is an M2 procedure used as a native C-ABI callback, dispatching to
 * an M2 message handler. Proven headlessly with a message-only window:
 * SendMessageW dispatches synchronously into the handler, so we can drive and
 * observe the callback path with no visible UI and no blocking message loop.
 * This is the bedrock under the Direct2D/DirectWrite Terminal and the wider
 * GUI shell.
 *
 * EXPECTED:
 * created: Y
 * result: 42
 * count: 1
 * wparam: 21
 * count2: 2
 * destroyed: Y
 *)
FROM WinShell IMPORT Window, CreateMessageWindow, Send, Destroy;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

CONST WM_USER = 1024;

VAR gCount, gLastW: CARDINAL;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
BEGIN
  IF msg = WM_USER + 1 THEN
    INC(gCount); gLastW := wParam; handled := TRUE; RETURN wParam * 2
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR w: Window; r: CARDINAL;
BEGIN
  gCount := 0; gLastW := 0;
  w := CreateMessageWindow(Handler);
  WriteString("created: "); IF w # NIL THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;
  r := Send(w, WM_USER + 1, 21, 0);
  WriteString("result: "); WriteCard(r, 1); WriteLn;
  WriteString("count: "); WriteCard(gCount, 1); WriteLn;
  WriteString("wparam: "); WriteCard(gLastW, 1); WriteLn;
  r := Send(w, WM_USER + 1, 5, 0);
  WriteString("count2: "); WriteCard(gCount, 1); WriteLn;
  Destroy(w);
  WriteString("destroyed: "); IF w = NIL THEN WriteString("Y") ELSE WriteString("N") END; WriteLn
END T90243WinShell.
