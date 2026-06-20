MODULE T90266ControlBackend;
(*
 * Group 90 — PaneShell S6 (P2 part 2/2, closes P2): native controls as the
 * simplest leaf. A control Backend's Attach creates a real Win32 child control
 * (message-window-safe, unlike a D2D target), Paint is a no-op (the OS draws it),
 * KindOf = NativeControl (ord 5). The generic value API SetText/GetText
 * round-trips through the control's HWND. The Kind.Custom (ord 6) extension seam:
 * an app subclasses Surface.Backend directly and slots into the same handle.
 *
 * EXPECTED:
 * btn-kind: 5
 * attach-btn: Y
 * edit-text: hello
 * custom-kind: 6
 *)
FROM SYSTEM IMPORT ADDRESS;
IMPORT Surface;
FROM WinShell IMPORT Window, CreateMessageWindow;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

(* an app-defined custom Backend — the §6 extension seam (no framework constructor) *)
CLASS MyCustom;
  INHERIT Surface.Backend;
  OVERRIDE PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN; BEGIN RETURN TRUE END Attach;
  OVERRIDE PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN; BEGIN RETURN TRUE END Resize;
  OVERRIDE PROCEDURE Paint; BEGIN END Paint;
  OVERRIDE PROCEDURE KindOf (): Surface.Kind; BEGIN RETURN Surface.Custom END KindOf;
  OVERRIDE PROCEDURE Close; BEGIN END Close;
END MyCustom;

PROCEDURE NullHandler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
BEGIN handled := FALSE; RETURN 0 END NullHandler;

VAR bt, ed, cu: Surface.Backend; mc: MyCustom; parent: Window;
    s: ARRAY [0..63] OF CHAR; ok: BOOLEAN;
BEGIN
  parent := CreateMessageWindow(NullHandler);          (* a message-only host window *)

  bt := Surface.NewButton("OK", "ok-click");
  ed := Surface.NewEdit(FALSE);

  WriteString("btn-kind: "); WriteCard(ORD(bt.KindOf()), 1); WriteLn;        (* 5 *)
  ok := bt.Attach(parent, 80, 24);
  WriteString("attach-btn: "); IF ok THEN WriteString("Y") ELSE WriteString("N") END; WriteLn;

  ok := ed.Attach(parent, 120, 24);
  Surface.SetText(ed, "hello");
  Surface.GetText(ed, s);
  WriteString("edit-text: "); WriteString(s); WriteLn;                       (* hello *)

  NEW(mc); cu := mc;
  WriteString("custom-kind: "); WriteCard(ORD(cu.KindOf()), 1); WriteLn;     (* 6 *)

  bt.Close(); ed.Close()
END T90266ControlBackend.
