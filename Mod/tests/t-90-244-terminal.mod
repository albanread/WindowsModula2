MODULE T90244Terminal;
(*
 * Group 90 — TUI terminal MODEL (rendered later with Direct2D/DirectWrite). The
 * model is pure Modula-2 and fully observable by reading cells back, so the
 * whole feature surface is testable headlessly: coloured monospaced text, cursor
 * positioning with wrap, a status bar, a menu bar with a highlighted selection,
 * text windows (with a box border), and an editable input field.
 *
 * EXPECTED:
 * size: Y
 * text: Y
 * colour: Y
 * poscol: Y
 * cursor: Y
 * wrap: Y
 * status: Y
 * menucnt: 3
 * menusel: Y
 * box: Y
 * panel: Y
 * field text: Y
 * field edit: Y
 *)
FROM Terminal IMPORT
  Init, Cols, Rows, SetColour, GotoXY, WhereX, WhereY, Write, WriteAt, WriteColAt,
  CellChar, CellFg, CellBg, SetStatus, MenuClear, MenuAdd, MenuSelect, MenuRender,
  MenuCount, TextWin, WinOpen, WinClear, WinBox, WinGotoXY, WinWrite,
  Field, FieldInit, FieldSet, FieldKey, FieldText, FieldRender,
  Red, Lime, Navy, Yellow, White, Maroon;
FROM StrIO IMPORT WriteString, WriteLn;
FROM NumberIO IMPORT WriteCard;

PROCEDURE YN (b: BOOLEAN); BEGIN IF b THEN WriteString("Y") ELSE WriteString("N") END END YN;

VAR tw: TextWin; f: Field; s: ARRAY [0..63] OF CHAR; ok: BOOLEAN;
BEGIN
  Init(80, 25);
  WriteString("size: "); YN((Cols() = 80) AND (Rows() = 25)); WriteLn;

  WriteAt(0, 0, "Hello");
  WriteString("text: "); YN((CellChar(0,0) = 'H') AND (CellChar(4,0) = 'o')); WriteLn;

  SetColour(Red, Navy); WriteAt(0, 1, "X");
  WriteString("colour: "); YN((CellFg(0,1) = Red) AND (CellBg(0,1) = Navy)); WriteLn;

  WriteColAt(10, 2, Lime, Navy, "Go");
  WriteString("poscol: "); YN((CellChar(10,2) = 'G') AND (CellFg(10,2) = Lime) AND (CellBg(11,2) = Navy)); WriteLn;

  GotoXY(5, 5); SetColour(Yellow, Navy); Write("AB");
  WriteString("cursor: "); YN((WhereX() = 7) AND (WhereY() = 5) AND (CellChar(5,5) = 'A')); WriteLn;

  GotoXY(78, 10); Write("ABCD");
  WriteString("wrap: "); YN((CellChar(78,10) = 'A') AND (CellChar(79,10) = 'B') AND (CellChar(0,11) = 'C') AND (CellChar(1,11) = 'D')); WriteLn;

  SetStatus("Ready");
  WriteString("status: "); YN((CellChar(0,24) = 'R') AND (CellBg(0,24) = Navy) AND (CellChar(79,24) = ' ')); WriteLn;

  MenuClear; MenuAdd("File"); MenuAdd("Edit"); MenuAdd("View"); MenuSelect(1); MenuRender;
  WriteString("menucnt: "); WriteCard(MenuCount(), 1); WriteLn;
  WriteString("menusel: "); YN((CellChar(2,0) = 'F') AND (CellChar(9,0) = 'E') AND (CellBg(9,0) = Navy)); WriteLn;

  WinOpen(tw, 10, 5, 20, 8, Lime, Navy); WinClear(tw); WinBox(tw);
  WriteString("box: "); YN((CellChar(10,5) = CHR(250CH)) AND (CellChar(29,12) = CHR(2518H))); WriteLn;
  WinGotoXY(tw, 2, 1); WinWrite(tw, "Panel");
  WriteString("panel: "); YN((CellChar(12,6) = 'P') AND (CellChar(16,6) = 'l') AND (CellFg(12,6) = Lime)); WriteLn;

  FieldInit(f, 5, 20, 10, White, Maroon); FieldSet(f, "Hi");
  ok := FieldKey(f, '!');           (* "Hi!" *)
  ok := FieldKey(f, CHR(8));        (* backspace -> "Hi" *)
  FieldText(f, s);
  WriteString("field text: "); YN((s[0] = 'H') AND (s[1] = 'i') AND (s[2] = 0C)); WriteLn;
  FieldRender(f);
  WriteString("field edit: "); YN((CellChar(5,20) = 'H') AND (CellChar(6,20) = 'i') AND (CellFg(5,20) = White)); WriteLn
END T90244Terminal.
