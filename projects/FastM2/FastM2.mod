MODULE FastM2;
(*
 * FastM2 — a single-window Modula-2 IDE in the spirit of Turbo Pascal / QuickBASIC,
 * written in Modula-2 on the WindowsModula2 stack it edits. A menu bar (F10), a
 * syntax-highlighted code editor over a TextRope buffer, an output pane, and a
 * status line — rendered with Direct2D via TermRender (no GDI), mouse-aware.
 * F9 compiles and F5 runs the buffer by driving the `newm2` toolchain.
 *
 * The window is freely resizable: resizing does NOT scale the glyphs — instead the
 * grid grows/shrinks to fit the new client area at native cell size, so you get
 * more (or less) editable text, like a real terminal.
 *
 *   build: newm2 build projects/FastM2/FastM2.mod --library library
 *   F2 Save   F3 Open   F9 Compile   F5 Run   F10 Menu
 *
 * Paths to the compiler/library/work files are CONSTs below — edit for your tree.
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  RunMessageLoop, Quit;
FROM TermRender IMPORT Startup, Attach, Resize, Paint;
FROM Terminal IMPORT Init, Cols, Rows, Clear, Fill, WriteColAt, SetStatus, Colour,
  Black, Navy, Silver, Gray, White, Yellow, Aqua, Red, Teal,
  MenuClear, MenuAdd, MenuAddItem, MenuSelect, MenuRender, MenuClose, MenuIsOpen,
  HandleKey, NextEvent, Event, EvMenuItem, EvMenuClose,
  KeyNone, KeyLeft, KeyRight, KeyUp, KeyDown, KeyEnter, KeyEsc, KeyTab;
FROM TextRope IMPORT Rope, Empty, FromString, Length, CharAt, Insert,
  DeleteRange, Append, Free;
FROM RunProg IMPORT PerformCommand, SyncExec, ExecFlagSet;
FROM Dialogs IMPORT OpenFile, SaveFile, Confirm;
IMPORT SeqFile, TextIO, IOResult, ChanConsts, IOConsts;
FROM WholeStr IMPORT CardToStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  CellW = 9; CellH = 18;                (* native pixels per character cell *)
  GutterW = 5;                         (* line-number gutter columns *)
  CodeX = GutterW;                     (* code starts after the gutter *)
  EdTop = 1;                           (* editor starts under the menu bar (row 0) *)
  MinCols = 30; MinRows = 12;          (* smallest usable grid on resize *)

  (* colours *)
  EdBg = Navy; CodeFg = Silver; KwFg = White; ComFg = Gray; StrFg = Yellow;
  NumFg = Aqua; GutFg = Teal; CurFg = Navy; CurBg = White;
  MenuFg = Black; MenuBg = Silver; OutBg = Black; OutFg = Silver; ErrFg = Red;

  (* toolchain — EDIT THESE for your tree *)
  Compiler = "e:\NewModula2\target\debug\newm2-driver.exe";
  LibPath  = "e:\NewModula2\library";
  WorkFile = "e:\NewModula2\projects\FastM2\fastm2_work.mod";
  OutFile  = "e:\NewModula2\projects\FastM2\fastm2_out.txt";

  WM_DESTROY = 2; WM_SIZE = 5; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  WM_SYSKEYDOWN = 260; WM_LBUTTONDOWN = 513;
  VK_BACK = 08H; VK_RETURN = 0DH; VK_ESCAPE = 1BH;
  VK_PRIOR = 21H; VK_NEXT = 22H; VK_END = 23H; VK_HOME = 24H;
  VK_LEFT = 25H; VK_UP = 26H; VK_RIGHT = 27H; VK_DOWN = 28H;
  VK_DELETE = 2EH; VK_F2 = 71H; VK_F3 = 72H; VK_F5 = 74H; VK_F9 = 78H;
  VK_F10 = 79H; VK_TAB = 09H;

VAR
  gWin:     Window;
  gDoc:     Rope;                      (* editor buffer *)
  gPos:     CARDINAL;                  (* cursor char index *)
  gTopLine, gLeft, gGoal: CARDINAL;    (* scroll + desired column *)
  gModified: BOOLEAN;
  gOut:     Rope;                      (* output pane buffer (read-only) *)
  gOutTop:  CARDINAL;
  gMsg:     ARRAY [0..63] OF CHAR;     (* transient status note *)
  gNL:      ARRAY [0..1] OF CHAR;
  gFile:    ARRAY [0..519] OF CHAR;    (* current file path (in/out of the dialogs) *)
  gMenuActive: BOOLEAN;                (* TRUE when the menu bar has focus *)
  gEatChar: BOOLEAN;                   (* swallow the WM_CHAR paired with a menu Enter/Tab *)
  (* dynamic layout — recomputed by Layout from the live grid size *)
  gCols, gRows: CARDINAL;              (* the live grid size (== Terminal.Cols/Rows) *)
  gReqCols, gReqRows: CARDINAL;        (* last grid size requested from a resize (pre-clamp) *)
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

(* ---- Modula-2 syntax tokeniser ----------------------------------------- *)

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
  FOR i := 0 TO (b - a) - 1 DO IF s[a + i] # kw[i] THEN RETURN FALSE END END;
  RETURN TRUE
END WordEq;

(* Is s[a..b-1] (already upper-cased) a reserved word? *)
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

(* Colour a single line `s[0..len-1]` into `col`, tracking the comment depth
   across lines (depthIO in/out). *)
PROCEDURE ColourLine (VAR s: ARRAY OF CHAR; len: CARDINAL; VAR depthIO: CARDINAL;
                      VAR col: ARRAY OF Colour);
  VAR i, a, depth: CARDINAL; q: CHAR; up: ARRAY [0..255] OF CHAR; w: CARDINAL;
BEGIN
  depth := depthIO; i := 0;
  WHILE i < len DO
    IF depth > 0 THEN                                  (* inside a comment *)
      IF (s[i] = '(') AND (i+1 < len) AND (s[i+1] = '*') THEN
        col[i] := ComFg; col[i+1] := ComFg; INC(depth); i := i + 2
      ELSIF (s[i] = '*') AND (i+1 < len) AND (s[i+1] = ')') THEN
        col[i] := ComFg; col[i+1] := ComFg; DEC(depth); i := i + 2
      ELSE col[i] := ComFg; INC(i) END
    ELSIF (s[i] = '(') AND (i+1 < len) AND (s[i+1] = '*') THEN
      col[i] := ComFg; col[i+1] := ComFg; INC(depth); i := i + 2
    ELSIF (s[i] = '"') OR (s[i] = "'") THEN            (* string *)
      q := s[i]; col[i] := StrFg; INC(i);
      WHILE (i < len) AND (s[i] # q) DO col[i] := StrFg; INC(i) END;
      IF i < len THEN col[i] := StrFg; INC(i) END
    ELSIF IsDigit(s[i]) THEN                           (* number *)
      WHILE (i < len) AND (IsAlnum(s[i]) OR (s[i] = '.')) DO col[i] := NumFg; INC(i) END
    ELSIF IsAlpha(s[i]) THEN                           (* word: keyword or ident *)
      a := i; w := 0;
      WHILE (i < len) AND IsAlnum(s[i]) DO
        IF w <= 255 THEN up[w] := Up(s[i]); INC(w) END; INC(i)
      END;
      IF IsKeyword(up, 0, w) THEN
        WHILE a < i DO col[a] := KwFg; INC(a) END
      ELSE WHILE a < i DO col[a] := CodeFg; INC(a) END END
    ELSE col[i] := CodeFg; INC(i) END
  END;
  depthIO := depth
END ColourLine;

(* Copy line `line` of `r` into `buf` (truncated), return its length. *)
PROCEDURE GetLine (r: Rope; line: CARDINAL; VAR buf: ARRAY OF CHAR): CARDINAL;
  VAR s, n, i: CARDINAL;
BEGIN
  s := LineStart(r, line); n := LineLen(r, line);
  IF n > HIGH(buf) THEN n := HIGH(buf) END;
  FOR i := 0 TO n-1 DO buf[i] := CharAt(r, s + i) END;
  buf[n] := 0C; RETURN n
END GetLine;

(* ---- layout + menus ---------------------------------------------------- *)

(* Recompute the pane geometry from the live grid size (gCols x gRows):
   row 0 = menu bar, last row = status; the rest splits ~3:1 editor:output. *)
PROCEDURE Layout;
BEGIN
  gCodeW := gCols - GutterW;
  gOutRows := (gRows - 3) DIV 4;
  IF gOutRows < 4 THEN gOutRows := 4 END;
  IF gOutRows > gRows - 3 - 1 THEN gOutRows := gRows - 3 - 1 END;
  gEdRows := (gRows - 3) - gOutRows;
  IF gEdRows < 1 THEN gEdRows := 1 END;
  gOutTitle := EdTop + gEdRows;
  gOutTop2 := gOutTitle + 1
END Layout;

PROCEDURE SetupMenus;
BEGIN
  MenuClear;
  MenuAdd("File");  MenuAddItem(0, "New");  MenuAddItem(0, "Open...");
                    MenuAddItem(0, "Save"); MenuAddItem(0, "Save As...");
                    MenuAddItem(0, "Quit");
  MenuAdd("Build"); MenuAddItem(1, "Compile  F9"); MenuAddItem(1, "Run  F5");
  MenuAdd("Help");  MenuAddItem(2, "About");
  MenuSelect(0)
END SetupMenus;

(* ---- the starter document ---------------------------------------------- *)

PROCEDURE Welcome;
BEGIN
  gDoc := Empty();
  gDoc := Append(gDoc, "MODULE Hello;"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "FROM STextIO IMPORT WriteString, WriteLn;"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "BEGIN"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, '  WriteString("hello from FastM2"); WriteLn'); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "END Hello.")
END Welcome;

(* ---- rendering --------------------------------------------------------- *)

PROCEDURE ShowStatus;
  VAR b: ARRAY [0..159] OF CHAR; num: ARRAY [0..15] OF CHAR; nm: ARRAY [0..127] OF CHAR;
      pos, line, c: CARDINAL;
BEGIN
  PosToLineCol(gDoc, gPos, line, c); pos := 0;
  Basename(gFile, nm);
  AppendStr(b, pos, " "); AppendStr(b, pos, nm);
  IF gModified THEN AppendStr(b, pos, "*") END;
  AppendStr(b, pos, "   Ln "); CardToStr(line+1, num); AppendStr(b, pos, num);
  AppendStr(b, pos, " Col "); CardToStr(c+1, num); AppendStr(b, pos, num);
  AppendStr(b, pos, "   ");
  IF gMsg[0] # 0C THEN AppendStr(b, pos, gMsg); AppendStr(b, pos, "   ") END;
  AppendStr(b, pos, "| F2 Save  F3 Open  F9 Compile  F5 Run  F10 Menu ");
  SetStatus(b)
END ShowStatus;

PROCEDURE RenderEditor;
  VAR curLine, curCol, sr, line, n, c, scol, depth: CARDINAL;
      buf: ARRAY [0..511] OF CHAR; col: ARRAY [0..511] OF Colour;
      num: ARRAY [0..15] OF CHAR; total: CARDINAL; ch: CHAR;
BEGIN
  PosToLineCol(gDoc, gPos, curLine, curCol);
  IF curLine < gTopLine THEN gTopLine := curLine
  ELSIF curLine >= gTopLine + gEdRows THEN gTopLine := curLine - gEdRows + 1 END;
  IF curCol < gLeft THEN gLeft := curCol
  ELSIF curCol >= gLeft + gCodeW THEN gLeft := curCol - gCodeW + 1 END;

  total := LineCount(gDoc);
  (* comment depth at the top visible line: scan the lines above the viewport *)
  depth := 0; line := 0;
  WHILE line < gTopLine DO
    n := GetLine(gDoc, line, buf);
    FOR c := 0 TO n DO col[c] := CodeFg END;        (* scratch; colours discarded *)
    ColourLine(buf, n, depth, col);
    INC(line)
  END;

  Fill(0, EdTop, gCols, gEdRows, ' ', CodeFg, EdBg);
  FOR sr := 0 TO gEdRows-1 DO
    line := gTopLine + sr;
    IF line < total THEN
      CardToStr(line+1, num);
      WriteColAt(0, EdTop+sr, GutFg, EdBg, num);     (* line-number gutter *)
      n := GetLine(gDoc, line, buf);
      FOR c := 0 TO n DO col[c] := CodeFg END;
      ColourLine(buf, n, depth, col);
      c := gLeft;
      WHILE (c < n) AND (c < gLeft + gCodeW) DO
        scol := CodeX + (c - gLeft);
        Fill(scol, EdTop+sr, 1, 1, buf[c], col[c], EdBg);
        INC(c)
      END
    END
  END;

  (* cursor (reverse video); the scroll adjust above keeps it on screen *)
  IF gPos < Length(gDoc) THEN ch := CharAt(gDoc, gPos); IF ch = CHR(10) THEN ch := ' ' END
  ELSE ch := ' ' END;
  Fill(CodeX + (curCol - gLeft), EdTop + (curLine - gTopLine), 1, 1, ch, CurFg, CurBg)
END RenderEditor;

PROCEDURE RenderOutput;
  VAR sr, line, n, total, i: CARDINAL; buf: ARRAY [0..255] OF CHAR; fg: Colour;
BEGIN
  Fill(0, gOutTitle, gCols, 1, ' ', White, Teal);
  WriteColAt(2, gOutTitle, White, Teal, "Output");
  Fill(0, gOutTop2, gCols, gOutRows, ' ', OutFg, OutBg);
  total := LineCount(gOut);
  FOR sr := 0 TO gOutRows-1 DO
    line := gOutTop + sr;
    IF line < total THEN
      n := GetLine(gOut, line, buf);
      fg := OutFg;
      i := 0;                                          (* redden lines mentioning "error" *)
      WHILE i + 5 <= n DO
        IF (buf[i]='e') AND (buf[i+1]='r') AND (buf[i+2]='r') AND (buf[i+3]='o') AND (buf[i+4]='r')
          THEN fg := ErrFg END;
        INC(i)
      END;
      WriteColAt(1, gOutTop2+sr, fg, OutBg, buf)
    END
  END
END RenderOutput;

PROCEDURE Render;
BEGIN RenderEditor; RenderOutput; ShowStatus; MenuRender END Render;

PROCEDURE Refresh;
BEGIN Render; Repaint(gWin) END Refresh;

(* ---- editing ----------------------------------------------------------- *)

PROCEDURE ClearMsg; BEGIN gMsg[0] := 0C END ClearMsg;

PROCEDURE InsertText (s: ARRAY OF CHAR);
BEGIN gDoc := Insert(gDoc, gPos, s); gPos := gPos + SLen(s); gModified := TRUE; ClearMsg END InsertText;

PROCEDURE InsertCh (ch: CHAR);
  VAR s: ARRAY [0..1] OF CHAR;
BEGIN s[0] := ch; s[1] := 0C; InsertText(s) END InsertCh;

PROCEDURE Backspace;
BEGIN IF gPos > 0 THEN gDoc := DeleteRange(gDoc, gPos-1, 1); DEC(gPos); gModified := TRUE; ClearMsg END END Backspace;

PROCEDURE DeleteFwd;
BEGIN IF gPos < Length(gDoc) THEN gDoc := DeleteRange(gDoc, gPos, 1); gModified := TRUE; ClearMsg END END DeleteFwd;

PROCEDURE SetGoal;
  VAR l, c: CARDINAL;
BEGIN PosToLineCol(gDoc, gPos, l, c); gGoal := c END SetGoal;

PROCEDURE GotoLineCol (line, col: CARDINAL);
  VAR ll: CARDINAL;
BEGIN ll := LineLen(gDoc, line); IF col > ll THEN col := ll END; gPos := LineStart(gDoc, line) + col END GotoLineCol;

PROCEDURE MoveLeft;  BEGIN IF gPos > 0 THEN DEC(gPos) END; SetGoal END MoveLeft;
PROCEDURE MoveRight; BEGIN IF gPos < Length(gDoc) THEN INC(gPos) END; SetGoal END MoveRight;
PROCEDURE MoveUp; VAR l,c: CARDINAL; BEGIN PosToLineCol(gDoc,gPos,l,c); IF l>0 THEN GotoLineCol(l-1,gGoal) END END MoveUp;
PROCEDURE MoveDown; VAR l,c: CARDINAL; BEGIN PosToLineCol(gDoc,gPos,l,c); IF l+1 < LineCount(gDoc) THEN GotoLineCol(l+1,gGoal) END END MoveDown;
PROCEDURE MoveHome; VAR l,c: CARDINAL; BEGIN PosToLineCol(gDoc,gPos,l,c); gPos := LineStart(gDoc,l); gGoal := 0 END MoveHome;
PROCEDURE MoveEnd; VAR l,c: CARDINAL; BEGIN PosToLineCol(gDoc,gPos,l,c); gPos := LineStart(gDoc,l)+LineLen(gDoc,l); gGoal := LineLen(gDoc,l) END MoveEnd;
PROCEDURE PageBy (up: BOOLEAN);
  VAR l, c, t: CARDINAL;
BEGIN
  PosToLineCol(gDoc, gPos, l, c);
  IF up THEN IF l >= gEdRows THEN t := l - gEdRows ELSE t := 0 END
  ELSE t := l + gEdRows; IF t >= LineCount(gDoc) THEN t := LineCount(gDoc)-1 END END;
  GotoLineCol(t, gGoal)
END PageBy;

PROCEDURE Click (lParam: CARDINAL);
  VAR px, py, tc, tr, line, col: CARDINAL;
BEGIN
  px := lParam MOD 65536; py := lParam DIV 65536;
  tc := px DIV CellW; tr := py DIV CellH;
  IF (tr < EdTop) OR (tr >= EdTop + gEdRows) OR (tc < CodeX) THEN RETURN END;
  line := gTopLine + (tr - EdTop); col := gLeft + (tc - CodeX);
  IF line >= LineCount(gDoc) THEN line := LineCount(gDoc)-1 END;
  GotoLineCol(line, col); gGoal := col
END Click;

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

(* Read `name` into a fresh rope (NIL on failure). *)
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

PROCEDURE OkToDiscard (): BOOLEAN;
BEGIN
  IF NOT gModified THEN RETURN TRUE END;
  RETURN Confirm(gWin, "Discard unsaved changes?", "FastM2")
END OkToDiscard;

PROCEDURE NewDoc;
BEGIN
  IF NOT OkToDiscard() THEN RETURN END;
  Free(gDoc); Welcome; SCopy(gFile, WorkFile);
  gPos := 0; gTopLine := 0; gLeft := 0; gGoal := 0; gModified := FALSE;
  SCopy(gMsg, "new")
END NewDoc;

PROCEDURE OpenDoc;
BEGIN
  IF NOT OkToDiscard() THEN RETURN END;
  IF OpenFile(gWin, gFile, "Modula-2|*.mod;*.def|All files|*.*", "Open") THEN
    Free(gDoc); gDoc := ReadFileRope(gFile);
    IF Length(gDoc) = 0 THEN gDoc := FromString("MODULE Untitled;") END;
    gPos := 0; gTopLine := 0; gLeft := 0; gGoal := 0; gModified := FALSE;
    SCopy(gMsg, "opened")
  END
END OpenDoc;

PROCEDURE DoSave;
BEGIN
  IF SaveDoc() THEN gModified := FALSE; SCopy(gMsg, "saved")
  ELSE SCopy(gMsg, "save FAILED") END
END DoSave;

PROCEDURE SaveAs;
BEGIN
  IF SaveFile(gWin, gFile, "Modula-2|*.mod;*.def|All files|*.*", "Save As", "mod") THEN DoSave END
END SaveAs;

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
  (* scan the output for the first  <name>:<line>:  and jump there *)
  total := LineCount(gOut); found := FALSE; line := 0;
  WHILE (line < total) AND NOT found DO
    n := GetLine(gOut, line, buf);
    i := 0;
    WHILE (i < n) AND (buf[i] # ':') DO INC(i) END;
    IF (i < n) AND (i+1 < n) AND IsDigit(buf[i+1]) THEN
      ln := 0; INC(i);
      WHILE (i < n) AND IsDigit(buf[i]) DO ln := ln*10 + (ORD(buf[i]) - ORD('0')); INC(i) END;
      IF (ln > 0) AND (ln <= LineCount(gDoc)) THEN GotoLineCol(ln-1, 0); SetGoal; found := TRUE END
    END;
    INC(line)
  END
END JumpToError;

PROCEDURE Compile (run: BOOLEAN);
  VAR cmd: ARRAY [0..511] OF CHAR; status: CARDINAL; ok: BOOLEAN;
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

(* ---- menu ------------------------------------------------------------- *)

PROCEDURE ShowAbout;
BEGIN
  Free(gOut); gOut := Empty();
  gOut := Append(gOut, "FastM2 - a single-window Modula-2 IDE."); gOut := Append(gOut, gNL);
  gOut := Append(gOut, "Written in Modula-2 on the WindowsModula2 stack it edits."); gOut := Append(gOut, gNL);
  gOut := Append(gOut, "Keys:  F2 Save   F3 Open   F9 Compile   F5 Run   F10 Menu");
  gOutTop := 0; SCopy(gMsg, "about")
END ShowAbout;

PROCEDURE DispatchMenu (menu, item: CARDINAL);
BEGIN
  IF menu = 0 THEN                                     (* File *)
    IF    item = 0 THEN NewDoc
    ELSIF item = 1 THEN OpenDoc
    ELSIF item = 2 THEN DoSave
    ELSIF item = 3 THEN SaveAs
    ELSIF item = 4 THEN Quit END
  ELSIF menu = 1 THEN                                  (* Build *)
    IF item = 0 THEN Compile(FALSE) ELSE Compile(TRUE) END
  ELSIF menu = 2 THEN                                  (* Help *)
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
    IF MenuIsOpen() THEN MenuClose END;
    gMenuActive := FALSE
  ELSE
    gMenuActive := TRUE; MenuSelect(0)
  END
END ToggleMenu;

(* ---- window handler ---------------------------------------------------- *)

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; rb: BOOLEAN; ch: CHAR; key, cw, chh, nc, nr: CARDINAL;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Paint(); ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_SIZE THEN
    ClientSize(w, cw, chh);
    IF (cw > 0) AND (chh > 0) THEN
      nc := cw DIV CellW; nr := chh DIV CellH;
      IF nc < MinCols THEN nc := MinCols END;
      IF nr < MinRows THEN nr := MinRows END;
      IF (nc # gReqCols) OR (nr # gReqRows) THEN
        gReqCols := nc; gReqRows := nr;
        Init(nc, nr);                    (* re-size + clear the model (clamps to its max, wipes menus) *)
        gCols := Cols(); gRows := Rows();  (* read the model's clamped truth back *)
        SetupMenus; Layout; gMenuActive := FALSE
      END;
      rb := Resize(cw, chh);             (* match the D2D target to the client px *)
      Render; Paint(); ok := ValidateRect(w, NIL)
    END;
    RETURN 0
  ELSIF msg = WM_LBUTTONDOWN THEN
    IF gMenuActive OR MenuIsOpen() THEN
      IF MenuIsOpen() THEN MenuClose END; gMenuActive := FALSE; Refresh
    ELSE Click(lParam); Refresh END;
    RETURN 0
  ELSIF msg = WM_CHAR THEN
    IF gEatChar THEN gEatChar := FALSE; RETURN 0 END;   (* the char paired with a menu Enter/Tab *)
    IF NOT (gMenuActive OR MenuIsOpen()) THEN
      ch := CHR(wParam);
      IF ch = CHR(VK_RETURN) THEN InsertText(gNL); SetGoal; Refresh
      ELSIF ch = CHR(VK_BACK) THEN Backspace; SetGoal; Refresh
      ELSIF ch = CHR(9) THEN InsertText("  "); SetGoal; Refresh
      ELSIF ch >= ' ' THEN InsertCh(ch); SetGoal; Refresh END
    END;
    RETURN 0
  ELSIF msg = WM_SYSKEYDOWN THEN
    IF wParam = VK_F10 THEN ToggleMenu; Refresh; RETURN 0 END;
    handled := FALSE; RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    gEatChar := FALSE;
    IF gMenuActive OR MenuIsOpen() THEN
      key := MapVK(wParam);
      IF key # KeyNone THEN
        IF HandleKey(key, 0C) THEN
          IF (key = KeyEnter) OR (key = KeyTab) THEN gEatChar := TRUE END;  (* eat its WM_CHAR *)
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
      ELSIF wParam = VK_F3     THEN OpenDoc; Refresh
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
  gPos := 0; gTopLine := 0; gLeft := 0; gGoal := 0; gModified := FALSE;
  gMsg[0] := 0C; gOut := Empty(); gOutTop := 0; gMenuActive := FALSE; gEatChar := FALSE;
  gReqCols := 104; gReqRows := 40;
  SCopy(gFile, WorkFile);
  Welcome;
  ok := Startup("Consolas", VAL(SHORTREAL, 15.0));
  Init(gReqCols, gReqRows);
  gCols := Cols(); gRows := Rows();     (* the model's clamped truth *)
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
