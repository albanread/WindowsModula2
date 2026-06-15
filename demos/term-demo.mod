MODULE TermDemo;
<*GUI*>   (* windowed app: GUI subsystem, no console *)
(*
 * A live TUI terminal, rendered with Direct2D/DirectWrite (no GDI), in pure
 * Modula-2. Shows the whole stack working together:
 *   Terminal  (the cell-grid model — menu bar with drop-down menus, status bar,
 *              a boxed text window with multi-colour text, an editable field,
 *              and a semantic event queue the app responds to)
 *   TermRender (Direct2D HWND render target + DirectWrite monospaced glyphs)
 *   WinShell   (the window + the M2 window-procedure callback + message loop)
 *
 * Run it:   newm2 run demos/term-demo.mod
 * or build: newm2 build demos/term-demo.mod   then run the .exe
 *
 * The controlling app turns Win32 keys into Terminal Key* codes, hands them to
 * HandleKey (the menu bar) or FieldHandleKey (the input field), and then drains
 * the resulting events — so it reacts to "menu item chosen", "field submitted",
 * etc. rather than to raw keystrokes.
 *
 *   Tab            switch focus between the menu bar and the input field
 *   menu focus:    Left/Right pick a menu, Down/Enter open it, Up/Down pick an
 *                  item, Enter choose, Esc close
 *   field focus:   type to edit, Left/Right/Home/End/Del move+edit, Enter submit
 *   File > Quit, or close the window, to exit. View > Toggle Help live-updates
 *   the menu bar (enables/disables the Help menu).
 *)
FROM SYSTEM IMPORT ADDRESS;
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  RunMessageLoop, Quit;
FROM TermRender IMPORT Startup, Attach, Paint;
FROM Terminal IMPORT
  Init, MenuClear, MenuAdd, MenuAddItem, MenuRender, MenuSelect, MenuSelected,
  MenuTitle, MenuItemText, MenuIsOpen, MenuClose, MenuEnable, MenuEnabled,
  HandleKey, NextEvent, Event,
  EvMenuMove, EvMenuOpen, EvMenuClose, EvMenuItem, EvFieldChange, EvSubmit, EvCancel,
  KeyNone, KeyChar, KeyEnter, KeyEsc, KeyTab, KeyBack, KeyDelete,
  KeyLeft, KeyRight, KeyUp, KeyDown, KeyHome, KeyEnd,
  SetStatus, WriteColAt, TextWin, WinOpen, WinClear, WinBox, WinGotoXY, WinWrite,
  Field, FieldInit, FieldRender, FieldHandleKey, FieldText,
  Black, Navy, Silver, Lime, Yellow, Aqua, Fuchsia, White, Red, Teal;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  Cols = 80; Rows = 25; CellW = 10; CellH = 20;
  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  (* Win32 virtual-key codes *)
  VK_BACK = 08H; VK_TAB = 09H; VK_RETURN = 0DH; VK_ESCAPE = 1BH;
  VK_END = 23H; VK_HOME = 24H; VK_LEFT = 25H; VK_UP = 26H;
  VK_RIGHT = 27H; VK_DOWN = 28H; VK_DELETE = 2EH;
  FocusField = 0; FocusMenu = 1;
  FileMenu = 0; ViewMenu = 2; HelpMenu = 3;

VAR
  gWin:   Window;
  gPanel: TextWin;
  gField: Field;
  gFocus: CARDINAL;

PROCEDURE AppendStr (VAR dst: ARRAY OF CHAR; VAR pos: CARDINAL; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (pos < HIGH(dst)) DO
    dst[pos] := src[i]; INC(pos); INC(i)
  END;
  dst[pos] := 0C
END AppendStr;

PROCEDURE MapVK (vk: CARDINAL): CARDINAL;
BEGIN
  IF    vk = VK_LEFT   THEN RETURN KeyLeft
  ELSIF vk = VK_RIGHT  THEN RETURN KeyRight
  ELSIF vk = VK_UP     THEN RETURN KeyUp
  ELSIF vk = VK_DOWN   THEN RETURN KeyDown
  ELSIF vk = VK_RETURN THEN RETURN KeyEnter
  ELSIF vk = VK_ESCAPE THEN RETURN KeyEsc
  ELSIF vk = VK_DELETE THEN RETURN KeyDelete
  ELSIF vk = VK_HOME   THEN RETURN KeyHome
  ELSIF vk = VK_END    THEN RETURN KeyEnd
  END;
  RETURN KeyNone
END MapVK;

PROCEDURE Compose;
BEGIN
  MenuClear;
  MenuAdd("File"); MenuAddItem(FileMenu, "New"); MenuAddItem(FileMenu, "Open");
                   MenuAddItem(FileMenu, "Save"); MenuAddItem(FileMenu, "Quit");
  MenuAdd("Edit"); MenuAddItem(1, "Cut"); MenuAddItem(1, "Copy"); MenuAddItem(1, "Paste");
  MenuAdd("View"); MenuAddItem(ViewMenu, "Zoom In"); MenuAddItem(ViewMenu, "Zoom Out");
                   MenuAddItem(ViewMenu, "Toggle Help");
  MenuAdd("Help"); MenuAddItem(HelpMenu, "About");
  MenuSelect(0); MenuRender;

  WriteColAt(2, 2, Lime,    Black, "NewM2 Terminal");
  WriteColAt(2, 3, Yellow,  Black, "Direct2D / DirectWrite text, in Modula-2:");
  WriteColAt(4, 4, Aqua,    Black, "* coloured monospaced cells, drop-down menus");
  WriteColAt(4, 5, Fuchsia, Black, "* event-driven: the app reacts to menu/field events");
  WriteColAt(4, 6, White,   Black, "* an editable input field below");

  WinOpen(gPanel, 48, 2, 28, 8, White, Teal);
  WinClear(gPanel); WinBox(gPanel);
  WinGotoXY(gPanel, 2, 1); WinWrite(gPanel, "Text window (panel)");
  WinGotoXY(gPanel, 2, 3); WinWrite(gPanel, "Tab switches focus.");
  WinGotoXY(gPanel, 2, 4); WinWrite(gPanel, "Menu focus: Down opens.");

  WriteColAt(2, 18, Silver, Black, "Name:");
  FieldInit(gField, 8, 18, 40, White, Navy);
  FieldRender(gField);

  SetStatus(" [FIELD] Tab: focus | type to edit | Down: open menu | File>Quit ");
END Compose;

(* Respond to one semantic event the model produced. *)
PROCEDURE React (e: Event);
  VAR buf: ARRAY [0..79] OF CHAR; tmp: ARRAY [0..63] OF CHAR; pos: CARDINAL;
BEGIN
  pos := 0;
  IF e.kind = EvMenuMove THEN
    AppendStr(buf, pos, " menu: ");
    MenuTitle(e.menu, tmp); AppendStr(buf, pos, tmp);
    SetStatus(buf)
  ELSIF e.kind = EvMenuOpen THEN
    AppendStr(buf, pos, " opened: ");
    MenuTitle(e.menu, tmp); AppendStr(buf, pos, tmp);
    SetStatus(buf)
  ELSIF e.kind = EvMenuClose THEN
    SetStatus(" menu closed ")
  ELSIF e.kind = EvMenuItem THEN
    IF (e.menu = FileMenu) AND (e.item = 3) THEN          (* File > Quit *)
      Quit
    ELSIF (e.menu = ViewMenu) AND (e.item = 2) THEN       (* View > Toggle Help *)
      MenuEnable(HelpMenu, NOT MenuEnabled(HelpMenu));
      IF MenuEnabled(HelpMenu) THEN SetStatus(" Help menu enabled ")
      ELSE SetStatus(" Help menu disabled ") END
    ELSE
      AppendStr(buf, pos, " chose: ");
      MenuTitle(e.menu, tmp); AppendStr(buf, pos, tmp);
      AppendStr(buf, pos, " / ");
      MenuItemText(e.menu, e.item, tmp); AppendStr(buf, pos, tmp);
      SetStatus(buf)
    END
  ELSIF e.kind = EvFieldChange THEN
    AppendStr(buf, pos, " editing: ");
    FieldText(gField, tmp); AppendStr(buf, pos, tmp);
    SetStatus(buf)
  ELSIF e.kind = EvSubmit THEN
    AppendStr(buf, pos, " submitted: ");
    FieldText(gField, tmp); AppendStr(buf, pos, tmp);
    SetStatus(buf)
  ELSIF e.kind = EvCancel THEN
    SetStatus(" cancelled ")
  END
END React;

PROCEDURE Drain;
  VAR e: Event;
BEGIN
  WHILE NextEvent(e) DO React(e) END
END Drain;

PROCEDURE ToggleFocus;
BEGIN
  IF gFocus = FocusField THEN
    gFocus := FocusMenu; SetStatus(" [MENU] Left/Right pick | Down open | Enter choose | Tab: field ")
  ELSE
    gFocus := FocusField; SetStatus(" [FIELD] type to edit | Enter submit | Tab: menu bar ")
  END
END ToggleFocus;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; consumed: BOOLEAN; key: CARDINAL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Paint();
    ok := ValidateRect(w, NIL);
    RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    key := MapVK(wParam);
    consumed := FALSE;
    IF wParam = VK_TAB THEN
      IF MenuIsOpen() THEN MenuClose ELSE ToggleFocus END;
      consumed := TRUE
    ELSIF key # KeyNone THEN
      IF MenuIsOpen() OR (gFocus = FocusMenu) THEN consumed := HandleKey(key, 0C)
      ELSE consumed := FieldHandleKey(gField, key, 0C) END
    END;
    IF consumed THEN
      Drain; MenuRender; FieldRender(gField); Repaint(w)
    END;
    RETURN 0
  ELSIF msg = WM_CHAR THEN
    IF (gFocus = FocusField) AND (NOT MenuIsOpen()) THEN
      ch := CHR(wParam);
      consumed := FALSE;
      IF ch >= ' ' THEN consumed := FieldHandleKey(gField, KeyChar, ch)
      ELSIF ch = CHR(8) THEN consumed := FieldHandleKey(gField, KeyBack, ch) END;
      IF consumed THEN Drain; FieldRender(gField); Repaint(w) END
    END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  gFocus := FocusField;
  ok := Startup("Consolas", VAL(SHORTREAL, 16.0));
  Init(Cols, Rows);
  Compose;
  gWin := CreateAppWindow("NewM2 Terminal", Cols*CellW + 16, Rows*CellH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  ok := Attach(gWin, cw, ch, CellW, CellH);
  Paint();                              (* force the first frame; later frames via WM_PAINT *)
  Repaint(gWin);
  RunMessageLoop()
END TermDemo.
