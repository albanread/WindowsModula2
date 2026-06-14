MODULE T90247TerminalExt;
(*
 * Group 90 — TUI terminal MODEL, extended controller surface. Builds on the
 * t-90-244 model with the features a controlling app drives: editing the menu
 * bar after creation (rename / insert / remove / enable+disable + skip), drop-
 * down menus (open over saved cells, navigate items, close+restore underneath),
 * a semantic event queue (FIFO), the HandleKey dispatcher, field caret editing,
 * and the area-drawing helpers. All observable headlessly by reading cells back.
 *
 * EXPECTED:
 * mcount: 4
 * rename: Y
 * insert: Y
 * remove: Y
 * enabled: Y
 * skipnext: Y
 * skipprev: Y
 * items: 3
 * open: Y
 * popbox: Y
 * itemsel: Y
 * itemtext: Y
 * choose: Y
 * restore: Y
 * menumove: Y
 * openkey: Y
 * hasevt: Y
 * evorder: Y
 * evdrain: Y
 * fcaret: Y
 * fchange: Y
 * fsubmit: Y
 * draw: Y
 *)
FROM Terminal IMPORT
  Init, MenuClear, MenuAdd, MenuCount, MenuSelect, MenuSelected, MenuNext, MenuPrev,
  MenuTitle, MenuSetTitle, MenuInsert, MenuRemove, MenuEnable, MenuEnabled,
  MenuAddItem, MenuItemCount, MenuItemText, MenuClearItems,
  MenuOpen, MenuClose, MenuIsOpen, MenuItemSelected, MenuItemNext, MenuRender,
  PostEvent, NextEvent, HasEvent, ClearEvents, HandleKey,
  Event, EvMenuMove, EvMenuOpen, EvMenuItem, EvFieldChange, EvSubmit,
  KeyEnter, KeyRight, KeyDown, KeyChar,
  Field, FieldInit, FieldSet, FieldText, FieldHome, FieldRight, FieldDelete,
  FieldCaret, FieldHandleKey,
  Fill, Box, CellChar, CellBg, WriteColAt,
  Navy, Red, Lime, Yellow, Blue, White, Maroon, Black;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR
  t, s: ARRAY [0..63] OF CHAR;
  f: Field;
  e, e2: Event;
  ok: BOOLEAN;
BEGIN
  Init(80, 25);

  (* ---- editing the menu bar ---- *)
  MenuClear; MenuAdd("File"); MenuAdd("Edit"); MenuAdd("View"); MenuAdd("Help");
  WriteString("mcount: "); WriteCard(MenuCount(), 1); WriteLn;

  MenuSetTitle(1, "Edytuj"); MenuTitle(1, t);
  WriteString("rename: "); YN((t[0] = 'E') AND (t[5] = 'j') AND (t[6] = 0C)); WriteLn;

  MenuInsert(2, "Run"); MenuTitle(2, t);
  WriteString("insert: ");
  YN((MenuCount() = 5) AND (t[0] = 'R') AND (t[1] = 'u') AND (t[2] = 'n') AND (t[3] = 0C)); WriteLn;

  MenuRemove(0); MenuTitle(0, t);             (* -> [Edytuj, Run, View, Help] *)
  WriteString("remove: "); YN((MenuCount() = 4) AND (t[0] = 'E') AND (t[5] = 'j')); WriteLn;

  MenuSelect(0); MenuEnable(1, FALSE);        (* disable "Run" *)
  WriteString("enabled: "); YN((NOT MenuEnabled(1)) AND MenuEnabled(2)); WriteLn;

  ok := MenuNext();                            (* 0 -> skip disabled 1 -> 2 *)
  WriteString("skipnext: "); YN(ok AND (MenuSelected() = 2)); WriteLn;
  ok := MenuPrev();                            (* 2 -> skip disabled 1 -> 0 *)
  WriteString("skipprev: "); YN(ok AND (MenuSelected() = 0)); WriteLn;

  (* ---- drop-down menu ---- *)
  MenuEnable(1, TRUE); MenuSelect(2);          (* on "View" *)
  MenuClearItems(2);
  MenuAddItem(2, "Zoom In"); MenuAddItem(2, "Zoom Out"); MenuAddItem(2, "Reset");
  WriteString("items: "); WriteCard(MenuItemCount(2), 1); WriteLn;

  WriteColAt(20, 3, Red, Lime, "Z");           (* marker under the popup, to test restore *)

  MenuOpen;
  WriteString("open: "); YN(MenuIsOpen() AND (MenuItemSelected() = 0)); WriteLn;

  MenuRender;                                  (* paints the bar + the open drop-down *)
  WriteString("popbox: ");
  YN((CellChar(16, 1) = CHR(250CH)) AND (CellChar(18, 2) = 'Z') AND (CellBg(18, 2) = Navy)); WriteLn;

  ok := MenuItemNext(); ok := MenuItemNext();  (* highlight item 2 = "Reset" *)
  WriteString("itemsel: "); YN(MenuItemSelected() = 2); WriteLn;
  MenuItemText(2, MenuItemSelected(), t);
  WriteString("itemtext: "); YN((t[0] = 'R') AND (t[4] = 't') AND (t[5] = 0C)); WriteLn;

  ClearEvents;
  ok := HandleKey(KeyEnter, 0C);               (* choose the item: posts EvMenuItem + closes *)
  WriteString("choose: ");
  IF NextEvent(e) THEN
    YN((e.kind = EvMenuItem) AND (e.menu = 2) AND (e.item = 2) AND (NOT MenuIsOpen()))
  ELSE YN(FALSE) END; WriteLn;

  WriteString("restore: "); YN(CellChar(20, 3) = 'Z'); WriteLn;

  (* ---- key dispatch -> events ---- *)
  ClearEvents;
  ok := HandleKey(KeyRight, 0C);               (* 2 -> 3, posts EvMenuMove *)
  WriteString("menumove: ");
  IF NextEvent(e) THEN YN((e.kind = EvMenuMove) AND (e.menu = 3) AND (MenuSelected() = 3))
  ELSE YN(FALSE) END; WriteLn;

  ClearEvents; MenuSelect(2);
  ok := HandleKey(KeyDown, 0C);                (* opens "View", posts EvMenuOpen *)
  WriteString("openkey: ");
  IF NextEvent(e) THEN YN((e.kind = EvMenuOpen) AND (e.menu = 2) AND MenuIsOpen())
  ELSE YN(FALSE) END; WriteLn;
  MenuClose;

  (* ---- event queue is FIFO ---- *)
  ClearEvents;
  PostEvent(EvMenuMove, 1, 0, 0C);
  PostEvent(EvSubmit, 0, 0, 'x');
  WriteString("hasevt: "); YN(HasEvent()); WriteLn;
  ok := NextEvent(e);
  WriteString("evorder: "); YN((e.kind = EvMenuMove) AND (e.menu = 1)); WriteLn;
  ok := NextEvent(e2);
  WriteString("evdrain: "); YN((e2.kind = EvSubmit) AND (NOT HasEvent())); WriteLn;

  (* ---- field caret editing ---- *)
  FieldInit(f, 5, 20, 12, White, Maroon);
  FieldSet(f, "Hello");
  FieldHome(f);
  ok := FieldRight(f); ok := FieldRight(f);    (* caret -> 2 *)
  ok := FieldDelete(f);                        (* delete 'l' at caret -> "Helo" *)
  FieldText(f, s);
  WriteString("fcaret: ");
  YN((FieldCaret(f) = 2) AND (s[0] = 'H') AND (s[3] = 'o') AND (s[4] = 0C)); WriteLn;

  ClearEvents;
  ok := FieldHandleKey(f, KeyChar, '!');       (* insert '!' -> posts EvFieldChange *)
  WriteString("fchange: ");
  IF NextEvent(e) THEN YN((e.kind = EvFieldChange) AND (e.ch = '!') AND ok)
  ELSE YN(FALSE) END; WriteLn;

  ClearEvents;
  ok := FieldHandleKey(f, KeyEnter, 0C);       (* posts EvSubmit *)
  WriteString("fsubmit: ");
  IF NextEvent(e) THEN YN((e.kind = EvSubmit) AND ok) ELSE YN(FALSE) END; WriteLn;

  (* ---- area drawing helpers ---- *)
  Fill(60, 10, 5, 3, '#', Yellow, Blue);
  Box(60, 10, 5, 3, White, Black);
  WriteString("draw: ");
  YN((CellChar(60, 10) = CHR(250CH)) AND (CellChar(64, 12) = CHR(2518H))
     AND (CellChar(62, 11) = '#') AND (CellBg(62, 11) = Blue)); WriteLn
END T90247TerminalExt.
