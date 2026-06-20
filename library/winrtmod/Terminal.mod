IMPLEMENTATION MODULE Terminal;

(* S1 (PaneShell): instanced. All per-instance state lives in a heap-allocated
   InstRec (so the module's static sections stay tiny and two grids can coexist
   — the §0.4 heap mandate). A module-global `gActive` points at the current
   instance; every singleton procedure operates on `gActive^`. An eagerly-built
   default instance (`gDefault`) backs the legacy singleton API, so `gActive` is
   never NIL and existing callers behave exactly as before. Create/Use/Free
   manage explicit instances; the CellxxxOf accessors read a given instance
   regardless of which is current. *)

FROM SYSTEM IMPORT ADDRESS, CAST, SIZE;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;

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

  (* one instance = the whole text-grid model + menu + event state *)
  InstRec = RECORD
    gChar: ARRAY [0..MaxRows-1], [0..MaxCols-1] OF CHAR;
    gFg:   ARRAY [0..MaxRows-1], [0..MaxCols-1] OF Colour;
    gBg:   ARRAY [0..MaxRows-1], [0..MaxCols-1] OF Colour;
    gCols, gRows, gCurX, gCurY: CARDINAL;
    gCurFg, gCurBg: Colour;

    gMenu: ARRAY [0..MaxMenu-1] OF MenuRec;
    gMenuCount, gMenuSel: CARDINAL;
    gMenuOpen: BOOLEAN;
    gMenuFocused: BOOLEAN;        (* highlight the selected title only when focused *)
    gItemSel: CARDINAL;           (* highlighted item in the open drop-down *)

    (* cells the open drop-down covers, saved so MenuClose can restore them *)
    gSaveChar: ARRAY [0..PopMaxH-1], [0..PopMaxW-1] OF CHAR;
    gSaveFg:   ARRAY [0..PopMaxH-1], [0..PopMaxW-1] OF Colour;
    gSaveBg:   ARRAY [0..PopMaxH-1], [0..PopMaxW-1] OF Colour;
    gSaveX, gSaveY, gSaveW, gSaveH: CARDINAL;
    gSaveValid: BOOLEAN;

    (* event ring buffer *)
    gEv: ARRAY [0..MaxEvents-1] OF Event;
    gEvHead, gEvLen: CARDINAL;
  END;
  InstPtr = POINTER TO InstRec;

VAR
  gActive:  InstPtr;             (* the current instance (never NIL) *)
  gDefault: InstPtr;             (* backs the legacy singleton API; never freed *)

(* ---- pure string helpers (instance-independent) ---- *)
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

(* ---- instance lifecycle ---- *)
PROCEDURE ClearGrid (p: InstPtr);          (* fill p^'s grid with spaces in its colours; home cursor *)
  VAR r, c: CARDINAL;
BEGIN
  r := 0;
  WHILE r < p^.gRows DO
    c := 0;
    WHILE c < p^.gCols DO
      p^.gChar[r][c] := ' '; p^.gFg[r][c] := p^.gCurFg; p^.gBg[r][c] := p^.gCurBg;
      INC(c)
    END;
    INC(r)
  END;
  p^.gCurX := 0; p^.gCurY := 0
END ClearGrid;

PROCEDURE ResetInst (p: InstPtr; cols, rows: CARDINAL);  (* size + clear + reset all state *)
BEGIN
  IF cols > MaxCols THEN cols := MaxCols ELSIF cols < 1 THEN cols := 1 END;
  IF rows > MaxRows THEN rows := MaxRows ELSIF rows < 1 THEN rows := 1 END;
  p^.gCols := cols; p^.gRows := rows;
  p^.gCurFg := White; p^.gCurBg := Black;
  p^.gCurX := 0; p^.gCurY := 0;
  p^.gMenuCount := 0; p^.gMenuSel := 0; p^.gMenuOpen := FALSE; p^.gItemSel := 0;
  p^.gMenuFocused := TRUE;        (* default on, for consumers that don't manage focus *)
  p^.gSaveValid := FALSE;
  p^.gEvHead := 0; p^.gEvLen := 0;
  ClearGrid(p)
END ResetInst;

PROCEDURE NewInst (cols, rows: CARDINAL): InstPtr;
  VAR a: ADDRESS; p: InstPtr;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(InstRec));
  p := CAST(InstPtr, a);
  ResetInst(p, cols, rows);
  RETURN p
END NewInst;

PROCEDURE Create (cols, rows: CARDINAL): Instance;
BEGIN
  RETURN CAST(Instance, NewInst(cols, rows))
END Create;

PROCEDURE Use (i: Instance);
BEGIN
  IF i = NIL THEN gActive := gDefault ELSE gActive := CAST(InstPtr, i) END
END Use;

PROCEDURE Free (VAR i: Instance);
  VAR p: InstPtr;
BEGIN
  IF i # NIL THEN
    p := CAST(InstPtr, i);
    IF p = gActive THEN gActive := gDefault END;
    IF p # gDefault THEN DEALLOCATE(i, SIZE(InstRec)) END;
    i := NIL
  END
END Free;

PROCEDURE CellCharOf (i: Instance; col, row: CARDINAL): CHAR;
  VAR p: InstPtr;
BEGIN
  IF i = NIL THEN RETURN ' ' END;
  p := CAST(InstPtr, i);
  IF (row < p^.gRows) AND (col < p^.gCols) THEN RETURN p^.gChar[row][col] END;
  RETURN ' '
END CellCharOf;

PROCEDURE CellFgOf (i: Instance; col, row: CARDINAL): Colour;
  VAR p: InstPtr;
BEGIN
  IF i = NIL THEN RETURN White END;
  p := CAST(InstPtr, i);
  IF (row < p^.gRows) AND (col < p^.gCols) THEN RETURN p^.gFg[row][col] END;
  RETURN p^.gCurFg
END CellFgOf;

PROCEDURE CellBgOf (i: Instance; col, row: CARDINAL): Colour;
  VAR p: InstPtr;
BEGIN
  IF i = NIL THEN RETURN Black END;
  p := CAST(InstPtr, i);
  IF (row < p^.gRows) AND (col < p^.gCols) THEN RETURN p^.gBg[row][col] END;
  RETURN p^.gCurBg
END CellBgOf;

(* ---- the singleton API: every proc below operates on gActive^ ---- *)
PROCEDURE SetCell (row, col: CARDINAL; ch: CHAR; fg, bg: Colour);
BEGIN
  IF (row < gActive^.gRows) AND (col < gActive^.gCols) THEN
    gActive^.gChar[row][col] := ch; gActive^.gFg[row][col] := fg; gActive^.gBg[row][col] := bg
  END
END SetCell;

PROCEDURE Cols (): CARDINAL; BEGIN RETURN gActive^.gCols END Cols;
PROCEDURE Rows (): CARDINAL; BEGIN RETURN gActive^.gRows END Rows;
PROCEDURE Fg (): Colour; BEGIN RETURN gActive^.gCurFg END Fg;
PROCEDURE Bg (): Colour; BEGIN RETURN gActive^.gCurBg END Bg;
PROCEDURE WhereX (): CARDINAL; BEGIN RETURN gActive^.gCurX END WhereX;
PROCEDURE WhereY (): CARDINAL; BEGIN RETURN gActive^.gCurY END WhereY;

PROCEDURE SetColour (fg, bg: Colour); BEGIN gActive^.gCurFg := fg; gActive^.gCurBg := bg END SetColour;

PROCEDURE GotoXY (col, row: CARDINAL);
BEGIN
  IF col < gActive^.gCols THEN gActive^.gCurX := col END;
  IF row < gActive^.gRows THEN gActive^.gCurY := row END
END GotoXY;

PROCEDURE Clear;
BEGIN
  ClearGrid(gActive)
END Clear;

PROCEDURE Init (cols, rows: CARDINAL);
BEGIN
  ResetInst(gActive, cols, rows)
END Init;

(* Resize the active grid in place WITHOUT clearing existing cells — for
   reflow-on-resize (the window grew/shrank). A grow blanks only the
   newly-exposed region (the buffer past the old active size is uninitialised);
   content within the overlap is preserved and the caller re-renders. *)
PROCEDURE SetSize (cols, rows: CARDINAL);
  VAR p: InstPtr; r, c, oldC, oldR: CARDINAL;
BEGIN
  p := gActive;
  IF cols > MaxCols THEN cols := MaxCols ELSIF cols < 1 THEN cols := 1 END;
  IF rows > MaxRows THEN rows := MaxRows ELSIF rows < 1 THEN rows := 1 END;
  oldC := p^.gCols; oldR := p^.gRows;
  p^.gCols := cols; p^.gRows := rows;            (* set first: SetCell guards on the active bounds *)
  r := 0;
  WHILE r < rows DO
    c := 0;
    WHILE c < cols DO
      IF (r >= oldR) OR (c >= oldC) THEN SetCell(r, c, ' ', p^.gCurFg, p^.gCurBg) END;
      INC(c)
    END;
    INC(r)
  END;
  IF p^.gCurX >= cols THEN p^.gCurX := cols - 1 END;
  IF p^.gCurY >= rows THEN p^.gCurY := rows - 1 END
END SetSize;

PROCEDURE ScrollUp;
  VAR r, c: CARDINAL;
BEGIN
  r := 0;
  WHILE r < gActive^.gRows - 1 DO
    c := 0;
    WHILE c < gActive^.gCols DO
      gActive^.gChar[r][c] := gActive^.gChar[r+1][c];
      gActive^.gFg[r][c]   := gActive^.gFg[r+1][c];
      gActive^.gBg[r][c]   := gActive^.gBg[r+1][c];
      INC(c)
    END;
    INC(r)
  END;
  c := 0;
  WHILE c < gActive^.gCols DO SetCell(gActive^.gRows-1, c, ' ', gActive^.gCurFg, gActive^.gCurBg); INC(c) END
END ScrollUp;

PROCEDURE NewLineDown;
BEGIN
  INC(gActive^.gCurY);
  IF gActive^.gCurY >= gActive^.gRows THEN ScrollUp; gActive^.gCurY := gActive^.gRows - 1 END
END NewLineDown;

PROCEDURE Put (ch: CHAR);
BEGIN
  IF ch = CHR(13) THEN gActive^.gCurX := 0
  ELSIF ch = CHR(10) THEN gActive^.gCurX := 0; NewLineDown
  ELSE
    SetCell(gActive^.gCurY, gActive^.gCurX, ch, gActive^.gCurFg, gActive^.gCurBg);
    INC(gActive^.gCurX);
    IF gActive^.gCurX >= gActive^.gCols THEN gActive^.gCurX := 0; NewLineDown END
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
  WHILE (i <= HIGH(s)) AND (s[i] # NUL) AND (col + i < gActive^.gCols) DO
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
  IF (row < gActive^.gRows) AND (col < gActive^.gCols) THEN RETURN gActive^.gChar[row][col] END;
  RETURN ' '
END CellChar;

PROCEDURE CellFg (col, row: CARDINAL): Colour;
BEGIN
  IF (row < gActive^.gRows) AND (col < gActive^.gCols) THEN RETURN gActive^.gFg[row][col] END;
  RETURN gActive^.gCurFg
END CellFg;

PROCEDURE CellBg (col, row: CARDINAL): Colour;
BEGIN
  IF (row < gActive^.gRows) AND (col < gActive^.gCols) THEN RETURN gActive^.gBg[row][col] END;
  RETURN gActive^.gCurBg
END CellBg;

(* ---- status bar ---- *)
PROCEDURE SetStatusColour (s: ARRAY OF CHAR; fg, bg: Colour);
  VAR c, n, row: CARDINAL;
BEGIN
  row := gActive^.gRows - 1;
  n := StrLen(s);
  c := 0;
  WHILE c < gActive^.gCols DO
    IF c < n THEN SetCell(row, c, s[c], fg, bg)
    ELSE SetCell(row, c, ' ', fg, bg) END;
    INC(c)
  END
END SetStatusColour;

PROCEDURE SetStatus (s: ARRAY OF CHAR);
BEGIN SetStatusColour(s, White, Navy) END SetStatus;

(* ---- menu bar ---- *)
PROCEDURE MenuClear;
BEGIN gActive^.gMenuCount := 0; gActive^.gMenuSel := 0; gActive^.gMenuOpen := FALSE; gActive^.gSaveValid := FALSE END MenuClear;

PROCEDURE MenuCount (): CARDINAL; BEGIN RETURN gActive^.gMenuCount END MenuCount;
PROCEDURE MenuSelected (): CARDINAL; BEGIN RETURN gActive^.gMenuSel END MenuSelected;

PROCEDURE MenuAdd (title: ARRAY OF CHAR);
BEGIN
  IF gActive^.gMenuCount >= MaxMenu THEN RETURN END;
  CopyStr(title, gActive^.gMenu[gActive^.gMenuCount].title, TitleHi);
  gActive^.gMenu[gActive^.gMenuCount].enabled := TRUE;
  gActive^.gMenu[gActive^.gMenuCount].nItems := 0;
  INC(gActive^.gMenuCount)
END MenuAdd;

(* lay out each title's left column (and so the drop-down origin) without drawing *)
PROCEDURE MenuLayout;
  VAR i, col: CARDINAL;
BEGIN
  col := 1; i := 0;
  WHILE i < gActive^.gMenuCount DO
    gActive^.gMenu[i].colAt := col;
    INC(col);                              (* leading pad *)
    col := col + StrLen(gActive^.gMenu[i].title);   (* title *)
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
  WHILE i < gActive^.gMenu[gActive^.gMenuSel].nItems DO
    tl := StrLen(gActive^.gMenu[gActive^.gMenuSel].items[i]);
    IF tl > maxw THEN maxw := tl END;
    INC(i)
  END;
  pw := maxw + 4;                          (* border (2) + one pad each side *)
  IF pw < 4 THEN pw := 4 END;
  IF pw > PopMaxW THEN pw := PopMaxW END;
  ph := gActive^.gMenu[gActive^.gMenuSel].nItems + 2;        (* top + bottom border *)
  IF ph > PopMaxH THEN ph := PopMaxH END;
  px := gActive^.gMenu[gActive^.gMenuSel].colAt;
  py := 1;
  IF px + pw > gActive^.gCols THEN
    IF pw <= gActive^.gCols THEN px := gActive^.gCols - pw ELSE px := 0 END
  END
END PopupGeom;

PROCEDURE DrawDropdown;
  VAR px, py, pw, ph, i, j, tl, col: CARDINAL; fg, bg: Colour;
BEGIN
  PopupGeom(px, py, pw, ph);
  Box(px, py, pw, ph, Black, Silver);
  Fill(px + 1, py + 1, pw - 2, ph - 2, ' ', Black, Silver);
  i := 0;
  WHILE i < gActive^.gMenu[gActive^.gMenuSel].nItems DO
    IF i = gActive^.gItemSel THEN fg := White; bg := Navy ELSE fg := Black; bg := Silver END;
    col := px + 1;
    SetCell(py + 1 + i, col, ' ', fg, bg); INC(col);
    tl := StrLen(gActive^.gMenu[gActive^.gMenuSel].items[i]); j := 0;
    WHILE (j < tl) AND (col < px + pw - 1) DO
      SetCell(py + 1 + i, col, gActive^.gMenu[gActive^.gMenuSel].items[i][j], fg, bg);
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
  WHILE i < gActive^.gMenuCount DO
    IF (col >= gActive^.gMenu[i].colAt) AND (col < gActive^.gMenu[i].colAt + StrLen(gActive^.gMenu[i].title) + 2) THEN
      RETURN i
    END;
    INC(i)
  END;
  RETURN MAX(CARDINAL)
END MenuBarHit;

PROCEDURE MenuPopupHit (col, row: CARDINAL): CARDINAL;
  VAR px, py, pw, ph: CARDINAL;
BEGIN
  IF NOT gActive^.gMenuOpen THEN RETURN MAX(CARDINAL) END;
  PopupGeom(px, py, pw, ph);
  IF (row >= py + 1) AND (row <= py + gActive^.gMenu[gActive^.gMenuSel].nItems) AND
     (col >= px) AND (col < px + pw) THEN
    RETURN row - (py + 1)
  END;
  RETURN MAX(CARDINAL)
END MenuPopupHit;

PROCEDURE MenuClose;
  VAR r, c: CARDINAL;
BEGIN
  IF NOT gActive^.gMenuOpen THEN RETURN END;
  gActive^.gMenuOpen := FALSE;
  IF gActive^.gSaveValid THEN
    r := 0;
    WHILE r < gActive^.gSaveH DO
      c := 0;
      WHILE c < gActive^.gSaveW DO
        SetCell(gActive^.gSaveY + r, gActive^.gSaveX + c, gActive^.gSaveChar[r][c], gActive^.gSaveFg[r][c], gActive^.gSaveBg[r][c]);
        INC(c)
      END;
      INC(r)
    END;
    gActive^.gSaveValid := FALSE
  END
END MenuClose;

PROCEDURE MenuOpen;
  VAR px, py, pw, ph, r, c: CARDINAL;
BEGIN
  IF gActive^.gMenuOpen THEN RETURN END;
  IF gActive^.gMenuSel >= gActive^.gMenuCount THEN RETURN END;
  IF NOT gActive^.gMenu[gActive^.gMenuSel].enabled THEN RETURN END;
  IF gActive^.gMenu[gActive^.gMenuSel].nItems = 0 THEN RETURN END;
  MenuLayout;
  PopupGeom(px, py, pw, ph);
  gActive^.gSaveX := px; gActive^.gSaveY := py; gActive^.gSaveW := pw; gActive^.gSaveH := ph;
  r := 0;
  WHILE r < ph DO
    c := 0;
    WHILE c < pw DO
      gActive^.gSaveChar[r][c] := CellChar(px + c, py + r);
      gActive^.gSaveFg[r][c]   := CellFg(px + c, py + r);
      gActive^.gSaveBg[r][c]   := CellBg(px + c, py + r);
      INC(c)
    END;
    INC(r)
  END;
  gActive^.gSaveValid := TRUE;
  gActive^.gItemSel := 0;
  gActive^.gMenuOpen := TRUE
END MenuOpen;

PROCEDURE MenuSetFocus (on: BOOLEAN);
BEGIN gActive^.gMenuFocused := on END MenuSetFocus;

PROCEDURE MenuRender;
  VAR i, col, j, tl: CARDINAL; fg, bg: Colour;
BEGIN
  MenuLayout;
  col := 0;
  WHILE col < gActive^.gCols DO SetCell(0, col, ' ', Black, Silver); INC(col) END;
  i := 0;
  WHILE i < gActive^.gMenuCount DO
    IF NOT gActive^.gMenu[i].enabled THEN fg := Gray; bg := Silver
    ELSIF (i = gActive^.gMenuSel) AND gActive^.gMenuFocused THEN fg := White; bg := Navy
    ELSE fg := Black; bg := Silver END;
    col := gActive^.gMenu[i].colAt;
    IF col < gActive^.gCols THEN SetCell(0, col, ' ', fg, bg) END;
    INC(col);
    tl := StrLen(gActive^.gMenu[i].title); j := 0;
    WHILE (j < tl) AND (col < gActive^.gCols) DO SetCell(0, col, gActive^.gMenu[i].title[j], fg, bg); INC(col); INC(j) END;
    IF col < gActive^.gCols THEN SetCell(0, col, ' ', fg, bg) END;
    INC(i)
  END;
  IF gActive^.gMenuOpen THEN DrawDropdown END
END MenuRender;

(* move the highlight, carrying an open drop-down with it *)
PROCEDURE MoveSelTo (index: CARDINAL);
  VAR wasOpen: BOOLEAN;
BEGIN
  wasOpen := gActive^.gMenuOpen;
  IF wasOpen THEN MenuClose END;
  gActive^.gMenuSel := index;
  IF wasOpen THEN MenuOpen END
END MoveSelTo;

PROCEDURE MenuSelect (index: CARDINAL);
BEGIN IF index < gActive^.gMenuCount THEN MoveSelTo(index) END END MenuSelect;

PROCEDURE MenuNext (): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF gActive^.gMenuCount = 0 THEN RETURN FALSE END;
  i := gActive^.gMenuSel;
  WHILE i + 1 < gActive^.gMenuCount DO
    INC(i);
    IF gActive^.gMenu[i].enabled THEN MoveSelTo(i); RETURN TRUE END
  END;
  RETURN FALSE
END MenuNext;

PROCEDURE MenuPrev (): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF (gActive^.gMenuCount = 0) OR (gActive^.gMenuSel = 0) THEN RETURN FALSE END;
  i := gActive^.gMenuSel;
  WHILE i > 0 DO
    DEC(i);
    IF gActive^.gMenu[i].enabled THEN MoveSelTo(i); RETURN TRUE END
  END;
  RETURN FALSE
END MenuPrev;

PROCEDURE MenuTitle (index: CARDINAL; VAR s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  IF index < gActive^.gMenuCount THEN
    WHILE (i < HIGH(s)) AND (gActive^.gMenu[index].title[i] # NUL) DO s[i] := gActive^.gMenu[index].title[i]; INC(i) END
  END;
  s[i] := NUL
END MenuTitle;

PROCEDURE MenuSetTitle (index: CARDINAL; title: ARRAY OF CHAR);
BEGIN IF index < gActive^.gMenuCount THEN CopyStr(title, gActive^.gMenu[index].title, TitleHi) END END MenuSetTitle;

(* field-by-field copy of one menu slot (avoids whole-record-with-array assign) *)
PROCEDURE MenuSlotCopy (dst, src: CARDINAL);
  VAR i, j: CARDINAL;
BEGIN
  i := 0;
  WHILE i <= TitleHi DO gActive^.gMenu[dst].title[i] := gActive^.gMenu[src].title[i]; INC(i) END;
  gActive^.gMenu[dst].enabled := gActive^.gMenu[src].enabled;
  gActive^.gMenu[dst].nItems := gActive^.gMenu[src].nItems;
  i := 0;
  WHILE i < MaxItems DO
    j := 0;
    WHILE j <= TitleHi DO gActive^.gMenu[dst].items[i][j] := gActive^.gMenu[src].items[i][j]; INC(j) END;
    INC(i)
  END
END MenuSlotCopy;

PROCEDURE MenuInsert (index: CARDINAL; title: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  IF gActive^.gMenuCount >= MaxMenu THEN RETURN END;
  IF index > gActive^.gMenuCount THEN index := gActive^.gMenuCount END;
  IF gActive^.gMenuOpen THEN MenuClose END;
  i := gActive^.gMenuCount;
  WHILE i > index DO MenuSlotCopy(i, i - 1); DEC(i) END;
  CopyStr(title, gActive^.gMenu[index].title, TitleHi);
  gActive^.gMenu[index].enabled := TRUE;
  gActive^.gMenu[index].nItems := 0;
  INC(gActive^.gMenuCount);
  IF gActive^.gMenuSel >= gActive^.gMenuCount THEN gActive^.gMenuSel := gActive^.gMenuCount - 1 END
END MenuInsert;

PROCEDURE MenuRemove (index: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  IF index >= gActive^.gMenuCount THEN RETURN END;
  IF gActive^.gMenuOpen THEN MenuClose END;
  i := index;
  WHILE i + 1 < gActive^.gMenuCount DO MenuSlotCopy(i, i + 1); INC(i) END;
  DEC(gActive^.gMenuCount);
  IF gActive^.gMenuCount = 0 THEN gActive^.gMenuSel := 0
  ELSIF gActive^.gMenuSel >= gActive^.gMenuCount THEN gActive^.gMenuSel := gActive^.gMenuCount - 1 END
END MenuRemove;

PROCEDURE MenuEnable (index: CARDINAL; on: BOOLEAN);
BEGIN IF index < gActive^.gMenuCount THEN gActive^.gMenu[index].enabled := on END END MenuEnable;

PROCEDURE MenuEnabled (index: CARDINAL): BOOLEAN;
BEGIN IF index < gActive^.gMenuCount THEN RETURN gActive^.gMenu[index].enabled END; RETURN FALSE END MenuEnabled;

(* ---- drop-down items ---- *)
PROCEDURE MenuAddItem (menu: CARDINAL; text: ARRAY OF CHAR);
BEGIN
  IF (menu < gActive^.gMenuCount) AND (gActive^.gMenu[menu].nItems < MaxItems) THEN
    CopyStr(text, gActive^.gMenu[menu].items[gActive^.gMenu[menu].nItems], TitleHi);
    INC(gActive^.gMenu[menu].nItems)
  END
END MenuAddItem;

PROCEDURE MenuItemCount (menu: CARDINAL): CARDINAL;
BEGIN IF menu < gActive^.gMenuCount THEN RETURN gActive^.gMenu[menu].nItems END; RETURN 0 END MenuItemCount;

PROCEDURE MenuItemText (menu, item: CARDINAL; VAR s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  IF (menu < gActive^.gMenuCount) AND (item < gActive^.gMenu[menu].nItems) THEN
    WHILE (i < HIGH(s)) AND (gActive^.gMenu[menu].items[item][i] # NUL) DO
      s[i] := gActive^.gMenu[menu].items[item][i]; INC(i)
    END
  END;
  s[i] := NUL
END MenuItemText;

PROCEDURE MenuSetItem (menu, item: CARDINAL; text: ARRAY OF CHAR);
BEGIN
  IF (menu < gActive^.gMenuCount) AND (item < gActive^.gMenu[menu].nItems) THEN
    CopyStr(text, gActive^.gMenu[menu].items[item], TitleHi)
  END
END MenuSetItem;

PROCEDURE MenuClearItems (menu: CARDINAL);
BEGIN IF menu < gActive^.gMenuCount THEN gActive^.gMenu[menu].nItems := 0 END END MenuClearItems;

PROCEDURE MenuIsOpen (): BOOLEAN; BEGIN RETURN gActive^.gMenuOpen END MenuIsOpen;
PROCEDURE MenuItemSelected (): CARDINAL; BEGIN RETURN gActive^.gItemSel END MenuItemSelected;

PROCEDURE MenuItemSelect (item: CARDINAL);
BEGIN
  IF gActive^.gMenuOpen AND (gActive^.gMenuSel < gActive^.gMenuCount) AND (item < gActive^.gMenu[gActive^.gMenuSel].nItems) THEN gActive^.gItemSel := item END
END MenuItemSelect;

PROCEDURE MenuItemNext (): BOOLEAN;
BEGIN
  IF gActive^.gMenuOpen AND (gActive^.gMenuSel < gActive^.gMenuCount) AND (gActive^.gItemSel + 1 < gActive^.gMenu[gActive^.gMenuSel].nItems) THEN
    INC(gActive^.gItemSel); RETURN TRUE
  END;
  RETURN FALSE
END MenuItemNext;

PROCEDURE MenuItemPrev (): BOOLEAN;
BEGIN
  IF gActive^.gMenuOpen AND (gActive^.gItemSel > 0) THEN DEC(gActive^.gItemSel); RETURN TRUE END;
  RETURN FALSE
END MenuItemPrev;

(* ---- events ---- *)
PROCEDURE PostEvent (kind: EventKind; menu, item: CARDINAL; ch: CHAR);
  VAR t: CARDINAL;
BEGIN
  IF gActive^.gEvLen >= MaxEvents THEN RETURN END;          (* full: drop the newest *)
  t := (gActive^.gEvHead + gActive^.gEvLen) MOD MaxEvents;
  gActive^.gEv[t].kind := kind; gActive^.gEv[t].menu := menu; gActive^.gEv[t].item := item; gActive^.gEv[t].ch := ch;
  INC(gActive^.gEvLen)
END PostEvent;

PROCEDURE NextEvent (VAR e: Event): BOOLEAN;
BEGIN
  IF gActive^.gEvLen = 0 THEN
    e.kind := EvNone; e.menu := 0; e.item := 0; e.ch := NUL;
    RETURN FALSE
  END;
  e.kind := gActive^.gEv[gActive^.gEvHead].kind;
  e.menu := gActive^.gEv[gActive^.gEvHead].menu;
  e.item := gActive^.gEv[gActive^.gEvHead].item;
  e.ch   := gActive^.gEv[gActive^.gEvHead].ch;
  gActive^.gEvHead := (gActive^.gEvHead + 1) MOD MaxEvents;
  DEC(gActive^.gEvLen);
  RETURN TRUE
END NextEvent;

PROCEDURE HasEvent (): BOOLEAN; BEGIN RETURN gActive^.gEvLen > 0 END HasEvent;
PROCEDURE ClearEvents; BEGIN gActive^.gEvHead := 0; gActive^.gEvLen := 0 END ClearEvents;

PROCEDURE HandleKey (key: CARDINAL; ch: CHAR): BOOLEAN;
  VAR moved: BOOLEAN;
BEGIN
  IF gActive^.gMenuOpen THEN
    IF key = KeyUp THEN moved := MenuItemPrev(); RETURN TRUE
    ELSIF key = KeyDown THEN moved := MenuItemNext(); RETURN TRUE
    ELSIF key = KeyLeft THEN
      IF MenuPrev() THEN PostEvent(EvMenuMove, gActive^.gMenuSel, 0, NUL) END; RETURN TRUE
    ELSIF key = KeyRight THEN
      IF MenuNext() THEN PostEvent(EvMenuMove, gActive^.gMenuSel, 0, NUL) END; RETURN TRUE
    ELSIF key = KeyEnter THEN
      PostEvent(EvMenuItem, gActive^.gMenuSel, gActive^.gItemSel, NUL); MenuClose; RETURN TRUE
    ELSIF (key = KeyEsc) OR (key = KeyTab) THEN
      MenuClose; PostEvent(EvMenuClose, gActive^.gMenuSel, 0, NUL); RETURN TRUE
    END;
    RETURN FALSE
  ELSE
    IF key = KeyLeft THEN
      IF MenuPrev() THEN PostEvent(EvMenuMove, gActive^.gMenuSel, 0, NUL); RETURN TRUE END;
      RETURN FALSE
    ELSIF key = KeyRight THEN
      IF MenuNext() THEN PostEvent(EvMenuMove, gActive^.gMenuSel, 0, NUL); RETURN TRUE END;
      RETURN FALSE
    ELSIF (key = KeyDown) OR (key = KeyEnter) THEN
      MenuOpen;
      IF gActive^.gMenuOpen THEN PostEvent(EvMenuOpen, gActive^.gMenuSel, 0, NUL); RETURN TRUE END;
      RETURN FALSE
    END;
    RETURN FALSE
  END
END HandleKey;

(* ---- text windows (caller-owned TextWin; grid writes go through the current instance) ---- *)
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

(* ---- input fields (caller-owned Field; only FieldRender writes the grid) ---- *)
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
  gDefault := NewInst(80, 25);    (* eager default backs the legacy singleton API *)
  gActive  := gDefault
END Terminal.
