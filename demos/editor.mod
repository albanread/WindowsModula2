MODULE Editor;
(*
 * A notepad-like text editor in pure Modula-2, on the Terminal cell grid
 * (Direct2D/DirectWrite via TermRender, window + loop via WinShell). The document
 * is a TextRope (library/utilmod/TextRope), so every keystroke's insert/delete is
 * an O(log n) rope edit, not a big-array shift. It also exercises ISO file I/O —
 * F2 saves the buffer to a text file, F3 loads it back (SeqFile + TextIO).
 *
 *   build: newm2 build demos/editor.mod   then run the .exe
 *   type / Enter / Backspace / Del          edit
 *   arrows / Home / End / PgUp / PgDn        move; click to place the cursor
 *   F2  save to notepad.txt                  F3  load it back        Esc  quit
 *)
FROM WinShell IMPORT Window, CreateAppWindow, Show, ClientSize, Repaint,
  RunMessageLoop, Quit;
FROM TermRender IMPORT Startup, Attach, Paint;
FROM Terminal IMPORT Init, Clear, Fill, WriteColAt, SetStatus, Colour,
  Black, White, Silver, Gray, Navy, Aqua, Yellow, Lime;
FROM TextRope IMPORT Rope, Empty, FromString, Length, CharAt, Insert,
  DeleteRange, Append, Free;
IMPORT SeqFile, TextIO, IOResult, ChanConsts, IOConsts;
FROM WholeStr IMPORT CardToStr;
FROM Graphics_Gdi IMPORT ValidateRect;
FROM WIN32 IMPORT BOOL;

CONST
  Cols = 100; Rows = 38; CellW = 9; CellH = 18;
  TW = Cols;            (* text-area width in cells *)
  TH = Rows - 2;        (* text-area height: row 0 = title, last row = status *)

  TextFg = Silver; TextBg = Navy;
  CursorFg = Navy; CursorBg = White;
  TitleFg = White; TitleBg = Gray;

  WM_DESTROY = 2; WM_PAINT = 15; WM_KEYDOWN = 256; WM_CHAR = 258;
  WM_LBUTTONDOWN = 513;
  VK_BACK = 08H; VK_RETURN = 0DH; VK_ESCAPE = 1BH;
  VK_PRIOR = 21H; VK_NEXT = 22H; VK_END = 23H; VK_HOME = 24H;
  VK_LEFT = 25H; VK_UP = 26H; VK_RIGHT = 27H; VK_DOWN = 28H;
  VK_DELETE = 2EH; VK_F2 = 71H; VK_F3 = 72H;

  FileName = "notepad.txt";

VAR
  gWin:     Window;
  gDoc:     Rope;
  gPos:     CARDINAL;        (* cursor character index, 0 .. Length(gDoc) *)
  gTopLine: CARDINAL;        (* first visible document line *)
  gLeft:    CARDINAL;        (* first visible column (horizontal scroll) *)
  gGoal:    CARDINAL;        (* desired column for vertical movement *)
  gModified: BOOLEAN;
  gMsg:     ARRAY [0..63] OF CHAR;   (* transient status note *)
  gNL:      ARRAY [0..1] OF CHAR;    (* a one-char newline string *)

(* ---- small string helpers --------------------------------------------- *)

PROCEDURE SLen (s: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO INC(i) END;
  RETURN i
END SLen;

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

(* ---- document line / column geometry (scan-based; O(n)) ---------------- *)

PROCEDURE PosToLineCol (pos: CARDINAL; VAR line, col: CARDINAL);
  VAR i: CARDINAL;
BEGIN
  line := 0; col := 0; i := 0;
  WHILE i < pos DO
    IF CharAt(gDoc, i) = CHR(10) THEN INC(line); col := 0 ELSE INC(col) END;
    INC(i)
  END
END PosToLineCol;

PROCEDURE LineCount (): CARDINAL;
  VAR i, len, n: CARDINAL;
BEGIN
  len := Length(gDoc); n := 1; i := 0;
  WHILE i < len DO IF CharAt(gDoc, i) = CHR(10) THEN INC(n) END; INC(i) END;
  RETURN n
END LineCount;

PROCEDURE LineStart (line: CARDINAL): CARDINAL;
  VAR i, len, ln: CARDINAL;
BEGIN
  IF line = 0 THEN RETURN 0 END;
  len := Length(gDoc); ln := 0; i := 0;
  WHILE i < len DO
    IF CharAt(gDoc, i) = CHR(10) THEN
      INC(ln);
      IF ln = line THEN RETURN i + 1 END
    END;
    INC(i)
  END;
  RETURN len
END LineStart;

PROCEDURE LineLen (line: CARDINAL): CARDINAL;
  VAR s, i, len: CARDINAL;
BEGIN
  s := LineStart(line); len := Length(gDoc); i := s;
  WHILE (i < len) AND (CharAt(gDoc, i) # CHR(10)) DO INC(i) END;
  RETURN i - s
END LineLen;

(* ---- rendering --------------------------------------------------------- *)

PROCEDURE ShowStatus;
  VAR buf: ARRAY [0..119] OF CHAR; num: ARRAY [0..15] OF CHAR;
      pos, line, col: CARDINAL;
BEGIN
  PosToLineCol(gPos, line, col);
  pos := 0;
  AppendStr(buf, pos, " ");
  AppendStr(buf, pos, FileName);
  IF gModified THEN AppendStr(buf, pos, "*") END;
  AppendStr(buf, pos, "  Ln "); CardToStr(line + 1, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, " Col "); CardToStr(col + 1, num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, "  ("); CardToStr(Length(gDoc), num); AppendStr(buf, pos, num);
  AppendStr(buf, pos, " chars)  ");
  IF gMsg[0] # 0C THEN AppendStr(buf, pos, gMsg); AppendStr(buf, pos, "  ") END;
  AppendStr(buf, pos, "| F2 save  F3 load  Esc quit ");
  SetStatus(buf)
END ShowStatus;

PROCEDURE Render;
  VAR curLine, curCol, idx, len, sr, c, scol, csr, csc: CARDINAL; ch: CHAR;
BEGIN
  PosToLineCol(gPos, curLine, curCol);
  IF curLine < gTopLine THEN gTopLine := curLine
  ELSIF curLine >= gTopLine + TH THEN gTopLine := curLine - TH + 1 END;
  IF curCol < gLeft THEN gLeft := curCol
  ELSIF curCol >= gLeft + TW THEN gLeft := curCol - TW + 1 END;

  Fill(0, 1, TW, TH, ' ', TextFg, TextBg);          (* clear text area *)

  len := Length(gDoc);
  idx := LineStart(gTopLine);
  sr := 0;
  WHILE sr < TH DO
    c := 0;
    LOOP
      IF idx >= len THEN sr := TH; EXIT END;        (* end of document *)
      ch := CharAt(gDoc, idx);
      IF ch = CHR(10) THEN INC(idx); EXIT END;      (* end of this line *)
      IF (c >= gLeft) AND (c < gLeft + TW) THEN
        scol := c - gLeft;
        Fill(scol, 1 + sr, 1, 1, ch, TextFg, TextBg)
      END;
      INC(c); INC(idx)
    END;
    INC(sr)
  END;

  (* cursor (reverse video) — guaranteed visible by the scroll adjust above *)
  csr := curLine - gTopLine; csc := curCol - gLeft;
  IF gPos < len THEN ch := CharAt(gDoc, gPos); IF ch = CHR(10) THEN ch := ' ' END
  ELSE ch := ' ' END;
  Fill(csc, 1 + csr, 1, 1, ch, CursorFg, CursorBg);

  ShowStatus
END Render;

PROCEDURE Refresh;
BEGIN Render; Repaint(gWin) END Refresh;

(* ---- editing ----------------------------------------------------------- *)

PROCEDURE ClearMsg; BEGIN gMsg[0] := 0C END ClearMsg;

PROCEDURE InsertText (s: ARRAY OF CHAR);
BEGIN
  gDoc := Insert(gDoc, gPos, s);
  gPos := gPos + SLen(s);
  gModified := TRUE; ClearMsg
END InsertText;

PROCEDURE InsertCharVal (ch: CHAR);
  VAR s: ARRAY [0..1] OF CHAR;
BEGIN
  s[0] := ch; s[1] := 0C; InsertText(s)
END InsertCharVal;

PROCEDURE Backspace;
BEGIN
  IF gPos > 0 THEN
    gDoc := DeleteRange(gDoc, gPos - 1, 1); DEC(gPos);
    gModified := TRUE; ClearMsg
  END
END Backspace;

PROCEDURE DeleteFwd;
BEGIN
  IF gPos < Length(gDoc) THEN
    gDoc := DeleteRange(gDoc, gPos, 1); gModified := TRUE; ClearMsg
  END
END DeleteFwd;

PROCEDURE SetGoal;
  VAR l, c: CARDINAL;
BEGIN PosToLineCol(gPos, l, c); gGoal := c END SetGoal;

(* ---- cursor movement --------------------------------------------------- *)

PROCEDURE MoveLeft;  BEGIN IF gPos > 0 THEN DEC(gPos) END; SetGoal END MoveLeft;
PROCEDURE MoveRight; BEGIN IF gPos < Length(gDoc) THEN INC(gPos) END; SetGoal END MoveRight;

PROCEDURE GotoLineCol (line, col: CARDINAL);
  VAR ll: CARDINAL;
BEGIN
  ll := LineLen(line);
  IF col > ll THEN col := ll END;
  gPos := LineStart(line) + col
END GotoLineCol;

PROCEDURE MoveUp;
  VAR l, c: CARDINAL;
BEGIN
  PosToLineCol(gPos, l, c);
  IF l > 0 THEN GotoLineCol(l - 1, gGoal) END
END MoveUp;

PROCEDURE MoveDown;
  VAR l, c: CARDINAL;
BEGIN
  PosToLineCol(gPos, l, c);
  IF l + 1 < LineCount() THEN GotoLineCol(l + 1, gGoal) END
END MoveDown;

PROCEDURE MoveHome;
  VAR l, c: CARDINAL;
BEGIN PosToLineCol(gPos, l, c); gPos := LineStart(l); gGoal := 0 END MoveHome;

PROCEDURE MoveEnd;
  VAR l, c: CARDINAL;
BEGIN
  PosToLineCol(gPos, l, c);
  gPos := LineStart(l) + LineLen(l); gGoal := LineLen(l)
END MoveEnd;

PROCEDURE PageBy (up: BOOLEAN);
  VAR l, c, target: CARDINAL;
BEGIN
  PosToLineCol(gPos, l, c);
  IF up THEN
    IF l >= TH THEN target := l - TH ELSE target := 0 END
  ELSE
    target := l + TH;
    IF target >= LineCount() THEN target := LineCount() - 1 END
  END;
  GotoLineCol(target, gGoal)
END PageBy;

PROCEDURE ClickTo (lParam: CARDINAL);
  VAR px, py, tc, tr, line, col: CARDINAL;
BEGIN
  px := lParam MOD 65536; py := lParam DIV 65536;
  tc := px DIV CellW; tr := py DIV CellH;
  IF tr < 1 THEN RETURN END;                        (* title row *)
  IF tr > TH THEN RETURN END;                       (* status row / below *)
  line := gTopLine + (tr - 1);
  col  := gLeft + tc;
  IF line >= LineCount() THEN line := LineCount() - 1 END;
  GotoLineCol(line, col); gGoal := col
END ClickTo;

(* ---- file I/O (validated separately, headless) ------------------------- *)

PROCEDURE SaveFile (): BOOLEAN;
  VAR cid: SeqFile.ChanId; res: ChanConsts.OpenResults; i, n: CARDINAL; ch: CHAR;
BEGIN
  SeqFile.OpenWrite(cid, FileName, SeqFile.write + SeqFile.text, res);
  IF res # ChanConsts.opened THEN RETURN FALSE END;
  n := Length(gDoc); i := 0;
  WHILE i < n DO
    ch := CharAt(gDoc, i);
    IF ch = CHR(10) THEN TextIO.WriteLn(cid) ELSE TextIO.WriteChar(cid, ch) END;
    INC(i)
  END;
  SeqFile.Close(cid);
  RETURN TRUE
END SaveFile;

PROCEDURE LoadFile (): BOOLEAN;
  VAR cid: SeqFile.ChanId; res: ChanConsts.OpenResults; buf: ARRAY [0..255] OF CHAR;
      rr: IOConsts.ReadResults; nu: Rope; done: BOOLEAN;
BEGIN
  SeqFile.OpenRead(cid, FileName, SeqFile.read + SeqFile.text, res);
  IF res # ChanConsts.opened THEN RETURN FALSE END;
  nu := Empty(); done := FALSE;
  WHILE NOT done DO
    TextIO.ReadString(cid, buf);
    nu := Append(nu, buf);
    rr := IOResult.ReadResult(cid);
    IF rr = IOConsts.endOfLine THEN
      nu := Append(nu, gNL); TextIO.SkipLine(cid)
    ELSIF rr = IOConsts.endOfInput THEN
      done := TRUE
    END
  END;
  SeqFile.Close(cid);
  Free(gDoc);
  gDoc := nu; gPos := 0; gTopLine := 0; gLeft := 0; gGoal := 0;
  RETURN TRUE
END LoadFile;

(* ---- window handler ---------------------------------------------------- *)

PROCEDURE Handler (w: Window; msg, wParam, lParam: CARDINAL; VAR handled: BOOLEAN): CARDINAL;
  VAR ok: BOOL; ch: CHAR;
BEGIN
  handled := TRUE;
  IF msg = WM_PAINT THEN
    Paint(); ok := ValidateRect(w, NIL); RETURN 0
  ELSIF msg = WM_CHAR THEN
    ch := CHR(wParam);
    IF ch = CHR(VK_RETURN) THEN InsertText(gNL); SetGoal; Refresh
    ELSIF ch = CHR(VK_BACK) THEN Backspace; SetGoal; Refresh
    ELSIF ch = CHR(9) THEN InsertText("    "); SetGoal; Refresh     (* tab -> 4 spaces *)
    ELSIF ch >= ' ' THEN InsertCharVal(ch); SetGoal; Refresh
    END;
    RETURN 0
  ELSIF msg = WM_KEYDOWN THEN
    IF    wParam = VK_LEFT   THEN MoveLeft;  Refresh
    ELSIF wParam = VK_RIGHT  THEN MoveRight; Refresh
    ELSIF wParam = VK_UP     THEN MoveUp;    Refresh
    ELSIF wParam = VK_DOWN   THEN MoveDown;  Refresh
    ELSIF wParam = VK_HOME   THEN MoveHome;  Refresh
    ELSIF wParam = VK_END    THEN MoveEnd;   Refresh
    ELSIF wParam = VK_PRIOR  THEN PageBy(TRUE);  Refresh
    ELSIF wParam = VK_NEXT   THEN PageBy(FALSE); Refresh
    ELSIF wParam = VK_DELETE THEN DeleteFwd; SetGoal; Refresh
    ELSIF wParam = VK_F2     THEN
      IF SaveFile() THEN gModified := FALSE; SCopy(gMsg, "saved") ELSE SCopy(gMsg, "save FAILED") END;
      Refresh
    ELSIF wParam = VK_F3     THEN
      IF LoadFile() THEN gModified := FALSE; SCopy(gMsg, "loaded") ELSE SCopy(gMsg, "load FAILED") END;
      Refresh
    ELSIF wParam = VK_ESCAPE THEN Quit
    END;
    RETURN 0
  ELSIF msg = WM_LBUTTONDOWN THEN
    ClickTo(lParam); Refresh; RETURN 0
  ELSIF msg = WM_DESTROY THEN
    Quit(); RETURN 0
  END;
  handled := FALSE; RETURN 0
END Handler;

PROCEDURE Welcome;
BEGIN
  gDoc := Empty();
  gDoc := Append(gDoc, "NewM2 Notepad - a rope-backed text editor."); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "Type to edit. Arrows / Home / End / PgUp / PgDn move;"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "Enter splits a line, Backspace / Del erase, click to place the cursor."); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "F2 saves this buffer to notepad.txt; F3 loads it back; Esc quits."); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "The buffer is a TextRope, so each edit is an O(log n) tree operation"); gDoc := Append(gDoc, gNL);
  gDoc := Append(gDoc, "rather than shifting a big character array."); gDoc := Append(gDoc, gNL)
END Welcome;

VAR cw, chh: CARDINAL; ok: BOOLEAN;
BEGIN
  gNL[0] := CHR(10); gNL[1] := 0C;
  gPos := 0; gTopLine := 0; gLeft := 0; gGoal := 0; gModified := FALSE; gMsg[0] := 0C;
  Welcome;
  ok := Startup("Consolas", VAL(SHORTREAL, 15.0));
  Init(Cols, Rows);
  Clear;
  WriteColAt(0, 0, TitleFg, TitleBg, "  NewM2 Notepad  -  rope-backed editor  (F2 save / F3 load / Esc quit)");
  gWin := CreateAppWindow("NewM2 Notepad", Cols*CellW + 16, Rows*CellH + 39, Handler);
  Show(gWin);
  ClientSize(gWin, cw, chh);
  ok := Attach(gWin, cw, chh, CellW, CellH);
  Render;
  Paint();
  Repaint(gWin);
  RunMessageLoop()
END Editor.
