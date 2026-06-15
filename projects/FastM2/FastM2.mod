MODULE FastM2;
(*
 * FastM2 — a single-window Modula-2 IDE in the spirit of Turbo Pascal / QuickBASIC,
 * written in Modula-2 on the WindowsModula2 stack it edits. A menu bar (F10 or
 * Alt+letter, mouse-clickable), a syntax-highlighted editor over a TextRope buffer
 * with mouse + keyboard selection and clipboard, find/replace, goto-line, a source
 * re-indenter, a recent-files list, an output pane with a draggable split, and
 * one-key compile/run driving the `newm2` toolchain. Rendered with Direct2D via
 * TermRender (no GDI). The window resizes without scaling the text.
 *
 *   build: newm2 build projects/FastM2/FastM2.mod --library library
 *
 * Paths to the compiler/library/work files are CONSTs below — edit for your tree.
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  RunMessageLoop, Quit;
FROM TermRender IMPORT Startup, Attach, Resize, Paint;
FROM Terminal IMPORT Init, Cols, Rows, Clear, Fill, Box, WriteColAt, SetStatus, Colour,
  Black, Navy, Silver, Gray, White, Yellow, Aqua, Red, Teal,
  MenuClear, MenuAdd, MenuAddItem, MenuSelect, MenuRender, MenuSetFocus, MenuOpen, MenuClose,
  MenuIsOpen, MenuSelected, MenuItemSelect, MenuBarHit, MenuPopupHit,
  HandleKey, NextEvent, Event, EvMenuItem, EvMenuClose,
  KeyNone, KeyLeft, KeyRight, KeyUp, KeyDown, KeyEnter, KeyEsc, KeyTab;
FROM TextRope IMPORT Rope, Empty, FromString, Length, CharAt, Insert,
  DeleteRange, Append, Free;
FROM Clipboard IMPORT SetText, GetText;
FROM RunProg IMPORT PerformCommand, SyncExec, ExecFlagSet;
FROM Dialogs IMPORT OpenFile, SaveFile, Confirm;
FROM UI_WindowsAndMessaging IMPORT SetTimer, KillTimer;
FROM SYSTEM IMPORT ADRCARD;
IMPORT SeqFile, TextIO, IOResult, ChanConsts, IOConsts;
FROM WholeStr IMPORT CardToStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL, DWORD;

CONST
  CellW = 9; CellH = 18;                (* native pixels per character cell *)
  GutterW = 5;                         (* line-number gutter columns *)
  CodeX = GutterW;                     (* code starts after the gutter *)
  EdTop = 1;                           (* editor starts under the menu bar (row 0) *)
  MinCols = 30; MinRows = 12;          (* smallest usable grid on resize *)
  MaxRecent = 6;                       (* recent-files list length *)

  (* menu indices (top-level order, see SetupMenus) *)
  MFile = 0; MEdit = 1; MSearch = 2; MSource = 3; MBuild = 4; MHelp = 5;

  (* prompt modes for the status-line input *)
  PromNone = 0; PromFind = 1; PromRepFind = 2; PromRepTo = 3; PromGoto = 4;

  (* colours *)
  EdBg = Navy; CodeFg = Silver; KwFg = White; ComFg = Gray; StrFg = Yellow;
  NumFg = Aqua; GutFg = Teal; CurFg = Navy; CurBg = White;
  SelBg = 0264F78H; SelFg = White;     (* text selection *)
  MenuFg = Black; MenuBg = Silver; OutBg = Black; OutFg = Silver; ErrFg = Red;

  (* toolchain — EDIT THESE for your tree *)
  Compiler = "e:\NewModula2\target\debug\newm2-driver.exe";
  LibPath  = "e:\NewModula2\library";
  WorkFile = "e:\NewModula2\projects\FastM2\fastm2_work.mod";
  OutFile  = "e:\NewModula2\projects\FastM2\fastm2_out.txt";
  RecentStore = "e:\NewModula2\projects\FastM2\fastm2_recent.txt";

  WM_DESTROY = 2; WM_SIZE = 5; WM_PAINT = 15; WM_KILLFOCUS = 8;
  WM_KEYDOWN = 256; WM_KEYUP = 257; WM_CHAR = 258; WM_SYSKEYDOWN = 260;
  WM_TIMER = 113H; WM_MOUSEMOVE = 200H; WM_LBUTTONDOWN = 201H; WM_LBUTTONUP = 202H;
  WM_MOUSEWHEEL = 20AH; MK_LBUTTON = 1; WheelLines = 3;
  AboutTimer = 1; AboutSecs = 8000;
  VK_BACK = 08H; VK_TAB = 09H; VK_RETURN = 0DH; VK_SHIFT = 10H; VK_ESCAPE = 1BH;
  VK_PRIOR = 21H; VK_NEXT = 22H; VK_END = 23H; VK_HOME = 24H;
  VK_LEFT = 25H; VK_UP = 26H; VK_RIGHT = 27H; VK_DOWN = 28H;
  VK_DELETE = 2EH; VK_F2 = 71H; VK_F3 = 72H; VK_F5 = 74H; VK_F9 = 78H; VK_F10 = 79H;

VAR
  gWin:     Window;
  gDoc:     Rope;                      (* editor buffer *)
  gPos:     CARDINAL;                  (* cursor char index *)
  gAnchor:  CARDINAL;                  (* selection anchor *)
  gHasSel:  BOOLEAN;                   (* a selection exists (gAnchor..gPos) *)
  gTopLine, gLeft, gGoal: CARDINAL;    (* scroll + desired column *)
  gModified: BOOLEAN;
  gOut:     Rope;                      (* output pane buffer (read-only) *)
  gOutTop:  CARDINAL;
  gMsg:     ARRAY [0..63] OF CHAR;     (* transient status note *)
  gNL:      ARRAY [0..1] OF CHAR;
  gFile:    ARRAY [0..519] OF CHAR;    (* current file path (in/out of the dialogs) *)
  gMenuActive: BOOLEAN;                (* TRUE when the menu bar has focus *)
  gEatChar: BOOLEAN;                   (* swallow the WM_CHAR paired with a menu Enter/Tab *)
  gShiftDown: BOOLEAN;                 (* Shift held (for selection-extending moves) *)
  gDragging: BOOLEAN;                  (* mouse text-selection drag in progress *)
  gSplitDrag: BOOLEAN;                 (* dragging the editor/output divider *)
  gAbout: BOOLEAN;                     (* the About popup is showing *)
  gFollowCursor: BOOLEAN;              (* keep the cursor on screen (off during a wheel scroll) *)
  gSplitRows: CARDINAL;                (* desired editor rows (0 = auto 3:1) *)
  gFind, gReplace: ARRAY [0..127] OF CHAR;
  gPromptMode: CARDINAL;               (* PromNone..PromGoto *)
  gPromptBuf: ARRAY [0..127] OF CHAR; gPromptLen: CARDINAL;
  gRecent: ARRAY [0..MaxRecent-1] OF ARRAY [0..519] OF CHAR;
  gRecentCount: CARDINAL;
  gClip: ARRAY [0..65535] OF CHAR;     (* clipboard / selection staging buffer *)
  (* dynamic layout — recomputed by Layout from the live grid size *)
  gCols, gRows: CARDINAL;
  gReqCols, gReqRows: CARDINAL;
  gEdRows, gOutTitle, gOutTop2, gOutRows, gCodeW: CARDINAL;

(* ---- small string helpers --------------------------------------------- *)

PROCEDURE SLen (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END; RETURN i END SLen;

PROCEDURE SCopy (VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (i < HIGH(dst)) AND (src[i] # 0C) DO dst[i] := src[i]; INC(i) END;
  dst[i] := 0C
END SCopy;

PROCEDURE AppendStr (VAR dst: ARRAY OF CHAR; VAR pos: CARDINAL; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (pos < HIGH(dst)) DO
    dst[pos] := src[i]; INC(pos); INC(i)
  END;
  dst[pos] := 0C
END AppendStr;

(* the file name after the last path separator *)
PROCEDURE Basename (VAR full: ARRAY OF CHAR; VAR base: ARRAY OF CHAR);
  VAR i, last, n, j: CARDINAL;
BEGIN
  n := SLen(full); last := 0;
  FOR i := 0 TO n DO
    IF (i < n) AND ((full[i] = '\') OR (full[i] = '/')) THEN last := i + 1 END
  END;
  j := 0;
  WHILE (last < n) AND (j < HIGH(base)) DO base[j] := full[last]; INC(j); INC(last) END;
  base[j] := 0C
END Basename;

PROCEDURE ClearMsg; BEGIN gMsg[0] := 0C END ClearMsg;

(* ---- document geometry (scan-based, O(n)) ------------------------------ *)

PROCEDURE PosToLineCol (r: Rope; pos: CARDINAL; VAR line, col: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  line := 0; col := 0; i := 0;
  WHILE i < pos DO
    IF CharAt(r, i) = CHR(10) THEN INC(line); col := 0 ELSE INC(col) END; INC(i)
  END
END PosToLineCol;

PROCEDURE LineCount (r: Rope): CARDINAL;
  VAR i, len, n: CARDINAL;
BEGIN
  len := Length(r); n := 1; i := 0;
  WHILE i < len DO IF CharAt(r, i) = CHR(10) THEN INC(n) END; INC(i) END;
  RETURN n
END LineCount;

PROCEDURE LineStart (r: Rope; line: CARDINAL): CARDINAL;
  VAR i, len, ln: CARDINAL;
BEGIN
  IF line = 0 THEN RETURN 0 END;
  len := Length(r); ln := 0; i := 0;
  WHILE i < len DO
    IF CharAt(r, i) = CHR(10) THEN INC(ln); IF ln = line THEN RETURN i + 1 END END;
    INC(i)
  END;
  RETURN len
END LineStart;

PROCEDURE LineLen (r: Rope; line: CARDINAL): CARDINAL;
  VAR s, i, len: CARDINAL;
BEGIN
  s := LineStart(r, line); len := Length(r); i := s;
  WHILE (i < len) AND (CharAt(r, i) # CHR(10)) DO INC(i) END;
  RETURN i - s
END LineLen;

(* Copy line `line` of `r` into `buf` (truncated), return its length. *)
PROCEDURE GetLine (r: Rope; line: CARDINAL; VAR buf: ARRAY OF CHAR): CARDINAL;
  VAR s, n, i: CARDINAL;
BEGIN
  s := LineStart(r, line); n := LineLen(r, line);
  IF n > HIGH(buf) THEN n := HIGH(buf) END;
  FOR i := 0 TO n-1 DO buf[i] := CharAt(r, s + i) END;
  buf[n] := 0C; RETURN n
END GetLine;

(* ---- character classes + tokeniser ------------------------------------- *)

PROCEDURE IsAlpha (c: CHAR): BOOLEAN;
BEGIN RETURN ((c >= 'A') AND (c <= 'Z')) OR ((c >= 'a') AND (c <= 'z')) OR (c = '_') END IsAlpha;
PROCEDURE IsDigit (c: CHAR): BOOLEAN;
BEGIN RETURN (c >= '0') AND (c <= '9') END IsDigit;
PROCEDURE IsAlnum (c: CHAR): BOOLEAN;
BEGIN RETURN IsAlpha(c) OR IsDigit(c) END IsAlnum;
PROCEDURE Up (c: CHAR): CHAR;
BEGIN IF (c >= 'a') AND (c <= 'z') THEN RETURN CHR(ORD(c) - 32) ELSE RETURN c END END Up;

PROCEDURE WordEq (VAR s: ARRAY OF CHAR; a, b: CARDINAL; kw: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF (b - a) # SLen(kw) THEN RETURN FALSE END;
  i := 0; WHILE i < b - a DO IF s[a + i] # kw[i] THEN RETURN FALSE END; INC(i) END;
  RETURN TRUE
END WordEq;

PROCEDURE IsKeyword (VAR s: ARRAY OF CHAR; a, b: CARDINAL): BOOLEAN;
BEGIN
  RETURN WordEq(s,a,b,"MODULE") OR WordEq(s,a,b,"DEFINITION") OR WordEq(s,a,b,"IMPLEMENTATION")
      OR WordEq(s,a,b,"BEGIN") OR WordEq(s,a,b,"END") OR WordEq(s,a,b,"PROCEDURE")
      OR WordEq(s,a,b,"IF") OR WordEq(s,a,b,"THEN") OR WordEq(s,a,b,"ELSE") OR WordEq(s,a,b,"ELSIF")
      OR WordEq(s,a,b,"WHILE") OR WordEq(s,a,b,"DO") OR WordEq(s,a,b,"FOR") OR WordEq(s,a,b,"TO")
      OR WordEq(s,a,b,"BY") OR WordEq(s,a,b,"REPEAT") OR WordEq(s,a,b,"UNTIL") OR WordEq(s,a,b,"LOOP")
      OR WordEq(s,a,b,"CASE") OR WordEq(s,a,b,"OF") OR WordEq(s,a,b,"RECORD") OR WordEq(s,a,b,"ARRAY")
      OR WordEq(s,a,b,"POINTER") OR WordEq(s,a,b,"SET") OR WordEq(s,a,b,"VAR") OR WordEq(s,a,b,"CONST")
      OR WordEq(s,a,b,"TYPE") OR WordEq(s,a,b,"FROM") OR WordEq(s,a,b,"IMPORT") OR WordEq(s,a,b,"EXPORT")
      OR WordEq(s,a,b,"QUALIFIED") OR WordEq(s,a,b,"RETURN") OR WordEq(s,a,b,"EXIT") OR WordEq(s,a,b,"WITH")
      OR WordEq(s,a,b,"AND") OR WordEq(s,a,b,"OR") OR WordEq(s,a,b,"NOT") OR WordEq(s,a,b,"DIV")
      OR WordEq(s,a,b,"MOD") OR WordEq(s,a,b,"IN") OR WordEq(s,a,b,"NIL")
END IsKeyword;

PROCEDURE ColourLine (VAR s: ARRAY OF CHAR; len: CARDINAL; VAR depthIO: CARDINAL;
                      VAR col: ARRAY OF Colour);
  VAR i, a, depth: CARDINAL; q: CHAR; up: ARRAY [0..255] OF CHAR; w: CARDINAL;
BEGIN
  depth := depthIO; i := 0;
  WHILE i < len DO
    IF depth > 0 THEN
      IF (s[i] = '(') AND (i+1 < len) AND (s[i+1] = '*') THEN
        col[i] := ComFg; col[i+1] := ComFg; INC(depth); i := i + 2
      ELSIF (s[i] = '*') AND (i+1 < len) AND (s[i+1] = ')') THEN
        col[i] := ComFg; col[i+1] := ComFg; DEC(depth); i := i + 2
      ELSE col[i] := ComFg; INC(i) END
    ELSIF (s[i] = '(') AND (i+1 < len) AND (s[i+1] = '*') THEN
      col[i] := ComFg; col[i+1] := ComFg; INC(depth); i := i + 2
    ELSIF (s[i] = '"') OR (s[i] = "'") THEN
      q := s[i]; col[i] := StrFg; INC(i);
      WHILE (i < len) AND (s[i] # q) DO col[i] := StrFg; INC(i) END;
      IF i < len THEN col[i] := StrFg; INC(i) END
    ELSIF IsDigit(s[i]) THEN
      WHILE (i < len) AND (IsAlnum(s[i]) OR (s[i] = '.')) DO col[i] := NumFg; INC(i) END
    ELSIF IsAlpha(s[i]) THEN
      a := i; w := 0;
      WHILE (i < len) AND IsAlnum(s[i]) DO
        IF w <= 255 THEN up[w] := Up(s[i]); INC(w) END; INC(i)
      END;
      IF IsKeyword(up, 0, w) THEN WHILE a < i DO col[a] := KwFg; INC(a) END
      ELSE WHILE a < i DO col[a] := CodeFg; INC(a) END END
    ELSE col[i] := CodeFg; INC(i) END
  END;
  depthIO := depth
END ColourLine;

(* ---- selection --------------------------------------------------------- *)

PROCEDURE SelLo (): CARDINAL;
BEGIN IF NOT gHasSel THEN RETURN gPos ELSIF gAnchor < gPos THEN RETURN gAnchor ELSE RETURN gPos END END SelLo;
PROCEDURE SelHi (): CARDINAL;
BEGIN IF NOT gHasSel THEN RETURN gPos ELSIF gAnchor > gPos THEN RETURN gAnchor ELSE RETURN gPos END END SelHi;
PROCEDURE ClearSel; BEGIN gHasSel := FALSE END ClearSel;

PROCEDURE DeleteSel;   (* delete the selection if any; cursor ends at its start *)
  VAR lo, hi: CARDINAL;
BEGIN
  IF NOT gHasSel THEN RETURN END;
  lo := SelLo(); hi := SelHi();
  IF hi > lo THEN gDoc := DeleteRange(gDoc, lo, hi - lo); gPos := lo; gModified := TRUE; ClearMsg END;
  gHasSel := FALSE
END DeleteSel;

PROCEDURE GetSelText (VAR buf: ARRAY OF CHAR);   (* selection -> buf (NUL-terminated) *)
  VAR lo, hi, i, j: CARDINAL;
BEGIN
  lo := SelLo(); hi := SelHi(); j := 0; i := lo;
  WHILE (i < hi) AND (j < HIGH(buf)) DO buf[j] := CharAt(gDoc, i); INC(j); INC(i) END;
  buf[j] := 0C
END GetSelText;

(* ---- layout + menus ---------------------------------------------------- *)

PROCEDURE Layout;
  VAR avail: CARDINAL;
BEGIN
  gCodeW := gCols - GutterW;
  avail := gRows - 3;                          (* menu + output-title + status *)
  IF gSplitRows = 0 THEN gEdRows := (avail * 3) DIV 4 ELSE gEdRows := gSplitRows END;
  IF gEdRows < 3 THEN gEdRows := 3 END;
  IF gEdRows > avail - 1 THEN gEdRows := avail - 1 END;
  gOutRows := avail - gEdRows;
  gOutTitle := EdTop + gEdRows;
  gOutTop2 := gOutTitle + 1
END Layout;

PROCEDURE SetupMenus;
  VAR i: CARDINAL; nm: ARRAY [0..127] OF CHAR;
BEGIN
  MenuClear;
  MenuAdd("File");
    MenuAddItem(MFile, "New");  MenuAddItem(MFile, "Open...");
    MenuAddItem(MFile, "Save"); MenuAddItem(MFile, "Save As...");
    i := 0;
    WHILE i < gRecentCount DO Basename(gRecent[i], nm); MenuAddItem(MFile, nm); INC(i) END;
    MenuAddItem(MFile, "Quit");
  MenuAdd("Edit");
    MenuAddItem(MEdit, "Cut  ^X");  MenuAddItem(MEdit, "Copy  ^C");
    MenuAddItem(MEdit, "Paste  ^V"); MenuAddItem(MEdit, "Select All  ^A");
  MenuAdd("Search");
    MenuAddItem(MSearch, "Find...  ^F"); MenuAddItem(MSearch, "Find Next  F3");
    MenuAddItem(MSearch, "Replace...  ^R"); MenuAddItem(MSearch, "Goto Line...  ^G");
  MenuAdd("Source");
    MenuAddItem(MSource, "Format");
  MenuAdd("Build");
    MenuAddItem(MBuild, "Compile  F9"); MenuAddItem(MBuild, "Run  F5");
  MenuAdd("Help");
    MenuAddItem(MHelp, "About");
  MenuSelect(0)
END SetupMenus;

(* ---- the starter document ---------------------------------------------- *)

PROCEDURE Welcome;
BEGIN
  gDoc := Empty();
  gDoc := Append(gDoc, "MODULE Hello;"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "FROM STextIO IMPORT WriteString, WriteLn;"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "FROM SWholeIO IMPORT WriteInt;"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "VAR i: INTEGER;"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "BEGIN"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, '  WriteString("Hello from FastM2!"); WriteLn;'); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "  FOR i := 1 TO 5 DO"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, '    WriteString("  count = "); WriteInt(i, 1); WriteLn'); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "  END"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "END Hello.")
END Welcome;

(* ---- rendering --------------------------------------------------------- *)

PROCEDURE ShowStatus;
  VAR b: ARRAY [0..159] OF CHAR; num: ARRAY [0..15] OF CHAR; nm: ARRAY [0..127] OF CHAR;
      pos, line, c: CARDINAL;
BEGIN
  IF gPromptMode # PromNone THEN
    pos := 0;
    IF    gPromptMode = PromFind    THEN AppendStr(b, pos, " Find: ")
    ELSIF gPromptMode = PromRepFind THEN AppendStr(b, pos, " Replace - find: ")
    ELSIF gPromptMode = PromRepTo   THEN AppendStr(b, pos, " Replace with: ")
    ELSE                                 AppendStr(b, pos, " Goto line: ") END;
    AppendStr(b, pos, gPromptBuf); AppendStr(b, pos, "_   (Enter=ok  Esc=cancel)");
    SetStatus(b); RETURN
  END;
  PosToLineCol(gDoc, gPos, line, c); pos := 0;
  Basename(gFile, nm);
  AppendStr(b, pos, " "); AppendStr(b, pos, nm);
  IF gModified THEN AppendStr(b, pos, "*") END;
  AppendStr(b, pos, "   Ln "); CardToStr(line+1, num); AppendStr(b, pos, num);
  AppendStr(b, pos, " Col "); CardToStr(c+1, num); AppendStr(b, pos, num);
  AppendStr(b, pos, "   ");
  IF gMsg[0] # 0C THEN AppendStr(b, pos, gMsg); AppendStr(b, pos, "   ") END;
  AppendStr(b, pos, "| F10 Menu  F9 Compile  F5 Run ");
  SetStatus(b)
END ShowStatus;

PROCEDURE RenderEditor;
  VAR curLine, curCol, sr, line, n, c, scol, depth: CARDINAL;
      buf: ARRAY [0..511] OF CHAR; col: ARRAY [0..511] OF Colour;
      num: ARRAY [0..15] OF CHAR; total, lstart, selLo, selHi, dpos: CARDINAL;
      ch: CHAR; bg, fg: Colour;
BEGIN
  PosToLineCol(gDoc, gPos, curLine, curCol);
  total := LineCount(gDoc);
  IF gFollowCursor THEN              (* keep the cursor visible (off after a wheel scroll) *)
    IF curLine < gTopLine THEN gTopLine := curLine
    ELSIF curLine >= gTopLine + gEdRows THEN gTopLine := curLine - gEdRows + 1 END;
    IF curCol < gLeft THEN gLeft := curCol
    ELSIF curCol >= gLeft + gCodeW THEN gLeft := curCol - gCodeW + 1 END
  END;
  IF gTopLine >= total THEN IF total > 0 THEN gTopLine := total - 1 ELSE gTopLine := 0 END END;

  selLo := SelLo(); selHi := SelHi();
  depth := 0; line := 0;
  WHILE line < gTopLine DO
    n := GetLine(gDoc, line, buf);
    FOR c := 0 TO n DO col[c] := CodeFg END;
    ColourLine(buf, n, depth, col);
    INC(line)
  END;

  Fill(0, EdTop, gCols, gEdRows, ' ', CodeFg, EdBg);
  FOR sr := 0 TO gEdRows-1 DO
    line := gTopLine + sr;
    IF line < total THEN
      lstart := LineStart(gDoc, line);
      CardToStr(line+1, num);
      WriteColAt(0, EdTop+sr, GutFg, EdBg, num);
      n := GetLine(gDoc, line, buf);
      FOR c := 0 TO n DO col[c] := CodeFg END;
      ColourLine(buf, n, depth, col);
      c := gLeft;
      WHILE (c < n) AND (c < gLeft + gCodeW) DO
        scol := CodeX + (c - gLeft);
        dpos := lstart + c;
        IF (dpos >= selLo) AND (dpos < selHi) THEN bg := SelBg; fg := SelFg
        ELSE bg := EdBg; fg := col[c] END;
        Fill(scol, EdTop+sr, 1, 1, buf[c], fg, bg);
        INC(c)
      END;
      (* show a multi-line selection running through the line break *)
      IF (lstart + n >= selLo) AND (lstart + n < selHi) THEN
        c := n; IF c < gLeft THEN c := gLeft END;
        WHILE c < gLeft + gCodeW DO
          Fill(CodeX + (c - gLeft), EdTop+sr, 1, 1, ' ', SelFg, SelBg); INC(c)
        END
      END
    END
  END;

  (* the cursor — only when it is inside the visible window (a wheel scroll can
     push it off-screen) *)
  IF (curLine >= gTopLine) AND (curLine < gTopLine + gEdRows) AND
     (curCol >= gLeft) AND (curCol < gLeft + gCodeW) THEN
    IF gPos < Length(gDoc) THEN ch := CharAt(gDoc, gPos); IF ch = CHR(10) THEN ch := ' ' END
    ELSE ch := ' ' END;
    Fill(CodeX + (curCol - gLeft), EdTop + (curLine - gTopLine), 1, 1, ch, CurFg, CurBg)
  END
END RenderEditor;

PROCEDURE RenderOutput;
  VAR sr, line, n, total, i: CARDINAL; buf: ARRAY [0..255] OF CHAR; fg: Colour;
BEGIN
  Fill(0, gOutTitle, gCols, 1, ' ', White, Teal);
  WriteColAt(2, gOutTitle, White, Teal, "Output  (drag this bar to resize)");
  Fill(0, gOutTop2, gCols, gOutRows, ' ', OutFg, OutBg);
  total := LineCount(gOut);
  FOR sr := 0 TO gOutRows-1 DO
    line := gOutTop + sr;
    IF line < total THEN
      n := GetLine(gOut, line, buf);
      fg := OutFg;
      i := 0;
      WHILE i + 5 <= n DO
        IF (buf[i]='e') AND (buf[i+1]='r') AND (buf[i+2]='r') AND (buf[i+3]='o') AND (buf[i+4]='r')
          THEN fg := ErrFg END;
        INC(i)
      END;
      WriteColAt(1, gOutTop2+sr, fg, OutBg, buf)
    END
  END
END RenderOutput;

PROCEDURE RenderAbout;
  VAR bx, by, bw, bh, cy: CARDINAL;
BEGIN
  bw := 64; IF bw > gCols THEN bw := gCols END;
  bh := 16; IF bh > gRows THEN bh := gRows END;
  bx := (gCols - bw) DIV 2; by := (gRows - bh) DIV 2;
  Fill(bx, by, bw, bh, ' ', White, Navy);
  Box(bx, by, bw, bh, Aqua, Navy);
  cy := by + 1;
  WriteColAt(bx+3, cy, Yellow, Navy, "FastM2 - a Modula-2 IDE for Windows"); cy := cy + 2;
  WriteColAt(bx+3, cy, White,  Navy, "Version 0.2    (WindowsModula2 / newm2)"); cy := cy + 2;
  WriteColAt(bx+3, cy, Silver, Navy, "Modula-2: a systems-programming language designed by"); INC(cy);
  WriteColAt(bx+3, cy, Silver, Navy, "Niklaus Wirth (1978) as the successor to Pascal -"); INC(cy);
  WriteColAt(bx+3, cy, Silver, Navy, "modules, coroutines, strong typing, and low-level"); INC(cy);
  WriteColAt(bx+3, cy, Silver, Navy, "SYSTEM access for systems work."); cy := cy + 2;
  WriteColAt(bx+3, cy, Silver, Navy, "This IDE and its libraries are written in Modula-2,"); INC(cy);
  WriteColAt(bx+3, cy, Silver, Navy, "compiled by newm2 (Rust + LLVM) to native Windows"); INC(cy);
  WriteColAt(bx+3, cy, Silver, Navy, "x64, and rendered with Direct2D."); cy := cy + 2;
  WriteColAt(bx+3, cy, Aqua,   Navy, "Press Esc or click (auto-closes in 8 seconds).")
END RenderAbout;

PROCEDURE Render;
BEGIN
  RenderEditor; RenderOutput; ShowStatus;
  MenuSetFocus(gMenuActive); MenuRender;
  IF gAbout THEN RenderAbout END
END Render;

(* Mark the window dirty. The actual Render happens once per WM_PAINT, so a burst
   of keystrokes (autorepeat) only renders/paints when the message queue drains -
   input stays responsive instead of each key doing a full render synchronously. *)
PROCEDURE Refresh;
BEGIN Repaint(gWin) END Refresh;

(* ---- editing ----------------------------------------------------------- *)

PROCEDURE InsertText (s: ARRAY OF CHAR);
BEGIN
  IF gHasSel THEN DeleteSel END;
  gDoc := Insert(gDoc, gPos, s); gPos := gPos + SLen(s); gModified := TRUE; ClearMsg
END InsertText;

PROCEDURE InsertCh (ch: CHAR);
  VAR s: ARRAY [0..1] OF CHAR;
BEGIN s[0] := ch; s[1] := 0C; InsertText(s) END InsertCh;

PROCEDURE Backspace;
BEGIN
  IF gHasSel THEN DeleteSel
  ELSIF gPos > 0 THEN gDoc := DeleteRange(gDoc, gPos-1, 1); DEC(gPos); gModified := TRUE; ClearMsg END
END Backspace;

PROCEDURE DeleteFwd;
BEGIN
  IF gHasSel THEN DeleteSel
  ELSIF gPos < Length(gDoc) THEN gDoc := DeleteRange(gDoc, gPos, 1); gModified := TRUE; ClearMsg END
END DeleteFwd;

PROCEDURE SetGoal;
  VAR l, c: CARDINAL;
BEGIN PosToLineCol(gDoc, gPos, l, c); gGoal := c END SetGoal;

(* call before any cursor move: extend the selection if Shift is down, else drop it *)
PROCEDURE PreMove;
BEGIN
  IF gShiftDown THEN
    IF NOT gHasSel THEN gAnchor := gPos; gHasSel := TRUE END
  ELSE gHasSel := FALSE END
END PreMove;

PROCEDURE GotoLineCol (line, col: CARDINAL);
  VAR ll: CARDINAL;
BEGIN ll := LineLen(gDoc, line); IF col > ll THEN col := ll END; gPos := LineStart(gDoc, line) + col END GotoLineCol;

PROCEDURE MoveLeft;  BEGIN PreMove; IF gPos > 0 THEN DEC(gPos) END; SetGoal END MoveLeft;
PROCEDURE MoveRight; BEGIN PreMove; IF gPos < Length(gDoc) THEN INC(gPos) END; SetGoal END MoveRight;
PROCEDURE MoveUp; VAR l,c: CARDINAL; BEGIN PreMove; PosToLineCol(gDoc,gPos,l,c); IF l>0 THEN GotoLineCol(l-1,gGoal) END END MoveUp;
PROCEDURE MoveDown; VAR l,c: CARDINAL; BEGIN PreMove; PosToLineCol(gDoc,gPos,l,c); IF l+1 < LineCount(gDoc) THEN GotoLineCol(l+1,gGoal) END END MoveDown;
PROCEDURE MoveHome; VAR l,c: CARDINAL; BEGIN PreMove; PosToLineCol(gDoc,gPos,l,c); gPos := LineStart(gDoc,l); gGoal := 0 END MoveHome;
PROCEDURE MoveEnd; VAR l,c: CARDINAL; BEGIN PreMove; PosToLineCol(gDoc,gPos,l,c); gPos := LineStart(gDoc,l)+LineLen(gDoc,l); gGoal := LineLen(gDoc,l) END MoveEnd;
PROCEDURE PageBy (up: BOOLEAN);
  VAR l, c, t: CARDINAL;
BEGIN
  PreMove; PosToLineCol(gDoc, gPos, l, c);
  IF up THEN IF l >= gEdRows THEN t := l - gEdRows ELSE t := 0 END
  ELSE t := l + gEdRows; IF t >= LineCount(gDoc) THEN t := LineCount(gDoc)-1 END END;
  GotoLineCol(t, gGoal)
END PageBy;

PROCEDURE PositionCursorAt (tc, tr: CARDINAL);   (* place the cursor at a screen cell *)
  VAR line, col: CARDINAL;
BEGIN
  IF tr < EdTop THEN tr := EdTop END;
  IF tr >= EdTop + gEdRows THEN tr := EdTop + gEdRows - 1 END;
  line := gTopLine + (tr - EdTop);
  IF tc < CodeX THEN col := 0 ELSE col := gLeft + (tc - CodeX) END;
  IF line >= LineCount(gDoc) THEN line := LineCount(gDoc) - 1 END;
  GotoLineCol(line, col); gGoal := col
END PositionCursorAt;

(* ---- file I/O ---------------------------------------------------------- *)

PROCEDURE SaveDoc (): BOOLEAN;
  VAR cid: SeqFile.ChanId; res: ChanConsts.OpenResults; i, n: CARDINAL; ch: CHAR;
BEGIN
  SeqFile.OpenWrite(cid, gFile, SeqFile.write + SeqFile.text, res);
  IF res # ChanConsts.opened THEN RETURN FALSE END;
  n := Length(gDoc); i := 0;
  WHILE i < n DO
    ch := CharAt(gDoc, i);
    IF ch = CHR(10) THEN TextIO.WriteLn(cid) ELSE TextIO.WriteChar(cid, ch) END; INC(i)
  END;
  SeqFile.Close(cid); RETURN TRUE
END SaveDoc;

PROCEDURE ReadFileRope (name: ARRAY OF CHAR): Rope;
  VAR cid: SeqFile.ChanId; res: ChanConsts.OpenResults; buf: ARRAY [0..255] OF CHAR;
      rr: IOConsts.ReadResults; r: Rope; done: BOOLEAN;
BEGIN
  SeqFile.OpenRead(cid, name, SeqFile.read + SeqFile.text, res);
  IF res # ChanConsts.opened THEN RETURN Empty() END;
  r := Empty(); done := FALSE;
  WHILE NOT done DO
    TextIO.ReadString(cid, buf); r := Append(r, buf);
    rr := IOResult.ReadResult(cid);
    IF rr = IOConsts.endOfLine THEN r := Append(r, gNL); TextIO.SkipLine(cid)
    ELSIF rr = IOConsts.endOfInput THEN done := TRUE END
  END;
  SeqFile.Close(cid); RETURN r
END ReadFileRope;

(* ---- recent files ------------------------------------------------------ *)

PROCEDURE SaveRecent;
  VAR cid: SeqFile.ChanId; res: ChanConsts.OpenResults; i, j, n: CARDINAL;
BEGIN
  SeqFile.OpenWrite(cid, RecentStore, SeqFile.write + SeqFile.text, res);
  IF res # ChanConsts.opened THEN RETURN END;
  i := 0;
  WHILE i < gRecentCount DO
    n := SLen(gRecent[i]); j := 0;
    WHILE j < n DO TextIO.WriteChar(cid, gRecent[i][j]); INC(j) END;
    TextIO.WriteLn(cid); INC(i)
  END;
  SeqFile.Close(cid)
END SaveRecent;

PROCEDURE LoadRecent;
  VAR cid: SeqFile.ChanId; res: ChanConsts.OpenResults; buf: ARRAY [0..519] OF CHAR;
      rr: IOConsts.ReadResults; done: BOOLEAN;
BEGIN
  gRecentCount := 0;
  SeqFile.OpenRead(cid, RecentStore, SeqFile.read + SeqFile.text, res);
  IF res # ChanConsts.opened THEN RETURN END;
  done := FALSE;
  WHILE NOT done DO
    TextIO.ReadString(cid, buf);
    IF (buf[0] # 0C) AND (gRecentCount < MaxRecent) THEN
      SCopy(gRecent[gRecentCount], buf); INC(gRecentCount)
    END;
    rr := IOResult.ReadResult(cid);
    IF rr = IOConsts.endOfLine THEN TextIO.SkipLine(cid)
    ELSIF rr = IOConsts.endOfInput THEN done := TRUE END
  END;
  SeqFile.Close(cid)
END LoadRecent;

PROCEDURE SameStr (VAR a: ARRAY OF CHAR; b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF SLen(a) # SLen(b) THEN RETURN FALSE END;
  i := 0; WHILE i < SLen(b) DO IF a[i] # b[i] THEN RETURN FALSE END; INC(i) END;
  RETURN TRUE
END SameStr;

PROCEDURE AddRecent (path: ARRAY OF CHAR);   (* move-to-front MRU, persist, rebuild menu *)
  VAR i, found: CARDINAL;
BEGIN
  found := MaxRecent;
  i := 0; WHILE i < gRecentCount DO IF SameStr(gRecent[i], path) THEN found := i END; INC(i) END;
  IF found < MaxRecent THEN
    i := found; WHILE i > 0 DO SCopy(gRecent[i], gRecent[i-1]); DEC(i) END
  ELSE
    IF gRecentCount < MaxRecent THEN INC(gRecentCount) END;
    i := gRecentCount - 1; WHILE i > 0 DO SCopy(gRecent[i], gRecent[i-1]); DEC(i) END
  END;
  SCopy(gRecent[0], path);
  SaveRecent; SetupMenus
END AddRecent;

PROCEDURE LoadDocFrom (name: ARRAY OF CHAR);
BEGIN
  Free(gDoc); gDoc := ReadFileRope(name);
  IF Length(gDoc) = 0 THEN gDoc := FromString("MODULE Untitled;") END;
  gPos := 0; gAnchor := 0; gHasSel := FALSE;
  gTopLine := 0; gLeft := 0; gGoal := 0; gModified := FALSE;
  SCopy(gFile, name); AddRecent(name); SCopy(gMsg, "opened")
END LoadDocFrom;

PROCEDURE OpenRecent (i: CARDINAL);
BEGIN IF i < gRecentCount THEN LoadDocFrom(gRecent[i]) END END OpenRecent;

PROCEDURE OkToDiscard (): BOOLEAN;
BEGIN
  IF NOT gModified THEN RETURN TRUE END;
  RETURN Confirm(gWin, "Discard unsaved changes?", "FastM2")
END OkToDiscard;

PROCEDURE NewDoc;
BEGIN
  IF NOT OkToDiscard() THEN RETURN END;
  Free(gDoc); Welcome; SCopy(gFile, WorkFile);
  gPos := 0; gAnchor := 0; gHasSel := FALSE;
  gTopLine := 0; gLeft := 0; gGoal := 0; gModified := FALSE; SCopy(gMsg, "new")
END NewDoc;

PROCEDURE OpenDoc;
BEGIN
  IF NOT OkToDiscard() THEN RETURN END;
  IF OpenFile(gWin, gFile, "Modula-2|*.mod;*.def|All files|*.*", "Open") THEN LoadDocFrom(gFile) END
END OpenDoc;

PROCEDURE DoSave;
BEGIN
  IF SaveDoc() THEN gModified := FALSE; AddRecent(gFile); SCopy(gMsg, "saved")
  ELSE SCopy(gMsg, "save FAILED") END
END DoSave;

PROCEDURE SaveAs;
BEGIN
  IF SaveFile(gWin, gFile, "Modula-2|*.mod;*.def|All files|*.*", "Save As", "mod") THEN DoSave END
END SaveAs;

(* ---- find / replace / goto (status-line prompt) ------------------------ *)

PROCEDURE EqCI (a, b: CHAR): BOOLEAN;
BEGIN RETURN Up(a) = Up(b) END EqCI;

PROCEDURE FindFrom (start: CARDINAL; VAR at: CARDINAL): BOOLEAN;
  VAR n, m, i, j: CARDINAL; match: BOOLEAN;
BEGIN
  m := SLen(gFind); IF m = 0 THEN RETURN FALSE END;
  n := Length(gDoc); IF m > n THEN RETURN FALSE END;
  i := start; IF i > n - m THEN RETURN FALSE END;
  WHILE i + m <= n DO
    match := TRUE; j := 0;
    WHILE match AND (j < m) DO IF NOT EqCI(CharAt(gDoc, i+j), gFind[j]) THEN match := FALSE END; INC(j) END;
    IF match THEN at := i; RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END FindFrom;

PROCEDURE FindNext;
  VAR start, at: CARDINAL; ok: BOOLEAN;
BEGIN
  IF SLen(gFind) = 0 THEN RETURN END;
  IF gHasSel THEN start := SelHi() ELSE start := gPos END;
  ok := FindFrom(start, at);
  IF NOT ok THEN ok := FindFrom(0, at) END;            (* wrap around *)
  IF ok THEN
    gAnchor := at; gPos := at + SLen(gFind); gHasSel := TRUE; SetGoal; SCopy(gMsg, "found")
  ELSE SCopy(gMsg, "not found") END
END FindNext;

PROCEDURE ReplaceAll;
  VAR m, count, p, at, pos: CARDINAL; num: ARRAY [0..15] OF CHAR;
BEGIN
  m := SLen(gFind); IF m = 0 THEN RETURN END;
  count := 0; p := 0;
  WHILE FindFrom(p, at) DO
    gDoc := DeleteRange(gDoc, at, m);
    gDoc := Insert(gDoc, at, gReplace);
    p := at + SLen(gReplace); INC(count)
  END;
  IF count > 0 THEN gModified := TRUE; gPos := 0; gHasSel := FALSE END;
  pos := 0; AppendStr(gMsg, pos, "replaced "); CardToStr(count, num); AppendStr(gMsg, pos, num)
END ReplaceAll;

PROCEDURE GotoLine (ln: CARDINAL);
BEGIN
  IF ln < 1 THEN ln := 1 END;
  IF ln > LineCount(gDoc) THEN ln := LineCount(gDoc) END;
  gHasSel := FALSE; GotoLineCol(ln-1, 0); SetGoal; SCopy(gMsg, "goto")
END GotoLine;

PROCEDURE StartPrompt (mode: CARDINAL);
BEGIN gPromptMode := mode; gPromptLen := 0; gPromptBuf[0] := 0C END StartPrompt;

PROCEDURE StartFind;    BEGIN StartPrompt(PromFind) END StartFind;
PROCEDURE StartReplace; BEGIN StartPrompt(PromRepFind) END StartReplace;
PROCEDURE StartGoto;    BEGIN StartPrompt(PromGoto) END StartGoto;

PROCEDURE FindNextCmd;   (* F3: repeat the last search, or open Find if none yet *)
BEGIN IF SLen(gFind) = 0 THEN StartFind ELSE FindNext END END FindNextCmd;

PROCEDURE SubmitPrompt;
  VAR ln, i: CARDINAL;
BEGIN
  IF gPromptMode = PromFind THEN
    SCopy(gFind, gPromptBuf); gPromptMode := PromNone; FindNext
  ELSIF gPromptMode = PromRepFind THEN
    SCopy(gFind, gPromptBuf); StartPrompt(PromRepTo)
  ELSIF gPromptMode = PromRepTo THEN
    SCopy(gReplace, gPromptBuf); gPromptMode := PromNone; ReplaceAll
  ELSIF gPromptMode = PromGoto THEN
    ln := 0; i := 0;
    WHILE (i < gPromptLen) AND IsDigit(gPromptBuf[i]) DO ln := ln*10 + (ORD(gPromptBuf[i])-ORD('0')); INC(i) END;
    gPromptMode := PromNone; GotoLine(ln)
  END
END SubmitPrompt;

PROCEDURE PromptKey (ch: CHAR);
BEGIN
  IF ch = CHR(VK_RETURN) THEN SubmitPrompt
  ELSIF ch = CHR(VK_ESCAPE) THEN gPromptMode := PromNone; SCopy(gMsg, "cancelled")
  ELSIF ch = CHR(VK_BACK) THEN IF gPromptLen > 0 THEN DEC(gPromptLen); gPromptBuf[gPromptLen] := 0C END
  ELSIF (ch >= ' ') AND (gPromptLen < HIGH(gPromptBuf)) THEN
    gPromptBuf[gPromptLen] := ch; INC(gPromptLen); gPromptBuf[gPromptLen] := 0C
  END
END PromptKey;

(* ---- source format (re-indenter) --------------------------------------- *)

PROCEDURE FirstWord (VAR line: ARRAY OF CHAR; s, e: CARDINAL; VAR w: ARRAY OF CHAR; VAR wl: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  i := s; WHILE (i < e) AND NOT IsAlpha(line[i]) DO INC(i) END;
  wl := 0;
  WHILE (i < e) AND IsAlnum(line[i]) AND (wl < HIGH(w)) DO w[wl] := Up(line[i]); INC(wl); INC(i) END;
  w[wl] := 0C
END FirstWord;

PROCEDURE LastWord (VAR line: ARRAY OF CHAR; s, e: CARDINAL; VAR w: ARRAY OF CHAR; VAR wl: CARDINAL);
  VAR b, en, i: CARDINAL;
BEGIN
  en := e; WHILE (en > s) AND NOT IsAlnum(line[en-1]) DO DEC(en) END;
  b := en; WHILE (b > s) AND IsAlnum(line[b-1]) DO DEC(b) END;
  wl := 0; i := b;
  WHILE (i < en) AND (wl < HIGH(w)) DO w[wl] := Up(line[i]); INC(wl); INC(i) END;
  w[wl] := 0C
END LastWord;

PROCEDURE WIs (VAR w: ARRAY OF CHAR; wl: CARDINAL; kw: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  IF wl # SLen(kw) THEN RETURN FALSE END;
  i := 0; WHILE i < wl DO IF w[i] # kw[i] THEN RETURN FALSE END; INC(i) END;
  RETURN TRUE
END WIs;

PROCEDURE Reindent;
  VAR total, ln, depth, emit, n, s, e, i, k, ind: CARDINAL;
      line, tmp: ARRAY [0..511] OF CHAR;
      fw, lw: ARRAY [0..31] OF CHAR; fwl, lwl, olen: CARDINAL;
      out: Rope; closer, elseish, opener: BOOLEAN; cl, cc: CARDINAL;
BEGIN
  PosToLineCol(gDoc, gPos, cl, cc);          (* remember the cursor line *)
  total := LineCount(gDoc); out := Empty(); depth := 0;
  ln := 0;
  WHILE ln < total DO
    n := GetLine(gDoc, ln, line);
    s := 0; WHILE (s < n) AND ((line[s] = ' ') OR (line[s] = CHR(9))) DO INC(s) END;
    e := n; WHILE (e > s) AND ((line[e-1] = ' ') OR (line[e-1] = CHR(9))) DO DEC(e) END;
    FirstWord(line, s, e, fw, fwl); LastWord(line, s, e, lw, lwl);
    closer  := WIs(fw,fwl,"END") OR WIs(fw,fwl,"UNTIL");
    elseish := WIs(fw,fwl,"ELSE") OR WIs(fw,fwl,"ELSIF");
    emit := depth;
    (* closers (END/UNTIL) and continuations (ELSE/ELSIF) both step the line out
       one level; for ELSE/ELSIF the trailing opener (ELSE / THEN) re-indents the
       body, so depth must drop here too or it would inflate permanently. *)
    IF closer OR elseish THEN IF depth > 0 THEN DEC(depth) END; emit := depth END;
    olen := 0;
    IF e > s THEN
      ind := emit * 2; k := 0;
      WHILE (k < ind) AND (olen < HIGH(tmp)) DO tmp[olen] := ' '; INC(olen); INC(k) END;
      i := s;
      WHILE (i < e) AND (olen < HIGH(tmp)) DO tmp[olen] := line[i]; INC(olen); INC(i) END
    END;
    tmp[olen] := 0C;
    IF ln > 0 THEN out := Append(out, gNL) END;
    out := Append(out, tmp);
    opener := WIs(lw,lwl,"THEN") OR WIs(lw,lwl,"DO") OR WIs(lw,lwl,"OF") OR WIs(lw,lwl,"BEGIN")
           OR WIs(lw,lwl,"LOOP") OR WIs(lw,lwl,"REPEAT") OR WIs(lw,lwl,"RECORD") OR WIs(lw,lwl,"ELSE");
    IF opener AND (depth < 40) THEN INC(depth) END;
    INC(ln)
  END;
  Free(gDoc); gDoc := out;
  gHasSel := FALSE; gTopLine := 0; gLeft := 0;
  IF cl >= LineCount(gDoc) THEN cl := LineCount(gDoc) - 1 END;
  GotoLineCol(cl, 0); SetGoal; gModified := TRUE; SCopy(gMsg, "formatted")
END Reindent;

(* ---- clipboard --------------------------------------------------------- *)

PROCEDURE SelTooBig (): BOOLEAN;   (* selection larger than the staging buffer *)
BEGIN RETURN (SelHi() - SelLo()) >= HIGH(gClip) END SelTooBig;

PROCEDURE DoCopy;
  VAR ok: BOOLEAN;
BEGIN
  IF gHasSel AND (SelHi() > SelLo()) THEN
    IF SelTooBig() THEN SCopy(gMsg, "selection too large (max 64K)")
    ELSE GetSelText(gClip); ok := SetText(gClip); SCopy(gMsg, "copied") END
  END
END DoCopy;

PROCEDURE DoCut;
BEGIN
  IF gHasSel AND (SelHi() > SelLo()) THEN
    IF SelTooBig() THEN SCopy(gMsg, "selection too large to cut")
    ELSE DoCopy; DeleteSel; SCopy(gMsg, "cut") END   (* copy must succeed before delete *)
  END
END DoCut;

PROCEDURE DoPaste;
BEGIN
  IF GetText(gClip) THEN
    IF gHasSel THEN DeleteSel END;
    gDoc := Insert(gDoc, gPos, gClip); gPos := gPos + SLen(gClip); gModified := TRUE; SCopy(gMsg, "pasted")
  END
END DoPaste;

PROCEDURE DoSelectAll;
BEGIN gAnchor := 0; gPos := Length(gDoc); gHasSel := Length(gDoc) > 0; SetGoal; SCopy(gMsg, "select all") END DoSelectAll;

(* ---- compile / run ----------------------------------------------------- *)

PROCEDURE BuildCmd (verb: ARRAY OF CHAR; VAR cmd: ARRAY OF CHAR);
  VAR pos: CARDINAL;
BEGIN
  pos := 0;
  AppendStr(cmd, pos, Compiler); AppendStr(cmd, pos, " ");
  AppendStr(cmd, pos, verb);     AppendStr(cmd, pos, " ");
  AppendStr(cmd, pos, gFile);    AppendStr(cmd, pos, " --library ");
  AppendStr(cmd, pos, LibPath);  AppendStr(cmd, pos, " > ");
  AppendStr(cmd, pos, OutFile);  AppendStr(cmd, pos, " 2>&1")
END BuildCmd;

PROCEDURE JumpToError;
  VAR total, line, n, i, ln: CARDINAL; buf: ARRAY [0..255] OF CHAR; found: BOOLEAN;
BEGIN
  total := LineCount(gOut); found := FALSE; line := 0;
  WHILE (line < total) AND NOT found DO
    n := GetLine(gOut, line, buf);
    i := 0; WHILE (i < n) AND (buf[i] # ':') DO INC(i) END;
    IF (i < n) AND (i+1 < n) AND IsDigit(buf[i+1]) THEN
      ln := 0; INC(i);
      WHILE (i < n) AND IsDigit(buf[i]) DO ln := ln*10 + (ORD(buf[i]) - ORD('0')); INC(i) END;
      IF (ln > 0) AND (ln <= LineCount(gDoc)) THEN gHasSel := FALSE; GotoLineCol(ln-1, 0); SetGoal; found := TRUE END
    END;
    INC(line)
  END
END JumpToError;

PROCEDURE Compile (run: BOOLEAN);
  VAR cmd: ARRAY [0..1023] OF CHAR; status: CARDINAL; ok: BOOLEAN;
BEGIN
  IF NOT SaveDoc() THEN SCopy(gMsg, "save FAILED"); RETURN END;
  gModified := FALSE;
  IF run THEN BuildCmd("run", cmd) ELSE BuildCmd("build", cmd) END;
  SCopy(gMsg, "compiling...");
  ok := PerformCommand(cmd, SyncExec, status);
  Free(gOut); gOut := ReadFileRope(OutFile); gOutTop := 0;
  IF NOT ok THEN SCopy(gMsg, "could not launch newm2")
  ELSIF status = 0 THEN IF run THEN SCopy(gMsg, "ran ok") ELSE SCopy(gMsg, "compiled ok") END
  ELSE SCopy(gMsg, "errors - see output"); JumpToError END
END Compile;

(* ---- menu -------------------------------------------------------------- *)

PROCEDURE ShowAbout;
  VAR tid: ADRCARD;
BEGIN
  gAbout := TRUE; tid := SetTimer(gWin, AboutTimer, VAL(DWORD, AboutSecs), NIL); SCopy(gMsg, "about")
END ShowAbout;

PROCEDURE CloseAbout;
  VAR ok: BOOL;
BEGIN IF gAbout THEN gAbout := FALSE; ok := KillTimer(gWin, AboutTimer) END END CloseAbout;

PROCEDURE DispatchMenu (menu, item: CARDINAL);
BEGIN
  IF menu = MFile THEN
    IF    item = 0 THEN NewDoc
    ELSIF item = 1 THEN OpenDoc
    ELSIF item = 2 THEN DoSave
    ELSIF item = 3 THEN SaveAs
    ELSIF item = 4 + gRecentCount THEN Quit
    ELSE OpenRecent(item - 4) END
  ELSIF menu = MEdit THEN
    IF    item = 0 THEN DoCut
    ELSIF item = 1 THEN DoCopy
    ELSIF item = 2 THEN DoPaste
    ELSE DoSelectAll END
  ELSIF menu = MSearch THEN
    IF    item = 0 THEN StartFind
    ELSIF item = 1 THEN FindNextCmd
    ELSIF item = 2 THEN StartReplace
    ELSE StartGoto END
  ELSIF menu = MSource THEN
    Reindent
  ELSIF menu = MBuild THEN
    IF item = 0 THEN Compile(FALSE) ELSE Compile(TRUE) END
  ELSIF menu = MHelp THEN
    ShowAbout
  END
END DispatchMenu;

PROCEDURE DrainMenu;
  VAR e: Event;
BEGIN
  WHILE NextEvent(e) DO
    IF e.kind = EvMenuItem THEN DispatchMenu(e.menu, e.item); gMenuActive := FALSE
    ELSIF e.kind = EvMenuClose THEN gMenuActive := FALSE END
  END
END DrainMenu;

PROCEDURE MapVK (vk: CARDINAL): CARDINAL;
BEGIN
  IF    vk = VK_LEFT   THEN RETURN KeyLeft
  ELSIF vk = VK_RIGHT  THEN RETURN KeyRight
  ELSIF vk = VK_UP     THEN RETURN KeyUp
  ELSIF vk = VK_DOWN   THEN RETURN KeyDown
  ELSIF vk = VK_RETURN THEN RETURN KeyEnter
  ELSIF vk = VK_ESCAPE THEN RETURN KeyEsc
  ELSIF vk = VK_TAB    THEN RETURN KeyTab
  ELSE RETURN KeyNone END
END MapVK;

PROCEDURE ToggleMenu;
BEGIN
  IF gMenuActive THEN
    IF MenuIsOpen() THEN MenuClose END; gMenuActive := FALSE
  ELSE gMenuActive := TRUE; MenuSelect(0) END
END ToggleMenu;

PROCEDURE ActivateMenu (idx: CARDINAL);   (* Alt+letter: focus + open a menu *)
BEGIN
  IF MenuIsOpen() THEN MenuClose END;
  gMenuActive := TRUE; MenuSelect(idx); MenuOpen
END ActivateMenu;

(* ---- window handler ---------------------------------------------------- *)

PROCEDURE OnLBdown (lParam: CARDINAL);
  VAR px, py, tc, tr, mi, it: CARDINAL;
BEGIN
  px := lParam MOD 65536; py := lParam DIV 65536;
  tc := px DIV CellW; tr := py DIV CellH;
  IF tr = 0 THEN                                       (* the menu bar *)
    mi := MenuBarHit(tc);
    IF mi # MAX(CARDINAL) THEN ActivateMenu(mi) ELSE
      IF MenuIsOpen() THEN MenuClose END; gMenuActive := FALSE END;
    Refresh; RETURN
  ELSIF gMenuActive OR MenuIsOpen() THEN
    it := MenuPopupHit(tc, tr);
    IF it # MAX(CARDINAL) THEN
      MenuItemSelect(it); DispatchMenu(MenuSelected(), it)
    END;
    IF MenuIsOpen() THEN MenuClose END; gMenuActive := FALSE; Refresh; RETURN
  ELSIF tr = gOutTitle THEN                            (* drag the split divider *)
    gSplitDrag := TRUE; RETURN
  ELSIF (tr >= EdTop) AND (tr < EdTop + gEdRows) THEN  (* start a text selection *)
    PositionCursorAt(tc, tr); gAnchor := gPos; gHasSel := FALSE; gDragging := TRUE; Refresh
  END
END OnLBdown;

PROCEDURE OnMouseMove (wParam, lParam: CARDINAL);
  VAR py, tr, ed: CARDINAL;
BEGIN
  IF (wParam BAND MK_LBUTTON) = 0 THEN gDragging := FALSE; gSplitDrag := FALSE; RETURN END;
  IF gDragging THEN
    PositionCursorAt(lParam MOD 65536 DIV CellW, lParam DIV 65536 DIV CellH);
    gHasSel := gPos # gAnchor; Refresh
  ELSIF gSplitDrag THEN
    py := lParam DIV 65536; tr := py DIV CellH;
    IF tr <= EdTop THEN ed := 3 ELSE ed := tr - EdTop END;
    gSplitRows := ed; Layout; Refresh
  END
END OnMouseMove;

PROCEDURE OnWheel (wParam: CARDINAL);   (* mouse wheel: scroll the view, cursor stays put *)
  VAR hw, total: CARDINAL;
BEGIN
  hw := (wParam DIV 65536) MOD 65536;   (* HIWORD = signed wheel delta (>0 = up) *)
  gFollowCursor := FALSE;
  total := LineCount(gDoc);
  IF hw < 32768 THEN
    IF gTopLine >= WheelLines THEN gTopLine := gTopLine - WheelLines ELSE gTopLine := 0 END
  ELSE
    gTopLine := gTopLine + WheelLines;
    IF gTopLine >= total THEN IF total > 0 THEN gTopLine := total - 1 ELSE gTopLine := 0 END END
  END
END OnWheel;

PROCEDURE EditChar (ch: CHAR);
BEGIN
  IF    ch = CHR(1)  THEN DoSelectAll
  ELSIF ch = CHR(3)  THEN DoCopy
  ELSIF ch = CHR(6)  THEN StartFind
  ELSIF ch = CHR(7)  THEN StartGoto
  ELSIF ch = CHR(14) THEN NewDoc
  ELSIF ch = CHR(15) THEN OpenDoc
  ELSIF ch = CHR(18) THEN StartReplace
  ELSIF ch = CHR(19) THEN DoSave
  ELSIF ch = CHR(22) THEN DoPaste
  ELSIF ch = CHR(24) THEN DoCut
  ELSIF ch = CHR(VK_RETURN) THEN InsertText(gNL); SetGoal
  ELSIF ch = CHR(VK_BACK) THEN Backspace; SetGoal
  ELSIF ch = CHR(9) THEN InsertText("  "); SetGoal
  ELSIF ch >= ' ' THEN InsertCh(ch); SetGoal
  END
END EditChar;

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; rb: BOOLEAN; ch: CHAR; key, cw, chh, nc, nr: CARDINAL;
BEGIN
  handled := TRUE;
  (* eat the WM_CHAR paired with a menu Enter/Tab FIRST, so it can't dismiss a
     popup the same Enter just opened *)
  IF (msg = WM_CHAR) AND gEatChar THEN gEatChar := FALSE; RETURN 0 END;
  (* any keypress or click dismisses the About popup *)
  IF gAbout AND ((msg = WM_KEYDOWN) OR (msg = WM_CHAR) OR (msg = WM_SYSKEYDOWN) OR (msg = WM_LBUTTONDOWN)) THEN
    CloseAbout; Refresh; RETURN 0
  END;
  (* non-wheel input re-engages cursor-follow (the wheel turns it off to free-scroll) *)
  IF (msg = WM_KEYDOWN) OR (msg = WM_CHAR) OR (msg = WM_LBUTTONDOWN) THEN gFollowCursor := TRUE END;
  IF msg = WM_PAINT THEN
    Render(); Paint(); ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_TIMER THEN
    IF wParam = AboutTimer THEN CloseAbout; Refresh END; RETURN 0
  ELSIF msg = WM_KILLFOCUS THEN
    gShiftDown := FALSE; gDragging := FALSE; gSplitDrag := FALSE;   (* don't strand drag/modifier state *)
    handled := FALSE; RETURN 0
  ELSIF msg = WM_SIZE THEN
    ClientSize(w, cw, chh);
    IF (cw > 0) AND (chh > 0) THEN
      nc := cw DIV CellW; nr := chh DIV CellH;
      IF nc < MinCols THEN nc := MinCols END;
      IF nr < MinRows THEN nr := MinRows END;
      IF (nc # gReqCols) OR (nr # gReqRows) THEN
        gReqCols := nc; gReqRows := nr;
        Init(nc, nr); gCols := Cols(); gRows := Rows();
        SetupMenus; Layout; gMenuActive := FALSE
      END;
      rb := Resize(cw, chh);
      Render; Paint(); ok := ValidateRect(w, NIL)
    END;
    RETURN 0
  ELSIF msg = WM_LBUTTONDOWN THEN
    OnLBdown(lParam); RETURN 0
  ELSIF msg = WM_MOUSEMOVE THEN
    IF gDragging OR gSplitDrag THEN OnMouseMove(wParam, lParam) END; RETURN 0
  ELSIF msg = WM_MOUSEWHEEL THEN
    OnWheel(wParam); Refresh; RETURN 0
  ELSIF msg = WM_LBUTTONUP THEN
    gDragging := FALSE; gSplitDrag := FALSE; RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF gPromptMode # PromNone THEN PromptKey(ch); Refresh
    ELSIF NOT (gMenuActive OR MenuIsOpen()) THEN EditChar(ch); Refresh END;
    RETURN 0
  ELSIF msg = WM_SYSKEYDOWN THEN
    IF    wParam = VK_F10     THEN ToggleMenu; Refresh; RETURN 0
    ELSIF wParam = ORD('F')   THEN ActivateMenu(MFile); Refresh; RETURN 0
    ELSIF wParam = ORD('E')   THEN ActivateMenu(MEdit); Refresh; RETURN 0
    ELSIF wParam = ORD('S')   THEN ActivateMenu(MSearch); Refresh; RETURN 0
    ELSIF wParam = ORD('O')   THEN ActivateMenu(MSource); Refresh; RETURN 0
    ELSIF wParam = ORD('B')   THEN ActivateMenu(MBuild); Refresh; RETURN 0
    ELSIF wParam = ORD('H')   THEN ActivateMenu(MHelp); Refresh; RETURN 0
    END;
    handled := FALSE; RETURN 0
  ELSIF msg = WM_KEYUP THEN
    IF wParam = VK_SHIFT THEN gShiftDown := FALSE END;
    handled := FALSE; RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    gEatChar := FALSE;
    IF wParam = VK_SHIFT THEN gShiftDown := TRUE; RETURN 0 END;
    IF gPromptMode # PromNone THEN RETURN 0 END;
    IF gMenuActive OR MenuIsOpen() THEN
      key := MapVK(wParam);
      IF key # KeyNone THEN
        IF HandleKey(key, 0C) THEN
          IF (key = KeyEnter) OR (key = KeyTab) THEN gEatChar := TRUE END;
          DrainMenu
        ELSIF key = KeyEsc THEN gMenuActive := FALSE END
      END;
      Refresh
    ELSE
      IF    wParam = VK_LEFT   THEN MoveLeft;  Refresh
      ELSIF wParam = VK_RIGHT  THEN MoveRight; Refresh
      ELSIF wParam = VK_UP     THEN MoveUp;    Refresh
      ELSIF wParam = VK_DOWN   THEN MoveDown;  Refresh
      ELSIF wParam = VK_HOME   THEN MoveHome;  Refresh
      ELSIF wParam = VK_END    THEN MoveEnd;   Refresh
      ELSIF wParam = VK_PRIOR  THEN PageBy(TRUE);  Refresh
      ELSIF wParam = VK_NEXT   THEN PageBy(FALSE); Refresh
      ELSIF wParam = VK_DELETE THEN DeleteFwd; SetGoal; Refresh
      ELSIF wParam = VK_F2     THEN DoSave; Refresh
      ELSIF wParam = VK_F3     THEN FindNextCmd; Refresh
      ELSIF wParam = VK_F9     THEN Compile(FALSE); Refresh
      ELSIF wParam = VK_F5     THEN Compile(TRUE); Refresh
      END
    END;
    RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

VAR cw, ch: CARDINAL; ok: BOOLEAN;
BEGIN
  gNL[0] := CHR(10); gNL[1] := 0C;
  gPos := 0; gAnchor := 0; gHasSel := FALSE; gTopLine := 0; gLeft := 0; gGoal := 0;
  gModified := FALSE; gMsg[0] := 0C; gOut := Empty(); gOutTop := 0;
  gMenuActive := FALSE; gEatChar := FALSE; gShiftDown := FALSE; gAbout := FALSE;
  gDragging := FALSE; gSplitDrag := FALSE; gSplitRows := 0; gFollowCursor := TRUE;
  gPromptMode := PromNone; gPromptLen := 0; gPromptBuf[0] := 0C;
  gFind[0] := 0C; gReplace[0] := 0C; gRecentCount := 0;
  gReqCols := 104; gReqRows := 40;
  SCopy(gFile, WorkFile);
  Welcome;
  LoadRecent;
  ok := Startup("Consolas", VAL(SHORTREAL, 15.0));
  Init(gReqCols, gReqRows);
  gCols := Cols(); gRows := Rows();
  Clear;
  SetupMenus;
  Layout;
  gWin := CreateAppWindow("FastM2 - Modula-2 IDE", gCols*CellW + 16, gRows*CellH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, ch);
  ok := Attach(gWin, cw, ch, CellW, CellH);
  Render; Paint(); Repaint(gWin);
  RunMessageLoop()
END FastM2.
