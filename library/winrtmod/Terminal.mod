IMPLEMENTATION MODULE Terminal;

CONST
  MaxCols  = 220;
  MaxRows  = 70;
  MaxMenu  = 16;
  MaxItems = 16;
  TitleHi  = 31;                 (* title/item arrays are ARRAY [0..TitleHi] OF CHAR *)
  MaxEvents = 64;
  PopMaxW  = 40;                 (* drop-down save-buffer bounds *)
  PopMaxH  = MaxItems + 2;
  NUL = 0C;

TYPE
  MenuRec = RECORD
    title:   ARRAY [0..TitleHi] OF CHAR;
    enabled: BOOLEAN;
    nItems:  CARDINAL;
    items:   ARRAY [0..MaxItems-1], [0..TitleHi] OF CHAR;
    colAt:   CARDINAL;           (* left edge of this title on the bar (set by MenuLayout) *)
  END;

VAR
  gChar: ARRAY [0..MaxRows-1], [0..MaxCols-1] OF CHAR;
  gFg:   ARRAY [0..MaxRows-1], [0..MaxCols-1] OF Colour;
  gBg:   ARRAY [0..MaxRows-1], [0..MaxCols-1] OF Colour;
  gCols, gRows, gCurX, gCurY: CARDINAL;
  gCurFg, gCurBg: Colour;

  gMenu: ARRAY [0..MaxMenu-1] OF MenuRec;
  gMenuCount, gMenuSel: CARDINAL;
  gMenuOpen: BOOLEAN;
  gMenuFocused: BOOLEAN;         (* highlight the selected title only when focused *)
  gItemSel: CARDINAL;            (* highlighted item in the open drop-down *)

  (* cells the open drop-down covers, saved so MenuClose can restore them *)
  gSaveChar: ARRAY [0..PopMaxH-1], [0..PopMaxW-1] OF CHAR;
  gSaveFg:   ARRAY [0..PopMaxH-1], [0..PopMaxW-1] OF Colour;
  gSaveBg:   ARRAY [0..PopMaxH-1], [0..PopMaxW-1] OF Colour;
  gSaveX, gSaveY, gSaveW, gSaveH: CARDINAL;
  gSaveValid: BOOLEAN;

  (* event ring buffer *)
  gEv: ARRAY [0..MaxEvents-1] OF Event;
  gEvHead, gEvLen: CARDINAL;

PROCEDURE StrLen (s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # NUL) DO INC(i) END;
  RETURN i
END StrLen;

PROCEDURE CopyStr (src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR; maxLen: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (i < maxLen) AND (i <= HIGH(dst)) AND (src[i] # NUL) DO
    dst[i] := src[i]; INC(i)
  END;
  IF i <= HIGH(dst) THEN dst[i] := NUL END
END CopyStr;

PROCEDURE SetCell (row, col: CARDINAL; ch: CHAR; fg, bg: Colour);
BEGIN
  IF (row < gRows) AND (col < gCols) THEN
    gChar[row][col] := ch; gFg[row][col] := fg; gBg[row][col] := bg
  END
END SetCell;

PROCEDURE Cols (): CARDINAL; BEGIN RETURN gCols END Cols;
PROCEDURE Rows (): CARDINAL; BEGIN RETURN gRows END Rows;
PROCEDURE Fg (): Colour; BEGIN RETURN gCurFg END Fg;
PROCEDURE Bg (): Colour; BEGIN RETURN gCurBg END Bg;
PROCEDURE WhereX (): CARDINAL; BEGIN RETURN gCurX END WhereX;
PROCEDURE WhereY (): CARDINAL; BEGIN RETURN gCurY END WhereY;

PROCEDURE SetColour (fg, bg: Colour); BEGIN gCurFg := fg; gCurBg := bg END SetColour;

PROCEDURE GotoXY (col, row: CARDINAL);
BEGIN
  IF col < gCols THEN gCurX := col END;
  IF row < gRows THEN gCurY := row END
END GotoXY;

PROCEDURE Clear;
  VAR r, c: CARDINAL;
BEGIN
  r := 0;
  WHILE r < gRows DO
    c := 0;
    WHILE c < gCols DO SetCell(r, c, ' ', gCurFg, gCurBg); INC(c) END;
    INC(r)
  END;
  gCurX := 0; gCurY := 0
END Clear;

PROCEDURE Init (cols, rows: CARDINAL);
BEGIN
  IF cols > MaxCols THEN cols := MaxCols ELSIF cols < 1 THEN cols := 1 END;
  IF rows > MaxRows THEN rows := MaxRows ELSIF rows < 1 THEN rows := 1 END;
  gCols := cols; gRows := rows;
  gCurFg := White; gCurBg := Black;
  gMenuCount := 0; gMenuSel := 0; gMenuOpen := FALSE; gItemSel := 0;
  gMenuFocused := TRUE;          (* default on, for consumers that don't manage focus *)
  gSaveValid := FALSE;
  gEvHead := 0; gEvLen := 0;
  Clear
END Init;

PROCEDURE ScrollUp;
  VAR r, c: CARDINAL;
BEGIN
  r := 0;
  WHILE r < gRows - 1 DO
    c := 0;
    WHILE c < gCols DO
      gChar[r][c] := gChar[r+1][c];
      gFg[r][c]   := gFg[r+1][c];
      gBg[r][c]   := gBg[r+1][c];
      INC(c)
    END;
    INC(r)
  END;
  c := 0;
  WHILE c < gCols DO SetCell(gRows-1, c, ' ', gCurFg, gCurBg); INC(c) END
END ScrollUp;

PROCEDURE NewLineDown;
BEGIN
  INC(gCurY);
  IF gCurY >= gRows THEN ScrollUp; gCurY := gRows - 1 END
END NewLineDown;

PROCEDURE Put (ch: CHAR);
BEGIN
  IF ch = CHR(13) THEN gCurX := 0
  ELSIF ch = CHR(10) THEN gCurX := 0; NewLineDown
  ELSE
    SetCell(gCurY, gCurX, ch, gCurFg, gCurBg);
    INC(gCurX);
    IF gCurX >= gCols THEN gCurX := 0; NewLineDown END
  END
END Put;

PROCEDURE Write (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # NUL) DO Put(s[i]); INC(i) END
END Write;

PROCEDURE WriteAt (col, row: CARDINAL; s: ARRAY OF CHAR);
BEGIN
  GotoXY(col, row); Write(s)
END WriteAt;

PROCEDURE WriteColAt (col, row: CARDINAL; fg, bg: Colour; s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # NUL) AND (col + i < gCols) DO
    SetCell(row, col + i, s[i], fg, bg);
    INC(i)
  END
END WriteColAt;

(* ---- area drawing ---- *)
PROCEDURE Fill (col, row, w, h: CARDINAL; ch: CHAR; fg, bg: Colour);
  VAR r, c: CARDINAL;
BEGIN
  r := 0;
  WHILE r < h DO
    c := 0;
    WHILE c < w DO SetCell(row + r, col + c, ch, fg, bg); INC(c) END;
    INC(r)
  END
END Fill;

PROCEDURE HLine (col, row, len: CARDINAL; ch: CHAR; fg, bg: Colour);
  VAR c: CARDINAL;
BEGIN c := 0; WHILE c < len DO SetCell(row, col + c, ch, fg, bg); INC(c) END END HLine;

PROCEDURE VLine (col, row, len: CARDINAL; ch: CHAR; fg, bg: Colour);
  VAR r: CARDINAL;
BEGIN r := 0; WHILE r < len DO SetCell(row + r, col, ch, fg, bg); INC(r) END END VLine;

PROCEDURE Box (col, row, w, h: CARDINAL; fg, bg: Colour);
  VAR c, r: CARDINAL;
BEGIN
  IF (w < 2) OR (h < 2) THEN RETURN END;
  SetCell(row, col, CHR(250CH), fg, bg);
  SetCell(row, col + w - 1, CHR(2510H), fg, bg);
  SetCell(row + h - 1, col, CHR(2514H), fg, bg);
  SetCell(row + h - 1, col + w - 1, CHR(2518H), fg, bg);
  c := 1;
  WHILE c < w - 1 DO
    SetCell(row, col + c, CHR(2500H), fg, bg);
    SetCell(row + h - 1, col + c, CHR(2500H), fg, bg);
    INC(c)
  END;
  r := 1;
  WHILE r < h - 1 DO
    SetCell(row + r, col, CHR(2502H), fg, bg);
    SetCell(row + r, col + w - 1, CHR(2502H), fg, bg);
    INC(r)
  END
END Box;

PROCEDURE CellChar (col, row: CARDINAL): CHAR;
BEGIN
  IF (row < gRows) AND (col < gCols) THEN RETURN gChar[row][col] END;
  RETURN ' '
END CellChar;

PROCEDURE CellFg (col, row: CARDINAL): Colour;
BEGIN
  IF (row < gRows) AND (col < gCols) THEN RETURN gFg[row][col] END;
  RETURN gCurFg
END CellFg;

PROCEDURE CellBg (col, row: CARDINAL): Colour;
BEGIN
  IF (row < gRows) AND (col < gCols) THEN RETURN gBg[row][col] END;
  RETURN gCurBg
END CellBg;

(* ---- status bar ---- *)
PROCEDURE SetStatusColour (s: ARRAY OF CHAR; fg, bg: Colour);
  VAR c, n, row: CARDINAL;
BEGIN
  row := gRows - 1;
  n := StrLen(s);
  c := 0;
  WHILE c < gCols DO
    IF c < n THEN SetCell(row, c, s[c], fg, bg)
    ELSE SetCell(row, c, ' ', fg, bg) END;
    INC(c)
  END
END SetStatusColour;

PROCEDURE SetStatus (s: ARRAY OF CHAR);
BEGIN SetStatusColour(s, White, Navy) END SetStatus;

(* ---- menu bar ---- *)
PROCEDURE MenuClear;
BEGIN gMenuCount := 0; gMenuSel := 0; gMenuOpen := FALSE; gSaveValid := FALSE END MenuClear;

PROCEDURE MenuCount (): CARDINAL; BEGIN RETURN gMenuCount END MenuCount;
PROCEDURE MenuSelected (): CARDINAL; BEGIN RETURN gMenuSel END MenuSelected;

PROCEDURE MenuAdd (title: ARRAY OF CHAR);
BEGIN
  IF gMenuCount >= MaxMenu THEN RETURN END;
  CopyStr(title, gMenu[gMenuCount].title, TitleHi);
  gMenu[gMenuCount].enabled := TRUE;
  gMenu[gMenuCount].nItems := 0;
  INC(gMenuCount)
END MenuAdd;

(* lay out each title's left column (and so the drop-down origin) without drawing *)
PROCEDURE MenuLayout;
  VAR i, col: CARDINAL;
BEGIN
  col := 1; i := 0;
  WHILE i < gMenuCount DO
    gMenu[i].colAt := col;
    INC(col);                              (* leading pad *)
    col := col + StrLen(gMenu[i].title);   (* title *)
    INC(col);                              (* trailing pad *)
    INC(col);                              (* gap before the next menu *)
    INC(i)
  END
END MenuLayout;

(* geometry of the highlighted menu's drop-down popup *)
PROCEDURE PopupGeom (VAR px, py, pw, ph: CARDINAL);
  VAR i, tl, maxw: CARDINAL;
BEGIN
  maxw := 0; i := 0;
  WHILE i < gMenu[gMenuSel].nItems DO
    tl := StrLen(gMenu[gMenuSel].items[i]);
    IF tl > maxw THEN maxw := tl END;
    INC(i)
  END;
  pw := maxw + 4;                          (* border (2) + one pad each side *)
  IF pw < 4 THEN pw := 4 END;
  IF pw > PopMaxW THEN pw := PopMaxW END;
  ph := gMenu[gMenuSel].nItems + 2;        (* top + bottom border *)
  IF ph > PopMaxH THEN ph := PopMaxH END;
  px := gMenu[gMenuSel].colAt;
  py := 1;
  IF px + pw > gCols THEN
    IF pw <= gCols THEN px := gCols - pw ELSE px := 0 END
  END
END PopupGeom;

PROCEDURE DrawDropdown;
  VAR px, py, pw, ph, i, j, tl, col: CARDINAL; fg, bg: Colour;
BEGIN
  PopupGeom(px, py, pw, ph);
  Box(px, py, pw, ph, Black, Silver);
  Fill(px + 1, py + 1, pw - 2, ph - 2, ' ', Black, Silver);
  i := 0;
  WHILE i < gMenu[gMenuSel].nItems DO
    IF i = gItemSel THEN fg := White; bg := Navy ELSE fg := Black; bg := Silver END;
    col := px + 1;
    SetCell(py + 1 + i, col, ' ', fg, bg); INC(col);
    tl := StrLen(gMenu[gMenuSel].items[i]); j := 0;
    WHILE (j < tl) AND (col < px + pw - 1) DO
      SetCell(py + 1 + i, col, gMenu[gMenuSel].items[i][j], fg, bg);
      INC(col); INC(j)
    END;
    WHILE col < px + pw - 1 DO SetCell(py + 1 + i, col, ' ', fg, bg); INC(col) END;
    INC(i)
  END
END DrawDropdown;

PROCEDURE MenuBarHit (col: CARDINAL): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  MenuLayout;
  i := 0;
  WHILE i < gMenuCount DO
    IF (col >= gMenu[i].colAt) AND (col < gMenu[i].colAt + StrLen(gMenu[i].title) + 2) THEN
      RETURN i
    END;
    INC(i)
  END;
  RETURN MAX(CARDINAL)
END MenuBarHit;

PROCEDURE MenuPopupHit (col, row: CARDINAL): CARDINAL;
  VAR px, py, pw, ph: CARDINAL;
BEGIN
  IF NOT gMenuOpen THEN RETURN MAX(CARDINAL) END;
  PopupGeom(px, py, pw, ph);
  IF (row >= py + 1) AND (row <= py + gMenu[gMenuSel].nItems) AND
     (col >= px) AND (col < px + pw) THEN
    RETURN row - (py + 1)
  END;
  RETURN MAX(CARDINAL)
END MenuPopupHit;

PROCEDURE MenuClose;
  VAR r, c: CARDINAL;
BEGIN
  IF NOT gMenuOpen THEN RETURN END;
  gMenuOpen := FALSE;
  IF gSaveValid THEN
    r := 0;
    WHILE r < gSaveH DO
      c := 0;
      WHILE c < gSaveW DO
        SetCell(gSaveY + r, gSaveX + c, gSaveChar[r][c], gSaveFg[r][c], gSaveBg[r][c]);
        INC(c)
      END;
      INC(r)
    END;
    gSaveValid := FALSE
  END
END MenuClose;

PROCEDURE MenuOpen;
  VAR px, py, pw, ph, r, c: CARDINAL;
BEGIN
  IF gMenuOpen THEN RETURN END;
  IF gMenuSel >= gMenuCount THEN RETURN END;
  IF NOT gMenu[gMenuSel].enabled THEN RETURN END;
  IF gMenu[gMenuSel].nItems = 0 THEN RETURN END;
  MenuLayout;
  PopupGeom(px, py, pw, ph);
  gSaveX := px; gSaveY := py; gSaveW := pw; gSaveH := ph;
  r := 0;
  WHILE r < ph DO
    c := 0;
    WHILE c < pw DO
      gSaveChar[r][c] := CellChar(px + c, py + r);
      gSaveFg[r][c]   := CellFg(px + c, py + r);
      gSaveBg[r][c]   := CellBg(px + c, py + r);
      INC(c)
    END;
    INC(r)
  END;
  gSaveValid := TRUE;
  gItemSel := 0;
  gMenuOpen := TRUE
END MenuOpen;

PROCEDURE MenuSetFocus (on: BOOLEAN);
BEGIN gMenuFocused := on END MenuSetFocus;

PROCEDURE MenuRender;
  VAR i, col, j, tl: CARDINAL; fg, bg: Colour;
BEGIN
  MenuLayout;
  col := 0;
  WHILE col < gCols DO SetCell(0, col, ' ', Black, Silver); INC(col) END;
  i := 0;
  WHILE i < gMenuCount DO
    IF NOT gMenu[i].enabled THEN fg := Gray; bg := Silver
    ELSIF (i = gMenuSel) AND gMenuFocused THEN fg := White; bg := Navy
    ELSE fg := Black; bg := Silver END;
    col := gMenu[i].colAt;
    IF col < gCols THEN SetCell(0, col, ' ', fg, bg) END;
    INC(col);
    tl := StrLen(gMenu[i].title); j := 0;
    WHILE (j < tl) AND (col < gCols) DO SetCell(0, col, gMenu[i].title[j], fg, bg); INC(col); INC(j) END;
    IF col < gCols THEN SetCell(0, col, ' ', fg, bg) END;
    INC(i)
  END;
  IF gMenuOpen THEN DrawDropdown END
END MenuRender;

(* move the highlight, carrying an open drop-down with it *)
PROCEDURE MoveSelTo (index: CARDINAL);
  VAR wasOpen: BOOLEAN;
BEGIN
  wasOpen := gMenuOpen;
  IF wasOpen THEN MenuClose END;
  gMenuSel := index;
  IF wasOpen THEN MenuOpen END
END MoveSelTo;

PROCEDURE MenuSelect (index: CARDINAL);
BEGIN IF index < gMenuCount THEN MoveSelTo(index) END END MenuSelect;

PROCEDURE MenuNext (): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF gMenuCount = 0 THEN RETURN FALSE END;
  i := gMenuSel;
  WHILE i + 1 < gMenuCount DO
    INC(i);
    IF gMenu[i].enabled THEN MoveSelTo(i); RETURN TRUE END
  END;
  RETURN FALSE
END MenuNext;

PROCEDURE MenuPrev (): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF (gMenuCount = 0) OR (gMenuSel = 0) THEN RETURN FALSE END;
  i := gMenuSel;
  WHILE i > 0 DO
    DEC(i);
    IF gMenu[i].enabled THEN MoveSelTo(i); RETURN TRUE END
  END;
  RETURN FALSE
END MenuPrev;

PROCEDURE MenuTitle (index: CARDINAL; VAR s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  IF index < gMenuCount THEN
    WHILE (i < HIGH(s)) AND (gMenu[index].title[i] # NUL) DO s[i] := gMenu[index].title[i]; INC(i) END
  END;
  s[i] := NUL
END MenuTitle;

PROCEDURE MenuSetTitle (index: CARDINAL; title: ARRAY OF CHAR);
BEGIN IF index < gMenuCount THEN CopyStr(title, gMenu[index].title, TitleHi) END END MenuSetTitle;

(* field-by-field copy of one menu slot (avoids whole-record-with-array assign) *)
PROCEDURE MenuSlotCopy (dst, src: CARDINAL);
  VAR i, j: CARDINAL;
BEGIN
  i := 0;
  WHILE i <= TitleHi DO gMenu[dst].title[i] := gMenu[src].title[i]; INC(i) END;
  gMenu[dst].enabled := gMenu[src].enabled;
  gMenu[dst].nItems := gMenu[src].nItems;
  i := 0;
  WHILE i < MaxItems DO
    j := 0;
    WHILE j <= TitleHi DO gMenu[dst].items[i][j] := gMenu[src].items[i][j]; INC(j) END;
    INC(i)
  END
END MenuSlotCopy;

PROCEDURE MenuInsert (index: CARDINAL; title: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  IF gMenuCount >= MaxMenu THEN RETURN END;
  IF index > gMenuCount THEN index := gMenuCount END;
  IF gMenuOpen THEN MenuClose END;
  i := gMenuCount;
  WHILE i > index DO MenuSlotCopy(i, i - 1); DEC(i) END;
  CopyStr(title, gMenu[index].title, TitleHi);
  gMenu[index].enabled := TRUE;
  gMenu[index].nItems := 0;
  INC(gMenuCount);
  IF gMenuSel >= gMenuCount THEN gMenuSel := gMenuCount - 1 END
END MenuInsert;

PROCEDURE MenuRemove (index: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  IF index >= gMenuCount THEN RETURN END;
  IF gMenuOpen THEN MenuClose END;
  i := index;
  WHILE i + 1 < gMenuCount DO MenuSlotCopy(i, i + 1); INC(i) END;
  DEC(gMenuCount);
  IF gMenuCount = 0 THEN gMenuSel := 0
  ELSIF gMenuSel >= gMenuCount THEN gMenuSel := gMenuCount - 1 END
END MenuRemove;

PROCEDURE MenuEnable (index: CARDINAL; on: BOOLEAN);
BEGIN IF index < gMenuCount THEN gMenu[index].enabled := on END END MenuEnable;

PROCEDURE MenuEnabled (index: CARDINAL): BOOLEAN;
BEGIN IF index < gMenuCount THEN RETURN gMenu[index].enabled END; RETURN FALSE END MenuEnabled;

(* ---- drop-down items ---- *)
PROCEDURE MenuAddItem (menu: CARDINAL; text: ARRAY OF CHAR);
BEGIN
  IF (menu < gMenuCount) AND (gMenu[menu].nItems < MaxItems) THEN
    CopyStr(text, gMenu[menu].items[gMenu[menu].nItems], TitleHi);
    INC(gMenu[menu].nItems)
  END
END MenuAddItem;

PROCEDURE MenuItemCount (menu: CARDINAL): CARDINAL;
BEGIN IF menu < gMenuCount THEN RETURN gMenu[menu].nItems END; RETURN 0 END MenuItemCount;

PROCEDURE MenuItemText (menu, item: CARDINAL; VAR s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  IF (menu < gMenuCount) AND (item < gMenu[menu].nItems) THEN
    WHILE (i < HIGH(s)) AND (gMenu[menu].items[item][i] # NUL) DO
      s[i] := gMenu[menu].items[item][i]; INC(i)
    END
  END;
  s[i] := NUL
END MenuItemText;

PROCEDURE MenuSetItem (menu, item: CARDINAL; text: ARRAY OF CHAR);
BEGIN
  IF (menu < gMenuCount) AND (item < gMenu[menu].nItems) THEN
    CopyStr(text, gMenu[menu].items[item], TitleHi)
  END
END MenuSetItem;

PROCEDURE MenuClearItems (menu: CARDINAL);
BEGIN IF menu < gMenuCount THEN gMenu[menu].nItems := 0 END END MenuClearItems;

PROCEDURE MenuIsOpen (): BOOLEAN; BEGIN RETURN gMenuOpen END MenuIsOpen;
PROCEDURE MenuItemSelected (): CARDINAL; BEGIN RETURN gItemSel END MenuItemSelected;

PROCEDURE MenuItemSelect (item: CARDINAL);
BEGIN
  IF gMenuOpen AND (gMenuSel < gMenuCount) AND (item < gMenu[gMenuSel].nItems) THEN gItemSel := item END
END MenuItemSelect;

PROCEDURE MenuItemNext (): BOOLEAN;
BEGIN
  IF gMenuOpen AND (gMenuSel < gMenuCount) AND (gItemSel + 1 < gMenu[gMenuSel].nItems) THEN
    INC(gItemSel); RETURN TRUE
  END;
  RETURN FALSE
END MenuItemNext;

PROCEDURE MenuItemPrev (): BOOLEAN;
BEGIN
  IF gMenuOpen AND (gItemSel > 0) THEN DEC(gItemSel); RETURN TRUE END;
  RETURN FALSE
END MenuItemPrev;

(* ---- events ---- *)
PROCEDURE PostEvent (kind: EventKind; menu, item: CARDINAL; ch: CHAR);
  VAR t: CARDINAL;
BEGIN
  IF gEvLen >= MaxEvents THEN RETURN END;          (* full: drop the newest *)
  t := (gEvHead + gEvLen) MOD MaxEvents;
  gEv[t].kind := kind; gEv[t].menu := menu; gEv[t].item := item; gEv[t].ch := ch;
  INC(gEvLen)
END PostEvent;

PROCEDURE NextEvent (VAR e: Event): BOOLEAN;
BEGIN
  IF gEvLen = 0 THEN
    e.kind := EvNone; e.menu := 0; e.item := 0; e.ch := NUL;
    RETURN FALSE
  END;
  e.kind := gEv[gEvHead].kind;
  e.menu := gEv[gEvHead].menu;
  e.item := gEv[gEvHead].item;
  e.ch   := gEv[gEvHead].ch;
  gEvHead := (gEvHead + 1) MOD MaxEvents;
  DEC(gEvLen);
  RETURN TRUE
END NextEvent;

PROCEDURE HasEvent (): BOOLEAN; BEGIN RETURN gEvLen > 0 END HasEvent;
PROCEDURE ClearEvents; BEGIN gEvHead := 0; gEvLen := 0 END ClearEvents;

PROCEDURE HandleKey (key: CARDINAL; ch: CHAR): BOOLEAN;
  VAR moved: BOOLEAN;
BEGIN
  IF gMenuOpen THEN
    IF key = KeyUp THEN moved := MenuItemPrev(); RETURN TRUE
    ELSIF key = KeyDown THEN moved := MenuItemNext(); RETURN TRUE
    ELSIF key = KeyLeft THEN
      IF MenuPrev() THEN PostEvent(EvMenuMove, gMenuSel, 0, NUL) END; RETURN TRUE
    ELSIF key = KeyRight THEN
      IF MenuNext() THEN PostEvent(EvMenuMove, gMenuSel, 0, NUL) END; RETURN TRUE
    ELSIF key = KeyEnter THEN
      PostEvent(EvMenuItem, gMenuSel, gItemSel, NUL); MenuClose; RETURN TRUE
    ELSIF (key = KeyEsc) OR (key = KeyTab) THEN
      MenuClose; PostEvent(EvMenuClose, gMenuSel, 0, NUL); RETURN TRUE
    END;
    RETURN FALSE
  ELSE
    IF key = KeyLeft THEN
      IF MenuPrev() THEN PostEvent(EvMenuMove, gMenuSel, 0, NUL); RETURN TRUE END;
      RETURN FALSE
    ELSIF key = KeyRight THEN
      IF MenuNext() THEN PostEvent(EvMenuMove, gMenuSel, 0, NUL); RETURN TRUE END;
      RETURN FALSE
    ELSIF (key = KeyDown) OR (key = KeyEnter) THEN
      MenuOpen;
      IF gMenuOpen THEN PostEvent(EvMenuOpen, gMenuSel, 0, NUL); RETURN TRUE END;
      RETURN FALSE
    END;
    RETURN FALSE
  END
END HandleKey;

(* ---- text windows ---- *)
PROCEDURE WinOpen (VAR tw: TextWin; x, y, w, h: CARDINAL; fg, bg: Colour);
BEGIN
  tw.x := x; tw.y := y; tw.w := w; tw.h := h;
  tw.cx := 0; tw.cy := 0; tw.fg := fg; tw.bg := bg
END WinOpen;

PROCEDURE WinClear (VAR tw: TextWin);
  VAR r, c: CARDINAL;
BEGIN
  r := 0;
  WHILE r < tw.h DO
    c := 0;
    WHILE c < tw.w DO SetCell(tw.y + r, tw.x + c, ' ', tw.fg, tw.bg); INC(c) END;
    INC(r)
  END;
  tw.cx := 0; tw.cy := 0
END WinClear;

PROCEDURE WinBox (VAR tw: TextWin);
BEGIN Box(tw.x, tw.y, tw.w, tw.h, tw.fg, tw.bg) END WinBox;

PROCEDURE WinGotoXY (VAR tw: TextWin; col, row: CARDINAL);
BEGIN
  IF col < tw.w THEN tw.cx := col END;
  IF row < tw.h THEN tw.cy := row END
END WinGotoXY;

PROCEDURE WinPut (VAR tw: TextWin; ch: CHAR);
BEGIN
  IF ch = CHR(13) THEN tw.cx := 0
  ELSIF ch = CHR(10) THEN tw.cx := 0; IF tw.cy + 1 < tw.h THEN INC(tw.cy) END
  ELSE
    SetCell(tw.y + tw.cy, tw.x + tw.cx, ch, tw.fg, tw.bg);
    INC(tw.cx);
    IF tw.cx >= tw.w THEN
      tw.cx := 0;
      IF tw.cy + 1 < tw.h THEN INC(tw.cy) END
    END
  END
END WinPut;

PROCEDURE WinWrite (VAR tw: TextWin; s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # NUL) DO WinPut(tw, s[i]); INC(i) END
END WinWrite;

(* ---- input fields ---- *)
PROCEDURE FieldInit (VAR f: Field; x, y, width: CARDINAL; fg, bg: Colour);
BEGIN
  IF width < 1 THEN width := 1 END;
  f.x := x; f.y := y; f.width := width; f.len := 0; f.caret := 0;
  f.fg := fg; f.bg := bg; f.buf[0] := NUL
END FieldInit;

PROCEDURE FieldSet (VAR f: Field; s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (i < 255) AND (s[i] # NUL) DO f.buf[i] := s[i]; INC(i) END;
  f.buf[i] := NUL; f.len := i; f.caret := i
END FieldSet;

PROCEDURE FieldKey (VAR f: Field; ch: CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF ch = CHR(8) THEN                       (* backspace *)
    IF f.caret > 0 THEN
      i := f.caret - 1;
      WHILE i + 1 < f.len DO f.buf[i] := f.buf[i+1]; INC(i) END;
      DEC(f.len); DEC(f.caret); f.buf[f.len] := NUL;
      RETURN TRUE
    END;
    RETURN FALSE
  ELSIF ch >= ' ' THEN                      (* printable (incl. Unicode) *)
    IF (f.len + 1 < f.width) AND (f.len < 255) THEN
      i := f.len;
      WHILE i > f.caret DO f.buf[i] := f.buf[i-1]; DEC(i) END;
      f.buf[f.caret] := ch;
      INC(f.len); INC(f.caret); f.buf[f.len] := NUL;
      RETURN TRUE
    END;
    RETURN FALSE
  END;
  RETURN FALSE
END FieldKey;

PROCEDURE FieldText (f: Field; VAR s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i < f.len) AND (i < HIGH(s)) DO s[i] := f.buf[i]; INC(i) END;
  s[i] := NUL
END FieldText;

PROCEDURE FieldRender (VAR f: Field);
  VAR i: CARDINAL; cfg, cbg: Colour;
BEGIN
  i := 0;
  WHILE i < f.width DO
    IF i = f.caret THEN cfg := f.bg; cbg := f.fg     (* caret = inverse video *)
    ELSE cfg := f.fg; cbg := f.bg END;
    IF i < f.len THEN SetCell(f.y, f.x + i, f.buf[i], cfg, cbg)
    ELSE SetCell(f.y, f.x + i, ' ', cfg, cbg) END;
    INC(i)
  END
END FieldRender;

PROCEDURE FieldLeft (VAR f: Field): BOOLEAN;
BEGIN IF f.caret > 0 THEN DEC(f.caret); RETURN TRUE END; RETURN FALSE END FieldLeft;

PROCEDURE FieldRight (VAR f: Field): BOOLEAN;
BEGIN IF f.caret < f.len THEN INC(f.caret); RETURN TRUE END; RETURN FALSE END FieldRight;

PROCEDURE FieldHome (VAR f: Field); BEGIN f.caret := 0 END FieldHome;
PROCEDURE FieldEnd (VAR f: Field); BEGIN f.caret := f.len END FieldEnd;

PROCEDURE FieldDelete (VAR f: Field): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF f.caret < f.len THEN
    i := f.caret;
    WHILE i + 1 < f.len DO f.buf[i] := f.buf[i+1]; INC(i) END;
    DEC(f.len); f.buf[f.len] := NUL;
    RETURN TRUE
  END;
  RETURN FALSE
END FieldDelete;

PROCEDURE FieldClear (VAR f: Field);
BEGIN f.len := 0; f.caret := 0; f.buf[0] := NUL END FieldClear;

PROCEDURE FieldCaret (f: Field): CARDINAL; BEGIN RETURN f.caret END FieldCaret;
PROCEDURE FieldLen (f: Field): CARDINAL; BEGIN RETURN f.len END FieldLen;

PROCEDURE FieldHandleKey (VAR f: Field; key: CARDINAL; ch: CHAR): BOOLEAN;
BEGIN
  IF key = KeyChar THEN
    IF FieldKey(f, ch) THEN PostEvent(EvFieldChange, 0, 0, ch); RETURN TRUE END;
    RETURN FALSE
  ELSIF key = KeyBack THEN
    IF FieldKey(f, CHR(8)) THEN PostEvent(EvFieldChange, 0, 0, CHR(8)); RETURN TRUE END;
    RETURN FALSE
  ELSIF key = KeyDelete THEN
    IF FieldDelete(f) THEN PostEvent(EvFieldChange, 0, 0, NUL); RETURN TRUE END;
    RETURN FALSE
  ELSIF key = KeyLeft THEN RETURN FieldLeft(f)
  ELSIF key = KeyRight THEN RETURN FieldRight(f)
  ELSIF key = KeyHome THEN FieldHome(f); RETURN TRUE
  ELSIF key = KeyEnd THEN FieldEnd(f); RETURN TRUE
  ELSIF key = KeyEnter THEN PostEvent(EvSubmit, 0, 0, NUL); RETURN TRUE
  ELSIF key = KeyEsc THEN PostEvent(EvCancel, 0, 0, NUL); RETURN TRUE
  END;
  RETURN FALSE
END FieldHandleKey;

BEGIN
  gCols := 80; gRows := 25; gCurX := 0; gCurY := 0;
  gCurFg := White; gCurBg := Black;
  gMenuCount := 0; gMenuSel := 0; gMenuOpen := FALSE; gItemSel := 0;
  gMenuFocused := TRUE;          (* default on, for consumers that don't manage focus *)
  gSaveValid := FALSE;
  gEvHead := 0; gEvLen := 0
END Terminal.
