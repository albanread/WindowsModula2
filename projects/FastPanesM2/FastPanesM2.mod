MODULE FastPanesM2;
(* FastPanesM2 — the FastM2 Modula-2 IDE rebuilt on the PaneShell GUI framework,
   using the SAME GPU-accelerated Terminal panes (Surface.NewTextGrid = Terminal +
   TermRender Direct2D) that give the original FastM2 its look: navy background,
   syntax colours, line-number gutter, status bar. The editor and the build-output
   are two TextGrid leaves in a reactive vertical Split (the divider is a real
   PaneShell splitter — drag it). The original projects/FastM2 is left untouched;
   the compile path reuses the same shared library modules (RunProg + NM2File).

   Keys:  printable -> insert,  Enter / Backspace,  arrows / Home / End / PgUp/PgDn,
   F9 = build the buffer and show the compiler output below.  Close with the X.

   Build:  newm2-driver build projects/FastPanesM2/FastPanesM2.mod
             --library library --out projects/FastPanesM2/FastPanesM2.exe *)
<*GUI*>

FROM SYSTEM IMPORT ADR, CAST, ADDRESS, ADRCARD;
FROM Surface IMPORT Backend, NewTextGrid, TermOf, VisibleCells, CellSize;
FROM PaneShell IMPORT Pane, PaneWindow, Workspace, Event, EvCloseRequest, EvResize,
  EvChar, EvKey, EvMouse, EvWheel, EvTimer, LeafPane, SetRect, Init, OpenWindow, Retile, Run, RunBounded, Quit,
  HostOf, FrameOf, RectOf, MouseAt, KeyDown;
FROM PaneLayout IMPORT Orientation, Split;
FROM UI_Input_KeyboardAndMouse IMPORT SetFocus;
FROM UI_WindowsAndMessaging IMPORT SetTimer, MoveWindow;
FROM System_SystemInformation IMPORT GetTickCount;
FROM System_Threading IMPORT Sleep;
FROM WIN32 IMPORT HWND, BOOL, PWSTR;
FROM System_LibraryLoader IMPORT GetModuleFileNameW;
FROM Harness IMPORT SnapClient, SendKey, SendKeyDown, SendKeyUp, SendChar, SendWheel, SendDrag, SendClick;
FROM Dialogs IMPORT OpenFile, SaveFile;
IMPORT Terminal;
FROM Terminal IMPORT Colour, Navy, Silver, White, Gray, Yellow, Aqua, Teal, Red, Black;
FROM RunProg IMPORT PerformCommand, SyncExec, RunProgram, ExecFlagSet, ExecAsync, ExecHidden, ExecDetached;
IMPORT NM2File;
IMPORT Clipboard;
FROM PipeClient IMPORT Ask;
IMPORT Ptcl;
IMPORT PipeServer;
IMPORT DirIter;
FROM PathStr IMPORT BaseName, Join;

CONST
  (* Compiler / LibPath / WorkFile / ExeFile / OutFile / Sample / DemoFile are
     computed at startup RELATIVE to this exe (see GetExeDir in BEGIN), so a
     self-contained release folder just works: the daemon + library + scratch all
     live beside FastPanesM2.exe. They are VARs (below), not consts. *)
  PipeName = "newm2";                     (* the resident compiler daemon's pipe *)
  IdePipe  = "fastpanes";                  (* the IDE's OWN pipe: external tools send ptcl here (Exec) *)
  EdCols   = 120; EdRows = 40;          (* editor grid *)
  OutCols  = 120; OutRows = 14;         (* output grid *)
  MaxLines = 4000; MaxCol = 400;
  UndoMax  = 32; UndoCap = 32767;       (* undo/redo: 32 snapshots, <=32KB each (compiler segfaults on bigger array elements) *)
  Gutter   = 5;                          (* line-number gutter width *)
  EdTop    = 2;                          (* editor text starts at row 2 (row 0 = menu bar, row 1 = tab strip) *)
  TabRow   = 1;                          (* the tab strip lives on editor-grid row 1 *)
  SelBg    = 0335A8AH;                    (* selection background (steel blue) *)
  BufMax   = 262143;
  MaxComp  = 128;                        (* autocomplete candidates held per query *)
  CompPopH = 10;                         (* max visible rows in the completion popup *)
  MaxDocs  = 16;                         (* open documents (tabs) *)
  TabW     = 18;                         (* fixed tab-chip width (cols) *)
  TabClose = 16;                         (* within-chip col of the close 'x' *)
  MaxTree  = 4000;                       (* visible rows in the file tree *)
  SideCols = 30; SideRows = 60;          (* sidebar grid model *)
  SideFrac = 0.18;                       (* sidebar fraction of the window width *)

VAR
  ws: Workspace; win: PaneWindow; root, edPane, outPane: Pane; edB, outB: Backend;
  edT, outT: Terminal.Instance;
  line: ARRAY [0..MaxLines-1] OF ARRAY [0..MaxCol] OF CHAR;   (* the text buffer, one NUL-term line each *)
  nLines, curRow, curCol, top, gLeft, outTop: CARDINAL;
  gMenuMode: BOOLEAN;                     (* TRUE while the menu bar has focus (keys drive the menu) *)
  gPrevBtn: CARDINAL;                     (* previous mouse button mask (for click edge-detect) *)
  gMouseSel: BOOLEAN;                      (* a left-button drag-select is in progress *)
  gSelActive: BOOLEAN;                    (* a selection is being made (anchor..cursor) *)
  gAnchRow, gAnchCol: CARDINAL;           (* the selection anchor (fixed end) *)
  gHasSel: BOOLEAN; gSelLoR, gSelLoC, gSelHiR, gSelHiC: CARDINAL;   (* normalised selection, set by RenderEditor for RenderLine *)
  gFollow: BOOLEAN;                       (* RenderEditor scrolls to keep the cursor visible (cleared for wheel) *)
  gOverflow: BOOLEAN;                     (* an edit hit a MaxCol/MaxLines cap (for truncation warnings) *)
  gFindMode: BOOLEAN;                     (* the status line is a Find prompt *)
  gFindTerm: ARRAY [0..127] OF CHAR;      (* the current search string *)
  gCmdMode: BOOLEAN;                      (* the status line is a ptcl command prompt (Ctrl+P) *)
  gCmdLine: ARRAY [0..511] OF CHAR;       (* the ptcl command being typed *)
  gAboutMode: BOOLEAN;                    (* the (non-modal) About overlay is showing *)
  gMsg: ARRAY [0..127] OF CHAR;          (* the transient status message *)
  gClip: ARRAY [0..BufMax] OF CHAR;       (* scratch for clipboard copy/paste text *)
  gErr: ARRAY [0..MaxLines-1] OF BOOLEAN; (* per-line error flag (red gutter) from the last build *)
  gNErr: CARDINAL;                        (* error-line count; 0 = markers stale/ignored *)
  gUndo, gRedo: ARRAY [0..UndoMax-1] OF ARRAY [0..UndoCap] OF CHAR;   (* serialized buffer snapshots *)
  gURow, gUCol, gRRow, gRCol: ARRAY [0..UndoMax-1] OF CARDINAL;        (* cursor per snapshot *)
  gUN, gRN, gLastKind: CARDINAL;          (* undo/redo depths + last edit kind (for coalescing) *)
  gFile: ARRAY [0..255] OF CHAR;         (* current file name (shown in the status line) *)
  gOut, gRaw: ARRAY [0..BufMax] OF CHAR;
  gReply: ARRAY [0..BufMax] OF CHAR;      (* the daemon's last response *)
  BaseDir: ARRAY [0..511] OF CHAR;        (* this exe's directory (for relocatable paths) *)
  Compiler, LibPath, WorkFile, ExeFile, OutFile, Sample, DemoFile: ARRAY [0..511] OF CHAR;
  gCompMode: BOOLEAN;                     (* the autocomplete popup is showing *)
  gCompN, gCompSel, gCompTop: CARDINAL;  (* candidate count / selected (index into gVis) / scroll top *)
  gCompStart: CARDINAL;                   (* col where the partial word begins (replaced on accept) *)
  gCompName:   ARRAY [0..MaxComp-1] OF ARRAY [0..63] OF CHAR;   (* candidate names (inserted on accept) *)
  gCompKind:   ARRAY [0..MaxComp-1] OF ARRAY [0..11] OF CHAR;   (* kind tag (module/proc/field/method/…) *)
  gCompDetail: ARRAY [0..MaxComp-1] OF ARRAY [0..63] OF CHAR;   (* signature / type detail for display *)
  gVis: ARRAY [0..MaxComp-1] OF CARDINAL; gVisN: CARDINAL;      (* candidate indices matching the typed partial *)
  gDirty: BOOLEAN;                        (* buffer changed since the last live check *)
  gEditTime: CARDINAL;                    (* GetTickCount at the last edit (debounce for check-on-idle) *)
  gPipeUp: BOOLEAN;                       (* the Exec pipe server is listening *)

TYPE
  (* an open document: its serialized text + cursor/scroll/dirty. The LIVE editor
     globals (line[], nLines, curRow, ...) are the ACTIVE doc's working set; an
     inactive doc lives here as a newline-joined blob (DocSave/DocLoad swap). *)
  (* heap-allocated to dodge the large-fixed-array-element compiler segfault: the
     record holds only a pointer, so gDocs has small elements. *)
  PText = POINTER TO ARRAY [0..BufMax] OF CHAR;
  DocRec = RECORD
    path:  ARRAY [0..511] OF CHAR;
    text:  PText;                         (* serialized content of an INACTIVE doc *)
    nLines, curRow, curCol, top, gLeft: CARDINAL;
    dirty: BOOLEAN;
    used:  BOOLEAN;
  END;
  (* one visible row of the file/project tree (a splice list — see ToggleNode) *)
  TreeRec = RECORD
    path:     ARRAY [0..511] OF CHAR;
    name:     ARRAY [0..127] OF CHAR;
    depth:    CARDINAL;
    isDir:    BOOLEAN;
    expanded: BOOLEAN;
  END;

VAR
  sidB: Backend; sidT: Terminal.Instance; sidPane, edOut: Pane;   (* left file-tree sidebar *)
  gDocs: ARRAY [0..MaxDocs-1] OF DocRec; gNDoc, gActiveDoc: CARDINAL;   (* open tabs *)
  gTabTop: CARDINAL;                      (* first visible tab (horizontal scroll) *)
  gTabPerPage: CARDINAL;                  (* tabs that fit (set by DrawTabs, read by hit-test) *)
  gTabRight: BOOLEAN;                     (* TRUE if tabs overflow to the right (show '>') *)
  gTree: ARRAY [0..MaxTree-1] OF TreeRec; gTreeN, gTreeSel, gTreeTop: CARDINAL;
  gProjRoot: ARRAY [0..511] OF CHAR;      (* the user's project folder (first tree root) *)
  gBuildTarget: ARRAY [0..511] OF CHAR;   (* pinned build/run entry module ("" = build the active file) *)
  di: CARDINAL;                           (* module-body scratch (BEGIN has no locals) *)

PROCEDURE SLen (VAR s: ARRAY OF CHAR): CARDINAL;
  VAR n: CARDINAL;
BEGIN n := 0; WHILE (n <= HIGH(s)) AND (s[n] # 0C) DO INC(n) END; RETURN n END SLen;

(* bounded string copy (any src/dst sizes; avoids fixed-array length-mismatch on :=) *)
PROCEDURE SCopy (VAR dst: ARRAY OF CHAR; src: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (i < HIGH(dst)) AND (src[i] # 0C) DO dst[i] := src[i]; INC(i) END;
  dst[i] := 0C
END SCopy;

PROCEDURE FileExists (path: ARRAY OF CHAR): BOOLEAN;
  VAR h: CARDINAL64; nm: ARRAY [0..511] OF CHAR;
BEGIN
  SCopy(nm, path); h := NM2File.Open(ADR(nm), NM2File.ReadFlag);
  IF h = 0 THEN RETURN FALSE END; NM2File.Close(h); RETURN TRUE
END FileExists;

PROCEDURE DirExists (path: ARRAY OF CHAR): BOOLEAN;
  VAR it: DirIter.Iter;
BEGIN
  IF DirIter.Open(path, it) THEN DirIter.Close(it); RETURN TRUE ELSE RETURN FALSE END
END DirExists;

PROCEDURE IsUntitled (VAR path: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (path[0] = 0C) OR ((path[0] = 'u') AND (path[1] = 'n') AND (path[2] = 't') AND (path[3] = 'i'))
END IsUntitled;

PROCEDURE StrEq (VAR a: ARRAY OF CHAR; VAR b: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  LOOP
    IF (i > HIGH(a)) OR (i > HIGH(b)) THEN RETURN (i > HIGH(a)) = (i > HIGH(b)) END;
    IF a[i] # b[i] THEN RETURN FALSE END;
    IF a[i] = 0C THEN RETURN TRUE END;
    INC(i)
  END
END StrEq;

PROCEDURE SetStatus (s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (i < 127) AND (s[i] # 0C) DO gMsg[i] := s[i]; INC(i) END; gMsg[i] := 0C END SetStatus;

PROCEDURE MarkDirty;   (* an edit happened -> schedule a live re-check after the typing pause *)
BEGIN gDirty := TRUE; gEditTime := VAL(CARDINAL, GetTickCount()) END MarkDirty;

(* dst := a + "\" + b  (NUL-terminated; CHAR is 16-bit/WCHAR here) *)
PROCEDURE JoinPath (VAR dst: ARRAY OF CHAR; a, b: ARRAY OF CHAR);
  VAR p, i: CARDINAL;
BEGIN
  p := 0; i := 0;
  WHILE (i <= HIGH(a)) AND (a[i] # 0C) AND (p < HIGH(dst)) DO dst[p] := a[i]; INC(p); INC(i) END;
  IF (p > 0) AND (dst[p-1] # '\') AND (p < HIGH(dst)) THEN dst[p] := '\'; INC(p) END;
  i := 0; WHILE (i <= HIGH(b)) AND (b[i] # 0C) AND (p < HIGH(dst)) DO dst[p] := b[i]; INC(p); INC(i) END;
  dst[p] := 0C
END JoinPath;

(* this exe's directory, via GetModuleFileNameW(NIL, ...) minus the file name *)
PROCEDURE GetExeDir (VAR dir: ARRAY OF CHAR);
  VAR buf: ARRAY [0..511] OF CHAR; n, i, last: CARDINAL;
BEGIN
  n := VAL(CARDINAL, GetModuleFileNameW(NIL, CAST(PWSTR, ADR(buf)), 512));
  last := 0; i := 0;
  WHILE (i < n) AND (i <= HIGH(buf)) AND (buf[i] # 0C) DO
    IF buf[i] = '\' THEN last := i END; INC(i)
  END;
  i := 0; WHILE (i < last) AND (i <= HIGH(dir)) DO dir[i] := buf[i]; INC(i) END;
  dir[i] := 0C
END GetExeDir;

PROCEDURE AppendStr (VAR d: ARRAY OF CHAR; VAR pos: CARDINAL; s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) AND (pos < HIGH(d)) DO d[pos] := s[i]; INC(i); INC(pos) END; d[pos] := 0C END AppendStr;

PROCEDURE AppendCard (VAR d: ARRAY OF CHAR; VAR pos: CARDINAL; n: CARDINAL);
  VAR dig: ARRAY [0..23] OF CHAR; k: CARDINAL;
BEGIN
  IF n = 0 THEN IF pos < HIGH(d) THEN d[pos] := '0'; INC(pos); d[pos] := 0C END; RETURN END;
  k := 0; WHILE n > 0 DO dig[k] := CHR((n MOD 10) + ORD('0')); n := n DIV 10; INC(k) END;
  WHILE k > 0 DO DEC(k); IF pos < HIGH(d) THEN d[pos] := dig[k]; INC(pos) END END;
  d[pos] := 0C
END AppendCard;

(* ---- minimal M2 syntax classification (per character of a line) ---- *)
PROCEDURE IsAlpha (c: CHAR): BOOLEAN;
BEGIN RETURN ((c >= 'A') AND (c <= 'Z')) OR ((c >= 'a') AND (c <= 'z')) OR (c = '_') END IsAlpha;
PROCEDURE IsDigit (c: CHAR): BOOLEAN;
BEGIN RETURN (c >= '0') AND (c <= '9') END IsDigit;

PROCEDURE IsKeyword (VAR s: ARRAY OF CHAR; a, b: CARDINAL): BOOLEAN;
  VAR w: ARRAY [0..31] OF CHAR; i, n: CARDINAL;
  PROCEDURE Eq (k: ARRAY OF CHAR): BOOLEAN;
    VAR j: CARDINAL;
  BEGIN
    IF SLen(k) # n THEN RETURN FALSE END;
    j := 0; WHILE j < n DO IF w[j] # k[j] THEN RETURN FALSE END; INC(j) END; RETURN TRUE
  END Eq;
BEGIN
  n := b - a; IF n > 31 THEN RETURN FALSE END;
  i := 0; WHILE i < n DO w[i] := s[a+i]; INC(i) END; w[n] := 0C;
  RETURN Eq("MODULE") OR Eq("BEGIN") OR Eq("END") OR Eq("FROM") OR Eq("IMPORT") OR Eq("PROCEDURE")
      OR Eq("VAR") OR Eq("CONST") OR Eq("TYPE") OR Eq("IF") OR Eq("THEN") OR Eq("ELSE") OR Eq("ELSIF")
      OR Eq("WHILE") OR Eq("DO") OR Eq("FOR") OR Eq("TO") OR Eq("BY") OR Eq("RETURN") OR Eq("LOOP")
      OR Eq("EXIT") OR Eq("REPEAT") OR Eq("UNTIL") OR Eq("CASE") OR Eq("RECORD") OR Eq("ARRAY")
      OR Eq("OF") OR Eq("POINTER") OR Eq("SET") OR Eq("AND") OR Eq("OR") OR Eq("NOT") OR Eq("DIV")
      OR Eq("MOD") OR Eq("IN") OR Eq("NIL") OR Eq("DEFINITION") OR Eq("IMPLEMENTATION") OR Eq("EXPORT")
      OR Eq("QUALIFIED") OR Eq("WITH") OR Eq("CLASS") OR Eq("INHERIT") OR Eq("OVERRIDE") OR Eq("ABSTRACT")
END IsKeyword;

(* normalised selection (anchor..cursor) -> lo/hi; FALSE if empty. Used by both the
   renderer (highlight) and the editor (copy/cut/delete). *)
PROCEDURE SelNorm (VAR loR, loC, hiR, hiC: CARDINAL): BOOLEAN;
BEGIN
  IF (NOT gSelActive) OR ((gAnchRow = curRow) AND (gAnchCol = curCol)) THEN RETURN FALSE END;
  IF (gAnchRow < curRow) OR ((gAnchRow = curRow) AND (gAnchCol < curCol)) THEN
    loR := gAnchRow; loC := gAnchCol; hiR := curRow; hiC := curCol
  ELSE
    loR := curRow; loC := curCol; hiR := gAnchRow; hiC := gAnchCol
  END;
  RETURN TRUE
END SelNorm;

PROCEDURE CellSelected (r, i, loR, loC, hiR, hiC: CARDINAL): BOOLEAN;
BEGIN
  IF (r < loR) OR (r > hiR) THEN RETURN FALSE END;
  IF loR = hiR THEN RETURN (i >= loC) AND (i < hiC) END;
  IF r = loR THEN RETURN i >= loC END;
  IF r = hiR THEN RETURN i < hiC END;
  RETURN TRUE                                          (* a fully-selected middle line *)
END CellSelected;

PROCEDURE HasSel (): BOOLEAN;                          (* a non-empty selection exists? *)
  VAR a, b, c, d: CARDINAL;
BEGIN RETURN SelNorm(a, b, c, d) END HasSel;

(* render one buffer line `r` at screen row `sr` — 2-pass: colour the whole line
   (so comment/string state is correct), then draw the horizontally-scrolled window. *)
PROCEDURE RenderLine (r, sr: CARDINAL);
  VAR ln: ARRAY [0..MaxCol] OF CHAR; col: ARRAY [0..MaxCol] OF Colour;
      n, i, a, cols, sc: CARDINAL; fg: Colour; com: BOOLEAN;
      num: ARRAY [0..Gutter] OF CHAR; v, k: CARDINAL; one: ARRAY [0..1] OF CHAR;
BEGIN
  cols := Terminal.Cols();
  v := r + 1; k := Gutter; num[Gutter] := 0C;
  REPEAT DEC(k); num[k] := CHR((v MOD 10) + ORD('0')); v := v DIV 10 UNTIL (v = 0) OR (k = 0);
  WHILE k > 0 DO DEC(k); num[k] := ' ' END;
  IF (gNErr > 0) AND (r < MaxLines) AND gErr[r] THEN     (* error line: red gutter *)
    Terminal.WriteColAt(0, sr, Red, Navy, num)
  ELSE
    Terminal.WriteColAt(0, sr, Teal, Navy, num)
  END;

  n := 0; WHILE (n <= MaxCol) AND (line[r][n] # 0C) DO ln[n] := line[r][n]; INC(n) END;
  i := 0; com := FALSE;                                  (* pass 1: classify every char *)
  WHILE i < n DO
    IF (NOT com) AND (i+1 < n) AND (ln[i] = '(') AND (ln[i+1] = '*') THEN com := TRUE END;
    IF com THEN
      col[i] := Gray;
      IF (i > 0) AND (ln[i-1] = '*') AND (ln[i] = ')') THEN com := FALSE END; INC(i)
    ELSIF (ln[i] = '"') OR (ln[i] = "'") THEN
      a := i; col[i] := Yellow; INC(i);
      WHILE (i < n) AND (ln[i] # ln[a]) DO col[i] := Yellow; INC(i) END;
      IF i < n THEN col[i] := Yellow; INC(i) END
    ELSIF IsAlpha(ln[i]) THEN
      a := i; WHILE (i < n) AND (IsAlpha(ln[i]) OR IsDigit(ln[i])) DO INC(i) END;
      IF IsKeyword(ln, a, i) THEN fg := White ELSE fg := Silver END;
      WHILE a < i DO col[a] := fg; INC(a) END
    ELSIF IsDigit(ln[i]) THEN col[i] := Aqua; INC(i)
    ELSE col[i] := Silver; INC(i)
    END
  END;
  i := gLeft; sc := Gutter + 1;                          (* pass 2: draw the visible window *)
  WHILE (i < n) AND (sc < cols) DO
    one[0] := ln[i]; one[1] := 0C;
    IF gHasSel AND CellSelected(r, i, gSelLoR, gSelLoC, gSelHiR, gSelHiC) THEN
      Terminal.WriteColAt(sc, sr, White, SelBg, one)      (* selected cell *)
    ELSE
      Terminal.WriteColAt(sc, sr, col[i], Navy, one)
    END;
    INC(i); INC(sc)
  END
END RenderLine;

(* one centred row of the About overlay (text centred in a bw-wide bg bar) *)
PROCEDURE AboutLine (bx, row, bw: CARDINAL; fg, bg: Colour; text: ARRAY OF CHAR);
  VAR buf: ARRAY [0..159] OF CHAR; tl, pad, i, p: CARDINAL;
BEGIN
  tl := SLen(text); IF tl > bw THEN tl := bw END;
  pad := (bw - tl) DIV 2; p := 0;
  WHILE p < pad DO buf[p] := ' '; INC(p) END;
  i := 0; WHILE i < tl DO buf[p] := text[i]; INC(p); INC(i) END;
  WHILE (p < bw) AND (p < 159) DO buf[p] := ' '; INC(p) END; buf[p] := 0C;
  Terminal.WriteColAt(bx, row, fg, bg, buf)
END AboutLine;

PROCEDURE DrawAbout (vc, vr: CARDINAL);          (* the non-modal in-grid About "text window" *)
  CONST Bg = 01E3A5FH;                            (* steel-blue dialog *)
  VAR bw, bh, bx, by, r: CARDINAL;
BEGIN
  bw := 54; IF bw > vc THEN bw := vc END;
  bh := 9;  IF bh > vr THEN bh := vr END;
  bx := (vc - bw) DIV 2; IF (vc - bw) DIV 2 > vc THEN bx := 0 END;
  by := (vr - bh) DIV 2;
  r := 0; WHILE r < bh DO AboutLine(bx, by + r, bw, White, Bg, ""); INC(r) END;   (* fill *)
  AboutLine(bx, by + 1, bw, Aqua,   Bg, "About FastPanesM2");
  AboutLine(bx, by + 3, bw, White,  Bg, "A Modula-2 IDE on the PaneShell GUI framework");
  AboutLine(bx, by + 4, bw, White,  Bg, "GPU-accelerated Terminal panes (Direct2D)");
  AboutLine(bx, by + 6, bw, Silver, Bg, "(c) NewModula-2");
  AboutLine(bx, by + 7, bw, Yellow, Bg, "[ Esc or click to close ]")
END DrawAbout;

(* the autocomplete popup: a list of candidates anchored at the cursor, drawn
   LAST (over everything). `gVis` (the indices matching the typed partial) and
   `gCompSel` are maintained by FilterComp; this only renders them. *)
PROCEDURE DrawCompletions (vc, vr: CARDINAL);
  VAR bx, by, bw, rows, gridR, gridC, r, vi, idx, p, k, nl: CARDINAL; fg, bg: Colour;
      buf: ARRAY [0..95] OF CHAR;
BEGIN
  IF gVisN = 0 THEN RETURN END;
  rows := gVisN; IF rows > CompPopH THEN rows := CompPopH END;
  IF gCompSel < gCompTop THEN gCompTop := gCompSel END;                 (* keep selection in view *)
  IF gCompSel >= gCompTop + rows THEN gCompTop := gCompSel - rows + 1 END;
  IF curRow >= top THEN gridR := EdTop + (curRow - top) ELSE gridR := EdTop END;
  IF curCol >= gLeft THEN gridC := Gutter + 1 + (curCol - gLeft) ELSE gridC := Gutter + 1 END;
  bw := 38;
  by := gridR + 1;                                                      (* below the cursor, flip up if no room *)
  IF by + rows >= vr THEN IF gridR > rows THEN by := gridR - rows ELSE by := 0 END END;
  bx := gridC; IF bx + bw > vc THEN IF vc > bw THEN bx := vc - bw ELSE bx := 0 END END;
  r := 0;
  WHILE r < rows DO
    vi := gCompTop + r;
    IF vi < gVisN THEN
      idx := gVis[vi];
      IF vi = gCompSel THEN fg := White; bg := Navy ELSE fg := Black; bg := Silver END;
      p := 0; nl := SLen(gCompName[idx]);
      k := 0; WHILE (k < nl) AND (p < bw - 1) DO buf[p] := gCompName[idx][k]; INC(p); INC(k) END;
      WHILE (p < 16) AND (p < bw - 1) DO buf[p] := ' '; INC(p) END;     (* pad the name column *)
      nl := SLen(gCompDetail[idx]);
      k := 0; WHILE (k < nl) AND (p < bw - 1) DO buf[p] := gCompDetail[idx][k]; INC(p); INC(k) END;
      WHILE p < bw DO buf[p] := ' '; INC(p) END; buf[p] := 0C;
      Terminal.WriteColAt(bx, by + r, fg, bg, buf)
    END;
    INC(r)
  END
END DrawCompletions;

(* the editor tab strip (row TabRow): fixed-width chips " name *x ", the active
   one highlighted, '*' = unsaved, trailing 'x' = close. Scrolls with '<' / '>'
   when the tabs overflow. Drawn by RenderEditor; hit-tested by PressAt. The first
   2 cols are the left-arrow zone, the last 2 the right-arrow zone. *)
PROCEDURE DrawTabs (vc: CARDINAL);
  VAR i, k, nl, perPage, nameW: CARDINAL; nm: ARRAY [0..127] OF CHAR; seg: ARRAY [0..TabW] OF CHAR;
      fg, bg: Colour; one: ARRAY [0..1] OF CHAR; dirty: BOOLEAN;
BEGIN
  Terminal.Use(edT);
  one[0] := ' '; one[1] := 0C;
  nameW := TabW - 4;                                      (* " " + name + marker + "x" + " " *)
  IF vc > 4 + TabW THEN perPage := (vc - 4) DIV TabW ELSE perPage := 1 END;
  IF perPage = 0 THEN perPage := 1 END;
  IF (gNDoc > 0) AND (gTabTop >= gNDoc) THEN gTabTop := gNDoc - 1 END;
  gTabPerPage := perPage;
  gTabRight := (gTabTop + perPage < gNDoc);
  k := 0; WHILE k < vc DO Terminal.WriteColAt(k, TabRow, Silver, Black, one); INC(k) END;   (* clear row *)
  i := gTabTop;
  WHILE (i < gNDoc) AND (i < gTabTop + perPage) DO
    BaseName(gDocs[i].path, nm); nl := SLen(nm);
    seg[0] := ' ';
    k := 0; WHILE k < nameW DO IF k < nl THEN seg[1+k] := nm[k] ELSE seg[1+k] := ' ' END; INC(k) END;
    IF nl > nameW THEN seg[nameW] := '~' END;             (* name truncated *)
    dirty := ((i = gActiveDoc) AND gDirty) OR ((i # gActiveDoc) AND gDocs[i].dirty);
    IF dirty THEN seg[TabW-3] := '*' ELSE seg[TabW-3] := ' ' END;
    seg[TabClose] := 'x'; seg[TabW-1] := ' '; seg[TabW] := 0C;
    IF i = gActiveDoc THEN fg := White; bg := Navy ELSE fg := Silver; bg := Black END;
    Terminal.WriteColAt(2 + (i - gTabTop) * TabW, TabRow, fg, bg, seg);
    INC(i)
  END;
  IF gTabTop > 0 THEN Terminal.WriteColAt(0, TabRow, White, Teal, "< ") END;
  IF gTabRight AND (vc >= 2) THEN Terminal.WriteColAt(vc-2, TabRow, White, Teal, " >") END
END DrawTabs;

(* keep the active tab on screen after a switch/open/close (NOT on every render,
   so manual '<'/'>' scrolling isn't fought) *)
PROCEDURE EnsureTabVisible;
BEGIN
  IF gActiveDoc < gTabTop THEN gTabTop := gActiveDoc END;
  IF (gTabPerPage > 0) AND (gActiveDoc >= gTabTop + gTabPerPage) THEN gTabTop := gActiveDoc - gTabPerPage + 1 END
END EnsureTabVisible;

PROCEDURE RenderEditor;
  VAR sr, cols, rows, vc, vr, visRows, visCols, p: CARDINAL; cch: ARRAY [0..1] OF CHAR; st: ARRAY [0..255] OF CHAR;
BEGIN
  Terminal.Use(edT);
  VisibleCells(edB, vc, vr);                             (* fit the layout to the actual pane, not the model *)
  cols := Terminal.Cols(); rows := Terminal.Rows();
  IF (vc = 0) OR (vc > cols) THEN vc := cols END;        (* fall back / clamp to model (before first show) *)
  IF (vr = 0) OR (vr > rows) THEN vr := rows END;
  Terminal.SetColour(Silver, Navy); Terminal.Clear;
  gHasSel := SelNorm(gSelLoR, gSelLoC, gSelHiR, gSelHiC);   (* snapshot the selection for RenderLine *)
  visRows := 0; IF vr > EdTop + 1 THEN visRows := vr - EdTop - 1 END;   (* text rows (row0 menu, last visible row = status) *)
  visCols := 0; IF vc > Gutter + 1 THEN visCols := vc - Gutter - 1 END;
  IF gFollow THEN                                      (* keep the cursor on screen (cleared for wheel scroll) *)
    IF curRow < top THEN top := curRow END;
    IF (visRows > 0) AND (curRow >= top + visRows) THEN top := curRow - visRows + 1 END;
    IF curCol < gLeft THEN gLeft := curCol END;
    IF (visCols > 0) AND (curCol >= gLeft + visCols) THEN gLeft := curCol - visCols + 1 END
  END;
  IF top >= nLines THEN top := nLines - 1 END;          (* clamp a free (wheel) scroll *)
  sr := 0;
  WHILE (sr < visRows) AND (top + sr < nLines) DO RenderLine(top + sr, EdTop + sr); INC(sr) END;
  IF (curRow >= top) AND (curRow < top + visRows) AND (curCol >= gLeft) AND (curCol < gLeft + visCols) THEN
    cch[0] := line[curRow][curCol]; IF cch[0] = 0C THEN cch[0] := ' ' END; cch[1] := 0C;
    Terminal.WriteColAt(Gutter + 1 + (curCol - gLeft), EdTop + (curRow - top), Navy, White, cch)
  END;
  p := 0;                                                (* status row (last visible), full-width Teal *)
  IF gFindMode THEN
    AppendStr(st, p, "Find: "); AppendStr(st, p, gFindTerm);
    AppendStr(st, p, "_    (Enter = next,  Esc = cancel)")
  ELSIF gCmdMode THEN
    AppendStr(st, p, "ptcl) "); AppendStr(st, p, gCmdLine);
    AppendStr(st, p, "_    (Enter = run,  Esc = cancel)")
  ELSE
    AppendStr(st, p, gMsg); AppendStr(st, p, "   ");
    AppendStr(st, p, gFile); AppendStr(st, p, "   Ln "); AppendCard(st, p, curRow + 1);
    AppendStr(st, p, " Col "); AppendCard(st, p, curCol + 1);
    AppendStr(st, p, "    F9 build  F5 run  F10 menu  Ctrl+F find  Ctrl+P cmd")
  END;
  WHILE (p < vc) AND (p < 255) DO st[p] := ' '; INC(p) END; st[p] := 0C;   (* pad to width *)
  IF vr > 0 THEN Terminal.WriteColAt(0, vr - 1, White, Teal, st) END;
  DrawTabs(vc);                                          (* tab strip (row 1, open docs) *)
  Terminal.MenuSetFocus(gMenuMode); Terminal.MenuRender;  (* menu bar (row 0) + any open drop-down, drawn last = on top *)
  IF gAboutMode THEN DrawAbout(vc, vr) END;            (* the About overlay sits on top of everything *)
  IF gCompMode THEN DrawCompletions(vc, vr) END;       (* the autocomplete popup sits above that *)
  edB.Paint;
  gFollow := TRUE                                       (* default: the next render follows the cursor again *)
END RenderEditor;

(* ============================ file/project tree ============================ *)

CONST SideBg = 0202830H;                                 (* dark slate sidebar background *)

PROCEDURE EndsWithCI (VAR name: ARRAY OF CHAR; ext: ARRAY OF CHAR): BOOLEAN;
  VAR nl, el, i: CARDINAL; a, b: CHAR;
BEGIN
  nl := SLen(name); el := 0; WHILE ext[el] # 0C DO INC(el) END;
  IF (el = 0) OR (el > nl) THEN RETURN FALSE END;
  i := 0;
  WHILE i < el DO
    a := name[nl-el+i]; b := ext[i];
    IF (a >= 'A') AND (a <= 'Z') THEN a := CHR(ORD(a)+32) END;
    IF (b >= 'A') AND (b <= 'Z') THEN b := CHR(ORD(b)+32) END;
    IF a # b THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END EndsWithCI;

PROCEDURE StartsWith (VAR name: ARRAY OF CHAR; pre: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE pre[i] # 0C DO IF (i > HIGH(name)) OR (name[i] # pre[i]) THEN RETURN FALSE END; INC(i) END;
  RETURN TRUE
END StartsWith;

(* build output + IDE scratch the tree shouldn't show *)
PROCEDURE IsHidden (VAR name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN EndsWithCI(name, ".exe") OR EndsWithCI(name, ".obj") OR EndsWithCI(name, ".png")
      OR EndsWithCI(name, ".pdb") OR EndsWithCI(name, ".lib") OR EndsWithCI(name, ".ilk")
      OR EndsWithCI(name, ".jsonl")
      OR StartsWith(name, "fastpanes_") OR StartsWith(name, "__m2complete__")
END IsHidden;

(* insert one tree row at position `at`, shifting the rest right *)
PROCEDURE TreeInsertAt (at: CARDINAL; VAR rec: TreeRec);
  VAR j: CARDINAL;
BEGIN
  IF gTreeN >= MaxTree THEN RETURN END;
  j := gTreeN;
  WHILE j > at DO gTree[j] := gTree[j-1]; DEC(j) END;
  gTree[at] := rec; INC(gTreeN)
END TreeInsertAt;

(* read `node`'s directory children into the tree right after it (dirs first,
   then files), one indent level deeper; mark it expanded *)
PROCEDURE ExpandNode (node: CARDINAL);
  VAR it: DirIter.Iter; nm: ARRAY [0..511] OF CHAR; isDir: BOOLEAN; size: CARDINAL;
      rec: TreeRec; at, d: CARDINAL; pass: CARDINAL;
BEGIN
  d := gTree[node].depth + 1; at := node + 1;
  FOR pass := 0 TO 1 DO                                   (* pass 0 = dirs, pass 1 = files *)
    IF DirIter.Open(gTree[node].path, it) THEN
      WHILE DirIter.Next(it, nm, isDir, size) DO
        IF (((isDir AND (pass = 0)) OR ((NOT isDir) AND (pass = 1)))) AND (NOT IsHidden(nm)) THEN
          Join(gTree[node].path, nm, rec.path);
          SCopy(rec.name, nm); rec.depth := d; rec.isDir := isDir; rec.expanded := FALSE;
          TreeInsertAt(at, rec); INC(at)
        END
      END;
      DirIter.Close(it)
    END
  END;
  gTree[node].expanded := TRUE
END ExpandNode;

(* remove `node`'s descendants (deeper rows that follow it); mark it collapsed *)
PROCEDURE CollapseNode (node: CARDINAL);
  VAR d, j, n: CARDINAL;
BEGIN
  d := gTree[node].depth; n := 0;
  WHILE (node + 1 + n < gTreeN) AND (gTree[node + 1 + n].depth > d) DO INC(n) END;
  j := node + 1;
  WHILE j + n < gTreeN DO gTree[j] := gTree[j + n]; INC(j) END;
  gTreeN := gTreeN - n;
  gTree[node].expanded := FALSE
END CollapseNode;

PROCEDURE ToggleNode (node: CARDINAL);
BEGIN
  IF (node < gTreeN) AND gTree[node].isDir THEN
    IF gTree[node].expanded THEN CollapseNode(node) ELSE ExpandNode(node) END
  END
END ToggleNode;

(* build the two roots (PROJECT + LIBRARY) and auto-expand the project *)
PROCEDURE InitTree;
  VAR rec: TreeRec;
BEGIN
  gTreeN := 0; gTreeSel := 0; gTreeTop := 0;
  SCopy(rec.path, gProjRoot); SCopy(rec.name, "PROJECT"); rec.depth := 0; rec.isDir := TRUE; rec.expanded := FALSE;
  TreeInsertAt(0, rec);
  SCopy(rec.path, LibPath);   SCopy(rec.name, "LIBRARY"); rec.depth := 0; rec.isDir := TRUE; rec.expanded := FALSE;
  TreeInsertAt(1, rec);
  ExpandNode(0)
END InitTree;

PROCEDURE RenderSidebar;
  VAR vc, vr, cols, rows, sr, i, p, k, nl, d: CARDINAL; row: ARRAY [0..255] OF CHAR; fg, bg: Colour;
BEGIN
  Terminal.Use(sidT);
  VisibleCells(sidB, vc, vr); cols := Terminal.Cols(); rows := Terminal.Rows();
  IF (vc = 0) OR (vc > cols) THEN vc := cols END;
  IF (vr = 0) OR (vr > rows) THEN vr := rows END;
  Terminal.SetColour(Silver, SideBg); Terminal.Clear;
  IF gTreeSel < gTreeTop THEN gTreeTop := gTreeSel END;
  IF (vr > 0) AND (gTreeSel >= gTreeTop + vr) THEN gTreeTop := gTreeSel - vr + 1 END;
  sr := 0;
  WHILE (sr < vr) AND (gTreeTop + sr < gTreeN) DO
    i := gTreeTop + sr; p := 0; d := gTree[i].depth;
    WHILE (p < d * 2) AND (p < 250) DO row[p] := ' '; INC(p) END;
    IF gTree[i].isDir THEN
      IF gTree[i].expanded THEN row[p] := '-' ELSE row[p] := '+' END; INC(p); row[p] := ' '; INC(p)
    ELSE row[p] := ' '; INC(p); row[p] := ' '; INC(p) END;
    nl := SLen(gTree[i].name); k := 0;
    WHILE (k < nl) AND (p < vc) AND (p < 250) DO row[p] := gTree[i].name[k]; INC(p); INC(k) END;
    WHILE (p < vc) AND (p < 250) DO row[p] := ' '; INC(p) END; row[p] := 0C;
    IF i = gTreeSel THEN fg := White; bg := Navy
    ELSIF gTree[i].isDir THEN fg := Aqua; bg := SideBg
    ELSE fg := Silver; bg := SideBg END;
    Terminal.WriteColAt(0, sr, fg, bg, row);
    INC(sr)
  END;
  sidB.Paint
END RenderSidebar;

(* ---- output: lay the captured compiler text into the output grid (scrolled by
   outTop, error lines in red) ---- *)
PROCEDURE ShowOutput (VAR buf: ARRAY OF CHAR);
  VAR i, col, srow, vc, vr, total, logLine: CARDINAL; one: ARRAY [0..1] OF CHAR; lineFg: Colour;
  PROCEDURE LineIsError (p: CARDINAL): BOOLEAN;          (* line at p contains "error"/"Error" before LF/EOF *)
    VAR q: CARDINAL;
  BEGIN
    q := p;
    WHILE (q <= HIGH(buf)) AND (buf[q] # 0C) AND (buf[q] # CHR(10)) DO
      IF ((buf[q] = 'e') OR (buf[q] = 'E')) AND (q + 4 <= HIGH(buf))
         AND (buf[q+1] = 'r') AND (buf[q+2] = 'r') AND (buf[q+3] = 'o') AND (buf[q+4] = 'r') THEN RETURN TRUE END;
      INC(q)
    END;
    RETURN FALSE
  END LineIsError;
BEGIN
  Terminal.Use(outT);
  VisibleCells(outB, vc, vr);
  IF (vr = 0) OR (vr > Terminal.Rows()) THEN vr := Terminal.Rows() END;
  IF (vc = 0) OR (vc > Terminal.Cols()) THEN vc := Terminal.Cols() END;
  total := 0; i := 0;                                     (* count logical lines, clamp the scroll *)
  WHILE (i <= HIGH(buf)) AND (buf[i] # 0C) DO IF buf[i] = CHR(10) THEN INC(total) END; INC(i) END;
  IF (total > 0) AND (outTop > total - 1) THEN outTop := total - 1 ELSIF total = 0 THEN outTop := 0 END;
  Terminal.SetColour(Silver, Black); Terminal.Clear;
  i := 0; logLine := 0;                                   (* skip outTop logical lines *)
  WHILE (logLine < outTop) AND (i <= HIGH(buf)) AND (buf[i] # 0C) DO
    IF buf[i] = CHR(10) THEN INC(logLine) END; INC(i)
  END;
  col := 0; srow := 0;
  IF (i <= HIGH(buf)) AND (buf[i] # 0C) THEN IF LineIsError(i) THEN lineFg := Red ELSE lineFg := Silver END
  ELSE lineFg := Silver END;
  WHILE (i <= HIGH(buf)) AND (buf[i] # 0C) AND (srow < vr) DO
    IF buf[i] = CHR(10) THEN
      INC(srow); col := 0;
      IF (srow < vr) AND (i + 1 <= HIGH(buf)) THEN IF LineIsError(i+1) THEN lineFg := Red ELSE lineFg := Silver END END
    ELSIF buf[i] # CHR(13) THEN
      IF col < vc THEN one[0] := buf[i]; one[1] := 0C; Terminal.WriteColAt(col, srow, lineFg, Black, one) END;
      INC(col)
    END;
    INC(i)
  END;
  outB.Paint
END ShowOutput;

(* ---- file IO + build (shared library modules, same as FastM2) ---- *)
PROCEDURE WriteWork (): BOOLEAN;
  VAR h: CARDINAL64; buf: ARRAY [0..MaxCol+2] OF CHAR; r, k, w: CARDINAL;
BEGIN
  h := NM2File.Open(ADR(WorkFile), NM2File.WriteFlag + NM2File.NewFlag);
  IF h = 0 THEN RETURN FALSE END;
  r := 0;
  WHILE r < nLines DO
    k := 0; WHILE (k <= MaxCol) AND (line[r][k] # 0C) DO buf[k] := line[r][k]; INC(k) END;
    buf[k] := CHR(10);
    w := VAL(CARDINAL, NM2File.WriteText(h, ADR(buf), VAL(CARDINAL64, k+1)));
    INC(r)
  END;
  NM2File.Close(h); RETURN TRUE
END WriteWork;

PROCEDURE ReadOut (VAR dst: ARRAY OF CHAR);
  VAR h: CARDINAL64; got: CARDINAL64; i: CARDINAL;
BEGIN
  dst[0] := 0C;
  h := NM2File.Open(ADR(OutFile), NM2File.ReadFlag);
  IF h = 0 THEN RETURN END;
  got := NM2File.ReadText(h, ADR(gRaw), VAL(CARDINAL64, HIGH(gRaw)));
  NM2File.Close(h);
  i := 0; WHILE (i < VAL(CARDINAL, got)) AND (i < HIGH(dst)) DO dst[i] := gRaw[i]; INC(i) END;
  dst[i] := 0C
END ReadOut;

(* shared scanners over the captured compiler output gOut *)
PROCEDURE MatchAt (at: CARDINAL; kw: ARRAY OF CHAR): BOOLEAN;       (* gOut[at..] starts with kw? *)
  VAR j: CARDINAL;
BEGIN
  j := 0; WHILE (j <= HIGH(kw)) AND (kw[j] # 0C) DO
    IF (at+j > HIGH(gOut)) OR (gOut[at+j] # kw[j]) THEN RETURN FALSE END; INC(j) END;
  RETURN TRUE
END MatchAt;

PROCEDURE NumAt (at: CARDINAL): CARDINAL;                            (* read the decimal at gOut[at] *)
  VAR r: CARDINAL;
BEGIN
  r := 0; WHILE (at <= HIGH(gOut)) AND (gOut[at] >= '0') AND (gOut[at] <= '9') DO r := r*10 + (ORD(gOut[at]) - ORD('0')); INC(at) END;
  RETURN r
END NumAt;

(* mark every "line N" diagnostic in the output -> gErr (red gutter) *)
PROCEDURE ParseErrors;
  VAR i, n: CARDINAL;
BEGIN
  i := 0; WHILE i < nLines DO gErr[i] := FALSE; INC(i) END;
  gNErr := 0; i := 0;
  WHILE (i <= HIGH(gOut)) AND (gOut[i] # 0C) DO
    IF MatchAt(i, "line ") THEN
      n := NumAt(i + 5);
      IF (n > 0) AND (n <= nLines) AND (NOT gErr[n-1]) THEN gErr[n-1] := TRUE; INC(gNErr) END
    END;
    INC(i)
  END
END ParseErrors;

(* scan the compiler output for the first "line N, column M" and put the cursor there *)
PROCEDURE JumpToError;
  VAR i, n, v: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(gOut)) AND (gOut[i] # 0C) DO
    IF MatchAt(i, "line ") THEN
      n := NumAt(i + 5);
      IF (n > 0) AND (n <= nLines) THEN
        curRow := n - 1; v := 0;
        WHILE (i <= HIGH(gOut)) AND (gOut[i] # 0C) AND (gOut[i] # CHR(10)) DO
          IF MatchAt(i, "column ") THEN v := NumAt(i + 7) END; INC(i)
        END;
        IF v > 0 THEN curCol := v - 1 END;
        IF curCol > SLen(line[curRow]) THEN curCol := SLen(line[curRow]) END;
        top := 0; gLeft := 0; gSelActive := FALSE; RETURN
      END
    END;
    INC(i)
  END
END JumpToError;

(* ---- the resident compiler daemon (fast channel); falls back to spawning the CLI ---- *)

PROCEDURE CopyOut (VAR src: ARRAY OF CHAR; from: CARDINAL);   (* gOut := src[from..] *)
  VAR i, k, slen: CARDINAL;
BEGIN
  slen := SLen(src); IF from > slen THEN from := slen END;
  i := from; k := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (k < BufMax) DO gOut[k] := src[i]; INC(i); INC(k) END;
  gOut[k] := 0C
END CopyOut;

(* parse "errors\n<LINE COL SEV MSG>..." in gReply into gErr/gNErr; returns the first
   error line (0 if none). Markers only — no display, no jump. *)
PROCEDURE ScanDiags (): CARDINAL;
  VAR i, n, k, ln, firstErr: CARDINAL;
BEGIN
  n := SLen(gReply); gNErr := 0;
  k := 0; WHILE k < nLines DO gErr[k] := FALSE; INC(k) END;
  i := 0; WHILE (i < n) AND (gReply[i] # CHR(10)) DO INC(i) END; IF i < n THEN INC(i) END;  (* skip "errors" *)
  firstErr := 0;
  WHILE i < n DO
    ln := 0; WHILE (i < n) AND (gReply[i] >= '0') AND (gReply[i] <= '9') DO ln := ln*10 + (ORD(gReply[i]) - ORD('0')); INC(i) END;
    WHILE (i < n) AND (gReply[i] # CHR(10)) DO INC(i) END; IF i < n THEN INC(i) END;        (* to next line *)
    IF (ln >= 1) AND (ln <= nLines) THEN
      IF NOT gErr[ln-1] THEN gErr[ln-1] := TRUE; INC(gNErr) END;
      IF firstErr = 0 THEN firstErr := ln END
    END
  END;
  RETURN firstErr
END ScanDiags;

(* parse the daemon reply (gReply) -> gOut (display) + gErr/gNErr (markers) + status *)
PROCEDURE ParseServiceReply (run: BOOLEAN);
  VAR i, n, firstErr, pos: CARDINAL; isOk, isErrs: BOOLEAN;
BEGIN
  n := SLen(gReply);
  isOk := (n >= 2) AND (gReply[0] = 'o') AND (gReply[1] = 'k');
  isErrs := (n >= 6) AND (gReply[0] = 'e') AND (gReply[1] = 'r') AND (gReply[2] = 'r')
            AND (gReply[3] = 'o') AND (gReply[4] = 'r') AND (gReply[5] = 's');
  IF isErrs THEN
    firstErr := ScanDiags();
    CopyOut(gReply, 7);                                   (* show diags (after "errors\n") *)
    IF firstErr >= 1 THEN
      curRow := firstErr - 1; top := 0; gLeft := 0; gSelActive := FALSE;
      IF curCol > SLen(line[curRow]) THEN curCol := SLen(line[curRow]) END
    END;
    SetStatus("errors (daemon)")
  ELSIF isOk THEN
    gNErr := 0;
    IF run THEN
      i := 0; WHILE (i < n) AND (gReply[i] # CHR(10)) DO INC(i) END; IF i < n THEN INC(i) END;
      CopyOut(gReply, i);                                 (* program output after "ok\n" *)
      SetStatus("ran ok (daemon)")
    ELSE
      pos := 0; AppendStr(gOut, pos, "compiled ok (daemon)");
      SetStatus("compiled ok (daemon)")
    END
  ELSE
    gNErr := 0; CopyOut(gReply, 6); SetStatus("build failed (daemon)")   (* "error <msg>" *)
  END;
  outTop := 0; ShowOutput(gOut)
END ParseServiceReply;

(* Spawn the resident compiler daemon (hidden, detached) and wait for its pipe. The
   IDE always has a warm compiler without the user starting one. *)
PROCEDURE SpawnDaemon;
  VAR args: ARRAY [0..511] OF CHAR; pos, st, tries: CARDINAL; ok: BOOLEAN; r: ARRAY [0..63] OF CHAR;
BEGIN
  pos := 0; AppendStr(args, pos, "daemon --library "); AppendStr(args, pos, LibPath);
  ok := RunProgram(Compiler, args, "", ExecFlagSet{ExecAsync, ExecHidden, ExecDetached}, st);
  IF NOT ok THEN RETURN END;
  tries := 0;                                           (* wait for the pipe to come up *)
  WHILE (tries < 30) AND (NOT Ask(PipeName, "ping", r)) DO Sleep(100); INC(tries) END
END SpawnDaemon;

(* One daemon request = one fresh connection (connect + send + recv + close), which is
   exactly how the daemon serves: one client at a time, serially. No persistent handle
   to go stale. The daemon serves one client at a time, so a request issued in the brief
   window while it tears down the previous connection + re-creates its pipe instance will
   miss it — so retry a few times before concluding it's down (and spawning one). *)
PROCEDURE DaemonAsk (cmd: ARRAY OF CHAR; VAR reply: ARRAY OF CHAR): BOOLEAN;
  VAR tries: CARDINAL;
BEGIN
  tries := 0;
  WHILE tries < 8 DO                          (* ~120ms of transient-busy tolerance *)
    IF Ask(PipeName, cmd, reply) THEN RETURN TRUE END;
    Sleep(15); INC(tries)
  END;
  SpawnDaemon;                                (* genuinely down -> start one + retry once *)
  RETURN Ask(PipeName, cmd, reply)
END DaemonAsk;

(* TRUE if the daemon handled the request (even if it reported errors); FALSE only
   when the daemon is unreachable, so the caller falls back to the spawned CLI. *)
PROCEDURE TryDaemon (entry: ARRAY OF CHAR; run: BOOLEAN): BOOLEAN;
  VAR cmd: ARRAY [0..1023] OF CHAR; pos: CARDINAL;
BEGIN
  pos := 0;
  IF run THEN AppendStr(cmd, pos, "run ") ELSE AppendStr(cmd, pos, "build ") END;
  AppendStr(cmd, pos, '"'); AppendStr(cmd, pos, entry); AppendStr(cmd, pos, '"');
  IF NOT run THEN
    AppendStr(cmd, pos, " "); AppendStr(cmd, pos, '"'); AppendStr(cmd, pos, ExeFile); AppendStr(cmd, pos, '"')
  END;
  IF NOT DaemonAsk(cmd, gReply) THEN RETURN FALSE END;
  ParseServiceReply(run);
  RenderEditor;
  RETURN TRUE
END TryDaemon;

(* live check-on-idle: ask the daemon to typecheck (sema only) and update the gutter
   markers — no output-pane change, no jump. The as-you-type squiggle. Daemon-only. *)
PROCEDURE DoCheck;
  VAR cmd: ARRAY [0..1023] OF CHAR; pos, k: CARDINAL; st: ARRAY [0..63] OF CHAR; sp: CARDINAL; isErrs: BOOLEAN;
BEGIN
  IF NOT WriteWork() THEN RETURN END;
  pos := 0; AppendStr(cmd, pos, 'check "'); AppendStr(cmd, pos, WorkFile); AppendStr(cmd, pos, '"');
  IF NOT DaemonAsk(cmd, gReply) THEN RETURN END;          (* no daemon -> no live check *)
  isErrs := (SLen(gReply) >= 6) AND (gReply[0] = 'e') AND (gReply[1] = 'r') AND (gReply[2] = 'r')
            AND (gReply[3] = 'o') AND (gReply[4] = 'r') AND (gReply[5] = 's');
  IF isErrs THEN k := ScanDiags() ELSE gNErr := 0 END;
  sp := 0;
  IF gNErr > 0 THEN AppendCard(st, sp, gNErr); AppendStr(st, sp, " problem(s)") ELSE AppendStr(st, sp, "no problems") END;
  SetStatus(st);
  RenderEditor
END DoCheck;

(* on-demand static analysis: ask the daemon for NEW/DISPOSE warnings (leak, double
   DISPOSE, use-after-DISPOSE), show the full list in the output pane + mark the gutter.
   Essential with no GC. Daemon-only (the warm compiler). *)
PROCEDURE DoAnalyze;
  VAR cmd: ARRAY [0..1023] OF CHAR; pos, k: CARDINAL; st: ARRAY [0..63] OF CHAR; sp: CARDINAL; isErrs: BOOLEAN;
BEGIN
  IF NOT WriteWork() THEN RETURN END;
  pos := 0; AppendStr(cmd, pos, 'analyze "'); AppendStr(cmd, pos, WorkFile); AppendStr(cmd, pos, '"');
  IF NOT DaemonAsk(cmd, gReply) THEN SetStatus("analyze: no daemon"); RenderEditor; RETURN END;
  isErrs := (SLen(gReply) >= 6) AND (gReply[0] = 'e') AND (gReply[1] = 'r') AND (gReply[2] = 'r')
            AND (gReply[3] = 'o') AND (gReply[4] = 'r') AND (gReply[5] = 's');
  IF isErrs THEN
    k := ScanDiags();                                     (* gutter markers (warnings + errors) *)
    CopyOut(gReply, 7); outTop := 0; ShowOutput(gOut);    (* show the list (skip the "errors\n" header) *)
    sp := 0; AppendCard(st, sp, gNErr); AppendStr(st, sp, " finding(s) - click a line to jump"); SetStatus(st)
  ELSE
    gNErr := 0; pos := 0; AppendStr(gOut, pos, "analyze: no NEW/DISPOSE issues found");
    outTop := 0; ShowOutput(gOut); SetStatus("analyze: clean")
  END;
  RenderEditor
END DoAnalyze;

PROCEDURE Compile (verb: ARRAY OF CHAR; run: BOOLEAN);
  VAR cmd, entry: ARRAY [0..1023] OF CHAR; pos, st: CARDINAL; ok: BOOLEAN;
BEGIN
  IF run THEN SetStatus("running...") ELSE SetStatus("compiling...") END; RenderEditor;
  (* entry = the pinned build target, else the active file, else a scratch copy
     (untitled). The caller (F9/F5) has already saved all dirty docs to disk so
     the target + its imported siblings are current; the compiler follows imports. *)
  IF (gBuildTarget[0] # 0C) AND (NOT IsUntitled(gBuildTarget)) THEN SCopy(entry, gBuildTarget)
  ELSIF NOT IsUntitled(gFile) THEN SCopy(entry, gFile)
  ELSE SCopy(entry, WorkFile); IF NOT WriteWork() THEN SetStatus("save FAILED"); RenderEditor; RETURN END END;
  IF TryDaemon(entry, run) THEN RETURN END;               (* warm resident compiler handled it *)
  pos := 0;
  AppendStr(cmd, pos, Compiler); AppendStr(cmd, pos, " "); AppendStr(cmd, pos, verb); AppendStr(cmd, pos, " ");
  AppendStr(cmd, pos, entry);    AppendStr(cmd, pos, " --library ");
  AppendStr(cmd, pos, LibPath);  AppendStr(cmd, pos, " > ");
  AppendStr(cmd, pos, OutFile);  AppendStr(cmd, pos, " 2>&1");
  ok := PerformCommand(cmd, SyncExec, st);
  ReadOut(gOut); outTop := 0; ShowOutput(gOut);
  IF NOT ok THEN SetStatus("could not launch compiler"); gNErr := 0
  ELSIF st = 0 THEN gNErr := 0; IF run THEN SetStatus("ran ok") ELSE SetStatus("compiled ok") END
  ELSE ParseErrors; SetStatus("errors - click a problem, or F-jump"); JumpToError END;
  RenderEditor
END Compile;

PROCEDURE Build;  BEGIN Compile("build", FALSE) END Build;
PROCEDURE DoRun;  BEGIN Compile("run",   TRUE)  END DoRun;

(* run the current buffer under the runtime heap guard (--protect-heap) and show the
   program output + the guard's double-free / leak report in the output pane. *)
PROCEDURE DoGuardRun;
  VAR cmd: ARRAY [0..1023] OF CHAR; pos, st: CARDINAL; ok: BOOLEAN;
BEGIN
  SetStatus("running under heap guard..."); RenderEditor;
  IF NOT WriteWork() THEN SetStatus("save FAILED"); RenderEditor; RETURN END;
  pos := 0;
  AppendStr(cmd, pos, Compiler);  AppendStr(cmd, pos, " run ");
  AppendStr(cmd, pos, WorkFile);  AppendStr(cmd, pos, " --library "); AppendStr(cmd, pos, LibPath);
  AppendStr(cmd, pos, " --protect-heap > "); AppendStr(cmd, pos, OutFile); AppendStr(cmd, pos, " 2>&1");
  ok := PerformCommand(cmd, SyncExec, st);
  ReadOut(gOut); outTop := 0; ShowOutput(gOut); gNErr := 0;
  IF ok THEN SetStatus("ran under heap guard - see output") ELSE SetStatus("guard run failed") END;
  RenderEditor
END DoGuardRun;

(* compiler inspector: run a dump-* subcommand on the buffer and show it in the output pane *)
PROCEDURE Dump (sub, label: ARRAY OF CHAR);
  VAR cmd: ARRAY [0..1023] OF CHAR; pos, st: CARDINAL; ok: BOOLEAN;
BEGIN
  SetStatus("inspecting..."); RenderEditor;
  IF NOT WriteWork() THEN SetStatus("save FAILED"); RenderEditor; RETURN END;
  pos := 0;
  AppendStr(cmd, pos, Compiler); AppendStr(cmd, pos, " "); AppendStr(cmd, pos, sub); AppendStr(cmd, pos, " ");
  AppendStr(cmd, pos, WorkFile); AppendStr(cmd, pos, " --library "); AppendStr(cmd, pos, LibPath);
  AppendStr(cmd, pos, " > "); AppendStr(cmd, pos, OutFile); AppendStr(cmd, pos, " 2>&1");
  ok := PerformCommand(cmd, SyncExec, st);
  ReadOut(gOut); outTop := 0; ShowOutput(gOut);
  SetStatus(label); RenderEditor
END Dump;

(* read a file into the line buffer (split on LF, drop CR); set it as the current file *)
PROCEDURE LoadFile (path: ARRAY OF CHAR): BOOLEAN;
  VAR h, got: CARDINAL64; i, c, g: CARDINAL;
BEGIN
  h := NM2File.Open(ADR(path), NM2File.ReadFlag);
  IF h = 0 THEN RETURN FALSE END;
  got := NM2File.ReadText(h, ADR(gRaw), VAL(CARDINAL64, HIGH(gRaw)));
  NM2File.Close(h);
  g := VAL(CARDINAL, got); nLines := 0; c := 0; i := 0;
  WHILE (i < g) AND (nLines < MaxLines - 1) DO
    IF gRaw[i] = CHR(10) THEN line[nLines][c] := 0C; INC(nLines); c := 0
    ELSIF gRaw[i] # CHR(13) THEN IF c < MaxCol THEN line[nLines][c] := gRaw[i]; INC(c) END
    END;
    INC(i)
  END;
  line[nLines][c] := 0C; INC(nLines);              (* last (or only) line *)
  curRow := 0; curCol := 0; top := 0; gLeft := 0; gSelActive := FALSE; gNErr := 0; MarkDirty;
  i := 0; WHILE (i <= HIGH(path)) AND (i < 255) AND (path[i] # 0C) DO gFile[i] := path[i]; INC(i) END;
  gFile[i] := 0C;
  RETURN TRUE
END LoadFile;

(* ---- editing ---- *)
PROCEDURE CurLen (): CARDINAL;
BEGIN RETURN SLen(line[curRow]) END CurLen;

PROCEDURE InsertCh (ch: CHAR);
  VAR n, j: CARDINAL;
BEGIN
  gNErr := 0; MarkDirty;                       (* edit -> stale markers; schedule a live re-check *)
  n := CurLen(); IF n >= MaxCol THEN gOverflow := TRUE; RETURN END;   (* line at max width: drop, signal *)
  j := n; WHILE j > curCol DO line[curRow][j] := line[curRow][j-1]; DEC(j) END;
  line[curRow][curCol] := ch; line[curRow][n+1] := 0C; INC(curCol)
END InsertCh;

PROCEDURE NewLine (): BOOLEAN;                 (* FALSE if the buffer is at MaxLines (could not split) *)
  VAR r, j, n: CARDINAL;
BEGIN
  gNErr := 0; MarkDirty;
  IF nLines >= MaxLines THEN gOverflow := TRUE; RETURN FALSE END;
  r := nLines; WHILE r > curRow + 1 DO line[r] := line[r-1]; DEC(r) END;
  (* split current line at curCol into curRow and curRow+1 *)
  n := CurLen(); j := 0;
  WHILE curCol + j < n DO line[curRow+1][j] := line[curRow][curCol+j]; INC(j) END;
  line[curRow+1][j] := 0C; line[curRow][curCol] := 0C;
  INC(nLines); INC(curRow); curCol := 0; RETURN TRUE
END NewLine;

PROCEDURE Backspace;
  VAR n, p, j, k: CARDINAL;
BEGIN
  gNErr := 0; MarkDirty;
  IF curCol > 0 THEN
    n := CurLen(); j := curCol-1;
    WHILE j+1 < n DO line[curRow][j] := line[curRow][j+1]; INC(j) END;
    line[curRow][n-1] := 0C; DEC(curCol)
  ELSIF curRow > 0 THEN
    p := SLen(line[curRow-1]);
    IF p + SLen(line[curRow]) > MaxCol THEN                (* join would overflow -> refuse, keep all data *)
      SetStatus("line too long to merge"); RETURN
    END;
    k := 0;
    WHILE line[curRow][k] # 0C DO line[curRow-1][p+k] := line[curRow][k]; INC(k) END;
    line[curRow-1][p+k] := 0C;
    j := curRow; WHILE j+1 < nLines DO line[j] := line[j+1]; INC(j) END;
    DEC(nLines); DEC(curRow); curCol := p
  END
END Backspace;

PROCEDURE ClampCol;
  VAR n: CARDINAL;
BEGIN n := CurLen(); IF curCol > n THEN curCol := n END END ClampCol;

(* ---- selection + clipboard ---- *)
PROCEDURE PreMove;                           (* before a cursor move: extend (Shift) or drop the selection *)
BEGIN
  IF KeyDown(16) THEN                         (* VK_SHIFT *)
    IF NOT gSelActive THEN gAnchRow := curRow; gAnchCol := curCol; gSelActive := TRUE END
  ELSE gSelActive := FALSE END
END PreMove;

PROCEDURE DeleteSel;                          (* remove the selected range; cursor -> its start *)
  VAR loR, loC, hiR, hiC, j, k, tlen, removed: CARDINAL;
BEGIN
  IF NOT SelNorm(loR, loC, hiR, hiC) THEN RETURN END;
  gNErr := 0; MarkDirty;
  IF loR = hiR THEN
    tlen := SLen(line[loR]); j := loC; k := hiC;
    WHILE k <= tlen DO line[loR][j] := line[loR][k]; INC(j); INC(k) END    (* shift tail (incl NUL) left *)
  ELSE
    j := loC; k := hiC;                                                    (* loR keeps [0,loC) + hiR[hiC..] *)
    WHILE (line[hiR][k] # 0C) AND (j < MaxCol) DO line[loR][j] := line[hiR][k]; INC(j); INC(k) END;
    line[loR][j] := 0C;
    removed := hiR - loR; j := loR + 1;                                    (* drop the lines in between *)
    WHILE j + removed < nLines DO line[j] := line[j + removed]; INC(j) END;
    nLines := nLines - removed
  END;
  curRow := loR; curCol := loC; gSelActive := FALSE
END DeleteSel;

PROCEDURE CopySel (): BOOLEAN;                (* selected text -> clipboard (LF between lines) *)
  VAR loR, loC, hiR, hiC, r, c, p: CARDINAL;
BEGIN
  IF NOT SelNorm(loR, loC, hiR, hiC) THEN RETURN FALSE END;
  p := 0;
  IF loR = hiR THEN
    c := loC; WHILE (c < hiC) AND (line[loR][c] # 0C) AND (p < BufMax) DO gClip[p] := line[loR][c]; INC(p); INC(c) END
  ELSE
    c := loC; WHILE (line[loR][c] # 0C) AND (p < BufMax) DO gClip[p] := line[loR][c]; INC(p); INC(c) END;
    IF p < BufMax THEN gClip[p] := CHR(10); INC(p) END;
    r := loR + 1;
    WHILE r < hiR DO
      c := 0; WHILE (line[r][c] # 0C) AND (p < BufMax) DO gClip[p] := line[r][c]; INC(p); INC(c) END;
      IF p < BufMax THEN gClip[p] := CHR(10); INC(p) END; INC(r)
    END;
    c := 0; WHILE (c < hiC) AND (line[hiR][c] # 0C) AND (p < BufMax) DO gClip[p] := line[hiR][c]; INC(p); INC(c) END
  END;
  gClip[p] := 0C;
  RETURN Clipboard.SetText(gClip)
END CopySel;

PROCEDURE CutSel;
BEGIN IF CopySel() THEN DeleteSel END END CutSel;

PROCEDURE PasteClip;                          (* replace any selection, then insert clipboard text *)
  VAR i: CARDINAL; okl: BOOLEAN;
BEGIN
  IF HasSel() THEN DeleteSel END;
  gOverflow := FALSE;
  IF Clipboard.GetText(gClip) THEN
    i := 0;
    WHILE (i <= HIGH(gClip)) AND (gClip[i] # 0C) DO
      IF gClip[i] = CHR(10) THEN
        okl := NewLine();
        IF NOT okl THEN SetStatus("paste stopped: max lines reached"); RETURN END   (* don't merge onto wrong line *)
      ELSIF gClip[i] # CHR(13) THEN InsertCh(gClip[i]) END;
      INC(i)
    END;
    IF gOverflow THEN SetStatus("pasted (a line hit the max width)") ELSE SetStatus("pasted") END
  END
END PasteClip;

PROCEDURE SelectAll;
BEGIN
  gAnchRow := 0; gAnchCol := 0; gSelActive := TRUE;
  curRow := nLines - 1; curCol := SLen(line[curRow]); top := 0
END SelectAll;

(* ---- undo / redo (coalesced snapshots of the whole buffer) ---- *)
PROCEDURE SerializeTo (VAR dst: ARRAY OF CHAR): BOOLEAN;   (* buffer -> text; FALSE if it didn't fit (lossy) *)
  VAR r, k, p: CARDINAL;
BEGIN
  p := 0; r := 0;
  WHILE r < nLines DO
    IF (r > 0) AND (p < HIGH(dst)) THEN dst[p] := CHR(10); INC(p) END;
    k := 0; WHILE (k <= MaxCol) AND (line[r][k] # 0C) AND (p < HIGH(dst)) DO dst[p] := line[r][k]; INC(p); INC(k) END;
    INC(r)
  END;
  dst[p] := 0C;
  RETURN p < HIGH(dst)                              (* TRUE only if everything fit (no truncation) *)
END SerializeTo;

PROCEDURE ApplyBuf (VAR src: ARRAY OF CHAR);      (* text -> buffer (inverse of SerializeTo) *)
  VAR i, c: CARDINAL;
BEGIN
  nLines := 0; c := 0; i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (nLines < MaxLines - 1) DO
    IF src[i] = CHR(10) THEN line[nLines][c] := 0C; INC(nLines); c := 0
    ELSIF src[i] # CHR(13) THEN IF c < MaxCol THEN line[nLines][c] := src[i]; INC(c) END END;
    INC(i)
  END;
  line[nLines][c] := 0C; INC(nLines)
END ApplyBuf;

PROCEDURE PushUndo;                               (* snapshot current state onto the undo stack; invalidates redo *)
  VAR i: CARDINAL;
BEGIN
  IF gUN >= UndoMax THEN                           (* full -> drop the oldest *)
    i := 0; WHILE i < UndoMax-1 DO gUndo[i] := gUndo[i+1]; gURow[i] := gURow[i+1]; gUCol[i] := gUCol[i+1]; INC(i) END;
    DEC(gUN)
  END;
  IF SerializeTo(gUndo[gUN]) THEN                   (* skip lossy (too-big) snapshots rather than corrupt on restore *)
    gURow[gUN] := curRow; gUCol[gUN] := curCol; INC(gUN); gRN := 0
  END
END PushUndo;

PROCEDURE BeginEdit (kind: CARDINAL);             (* coalesce a run of same-kind edits into one undo step *)
BEGIN IF kind # gLastKind THEN PushUndo END; gLastKind := kind END BeginEdit;

PROCEDURE DoUndo;
  VAR i: CARDINAL;
BEGIN
  IF gUN = 0 THEN SetStatus("nothing to undo"); RenderEditor; RETURN END;
  IF gRN >= UndoMax THEN
    i := 0; WHILE i < UndoMax-1 DO gRedo[i] := gRedo[i+1]; gRRow[i] := gRRow[i+1]; gRCol[i] := gRCol[i+1]; INC(i) END; DEC(gRN)
  END;
  IF SerializeTo(gRedo[gRN]) THEN gRRow[gRN] := curRow; gRCol[gRN] := curCol; INC(gRN) END;   (* current -> redo *)
  DEC(gUN); ApplyBuf(gUndo[gUN]); curRow := gURow[gUN]; curCol := gUCol[gUN];
  IF curRow >= nLines THEN curRow := nLines-1 END; ClampCol;
  gSelActive := FALSE; gNErr := 0; gLastKind := 0; top := 0; gLeft := 0; MarkDirty;
  SetStatus("undo"); RenderEditor
END DoUndo;

PROCEDURE DoRedo;
  VAR i: CARDINAL;
BEGIN
  IF gRN = 0 THEN SetStatus("nothing to redo"); RenderEditor; RETURN END;
  IF gUN >= UndoMax THEN
    i := 0; WHILE i < UndoMax-1 DO gUndo[i] := gUndo[i+1]; gURow[i] := gURow[i+1]; gUCol[i] := gUCol[i+1]; INC(i) END; DEC(gUN)
  END;
  IF SerializeTo(gUndo[gUN]) THEN gURow[gUN] := curRow; gUCol[gUN] := curCol; INC(gUN) END;   (* current -> undo (keep redo) *)
  DEC(gRN); ApplyBuf(gRedo[gRN]); curRow := gRRow[gRN]; curCol := gRCol[gRN];
  IF curRow >= nLines THEN curRow := nLines-1 END; ClampCol;
  gSelActive := FALSE; gNErr := 0; gLastKind := 0; top := 0; gLeft := 0; MarkDirty;
  SetStatus("redo"); RenderEditor
END DoRedo;

(* ---- save / open ---- *)
PROCEDURE SaveTo (path: ARRAY OF CHAR): BOOLEAN;
  VAR h, w: CARDINAL64; nm: ARRAY [0..255] OF CHAR; buf: ARRAY [0..MaxCol+2] OF CHAR; r, k: CARDINAL;
BEGIN
  nm := path;
  h := NM2File.Open(ADR(nm), NM2File.WriteFlag + NM2File.NewFlag);
  IF h = 0 THEN RETURN FALSE END;
  r := 0;
  WHILE r < nLines DO
    k := 0; WHILE (k <= MaxCol) AND (line[r][k] # 0C) DO buf[k] := line[r][k]; INC(k) END;
    buf[k] := CHR(10);
    w := NM2File.WriteText(h, ADR(buf), VAL(CARDINAL64, k+1));
    INC(r)
  END;
  NM2File.Close(h); RETURN TRUE
END SaveTo;

PROCEDURE Save;
BEGIN
  IF SaveTo(gFile) THEN
    gDirty := FALSE; IF gActiveDoc < gNDoc THEN gDocs[gActiveDoc].dirty := FALSE END;   (* clear the tab '*' *)
    SetStatus("saved")
  ELSE SetStatus("save FAILED") END;
  RenderEditor
END Save;


PROCEDURE NewFile;
BEGIN
  nLines := 1; line[0][0] := 0C; curRow := 0; curCol := 0; top := 0; gLeft := 0;
  gSelActive := FALSE; gFile := "untitled"; gNErr := 0; MarkDirty; SetStatus("new file"); RenderEditor
END NewFile;

(* ============================ documents / tabs ============================ *)

(* serialize the LIVE buffer (line[]) into dst as newline-joined text *)
PROCEDURE DocSerialize (VAR dst: ARRAY OF CHAR);
  VAR r, k, p: CARDINAL;
BEGIN
  p := 0; r := 0;
  WHILE r < nLines DO
    k := 0; WHILE (line[r][k] # 0C) AND (p < HIGH(dst)) DO dst[p] := line[r][k]; INC(p); INC(k) END;
    IF p < HIGH(dst) THEN dst[p] := CHR(10); INC(p) END;
    INC(r)
  END;
  dst[p] := 0C
END DocSerialize;

(* parse newline-joined text in src into the LIVE buffer (line[], nLines) *)
PROCEDURE DocDeserialize (VAR src: ARRAY OF CHAR);
  VAR i, c: CARDINAL;
BEGIN
  nLines := 0; c := 0; i := 0;
  WHILE (i <= HIGH(src)) AND (src[i] # 0C) AND (nLines < MaxLines - 1) DO
    IF src[i] = CHR(10) THEN line[nLines][c] := 0C; INC(nLines); c := 0
    ELSIF src[i] # CHR(13) THEN IF c < MaxCol THEN line[nLines][c] := src[i]; INC(c) END END;
    INC(i)
  END;
  line[nLines][c] := 0C; INC(nLines)
END DocDeserialize;

(* snapshot the live editor state into the active doc's slot *)
PROCEDURE DocSaveActive;
BEGIN
  IF gActiveDoc < gNDoc THEN
    IF gDocs[gActiveDoc].text = NIL THEN NEW(gDocs[gActiveDoc].text) END;
    DocSerialize(gDocs[gActiveDoc].text^);
    gDocs[gActiveDoc].nLines := nLines; gDocs[gActiveDoc].curRow := curRow;
    gDocs[gActiveDoc].curCol := curCol; gDocs[gActiveDoc].top := top;
    gDocs[gActiveDoc].gLeft := gLeft; gDocs[gActiveDoc].dirty := gDirty;
    SCopy(gDocs[gActiveDoc].path, gFile)
  END
END DocSaveActive;

(* load the active doc's slot into the live editor state (resets undo + selection) *)
PROCEDURE DocLoadActive;
BEGIN
  IF gDocs[gActiveDoc].text # NIL THEN DocDeserialize(gDocs[gActiveDoc].text^)
  ELSE nLines := 1; line[0][0] := 0C END;
  curRow := gDocs[gActiveDoc].curRow; curCol := gDocs[gActiveDoc].curCol;
  top := gDocs[gActiveDoc].top; gLeft := gDocs[gActiveDoc].gLeft;
  gDirty := gDocs[gActiveDoc].dirty; SCopy(gFile, gDocs[gActiveDoc].path);
  gSelActive := FALSE; gNErr := 0; gUN := 0; gRN := 0; gLastKind := 0;
  IF curRow >= nLines THEN curRow := nLines - 1 END
END DocLoadActive;

PROCEDURE FindOpenDoc (path: ARRAY OF CHAR): CARDINAL;
  VAR i: CARDINAL;
BEGIN
  i := 0; WHILE i < gNDoc DO IF StrEq(gDocs[i].path, path) THEN RETURN i END; INC(i) END;
  RETURN MaxDocs
END FindOpenDoc;

PROCEDURE SwitchToDoc (i: CARDINAL);
BEGIN
  IF (i >= gNDoc) OR (i = gActiveDoc) THEN RETURN END;
  DocSaveActive; gActiveDoc := i; DocLoadActive; EnsureTabVisible; RenderEditor
END SwitchToDoc;

(* open `path` in a tab: switch if already open, else load it into a new tab *)
PROCEDURE OpenInTab (path: ARRAY OF CHAR);
  VAR idx: CARDINAL;
BEGIN
  idx := FindOpenDoc(path);
  IF idx < gNDoc THEN SwitchToDoc(idx); RETURN END;
  IF gNDoc >= MaxDocs THEN SetStatus("too many tabs (close one)"); RenderEditor; RETURN END;
  DocSaveActive;
  IF NOT LoadFile(path) THEN SetStatus("open failed"); RenderEditor; RETURN END;
  gActiveDoc := gNDoc; INC(gNDoc);
  IF gDocs[gActiveDoc].text = NIL THEN NEW(gDocs[gActiveDoc].text) END;
  gDocs[gActiveDoc].used := TRUE; SCopy(gDocs[gActiveDoc].path, gFile);
  gDocs[gActiveDoc].dirty := FALSE; gDirty := FALSE;
  EnsureTabVisible; RenderEditor
END OpenInTab;

PROCEDURE CloseDoc (i: CARDINAL);
  VAR j: CARDINAL; wasActive: BOOLEAN;
BEGIN
  IF i >= gNDoc THEN RETURN END;
  wasActive := (i = gActiveDoc);
  IF NOT wasActive THEN DocSaveActive END;               (* preserve the active doc before shifting slots *)
  IF gDocs[i].text # NIL THEN DISPOSE(gDocs[i].text); gDocs[i].text := NIL END;   (* free the closed buffer *)
  j := i; WHILE j + 1 < gNDoc DO gDocs[j] := gDocs[j+1]; INC(j) END;
  gDocs[gNDoc-1].text := NIL;                             (* old last slot: its pointer now lives in [gNDoc-2] *)
  DEC(gNDoc);
  IF gNDoc = 0 THEN
    NewFile; gNDoc := 1; gActiveDoc := 0; gDocs[0].used := TRUE;
    IF gDocs[0].text = NIL THEN NEW(gDocs[0].text) END; SCopy(gDocs[0].path, gFile); RETURN
  END;
  IF gActiveDoc > i THEN DEC(gActiveDoc)
  ELSIF gActiveDoc = i THEN IF gActiveDoc >= gNDoc THEN gActiveDoc := gNDoc - 1 END END;
  DocLoadActive; EnsureTabVisible; RenderEditor
END CloseDoc;

(* write a serialized doc blob straight to disk (same byte path as SaveTo) *)
PROCEDURE WriteBlob (path: ARRAY OF CHAR; VAR blob: ARRAY OF CHAR): BOOLEAN;
  VAR h, w: CARDINAL64; nm: ARRAY [0..511] OF CHAR; n: CARDINAL;
BEGIN
  SCopy(nm, path); h := NM2File.Open(ADR(nm), NM2File.WriteFlag + NM2File.NewFlag);
  IF h = 0 THEN RETURN FALSE END;
  n := SLen(blob); w := NM2File.WriteText(h, ADR(blob), VAL(CARDINAL64, n));
  NM2File.Close(h); RETURN TRUE
END WriteBlob;

(* save every modified, real (non-untitled) document to disk — so a project build
   sees the target + all imported siblings as they are in the editor *)
PROCEDURE SaveAllDirty;
  VAR i: CARDINAL;
BEGIN
  DocSaveActive;
  i := 0;
  WHILE i < gNDoc DO
    IF gDocs[i].dirty AND (gDocs[i].text # NIL) AND (NOT IsUntitled(gDocs[i].path)) THEN
      IF WriteBlob(gDocs[i].path, gDocs[i].text^) THEN gDocs[i].dirty := FALSE END
    END;
    INC(i)
  END;
  gDirty := FALSE
END SaveAllDirty;

(* pin the active file as the build/run entry (F9/F5 then build it from any tab) *)
PROCEDURE SetBuildTarget;
  VAR nm: ARRAY [0..127] OF CHAR; msg: ARRAY [0..255] OF CHAR; p: CARDINAL;
BEGIN
  IF IsUntitled(gFile) THEN SetStatus("save the file first to pin it as the build target")
  ELSE
    SCopy(gBuildTarget, gFile); BaseName(gFile, nm);
    p := 0; AppendStr(msg, p, "build target = "); AppendStr(msg, p, nm); SetStatus(msg)
  END;
  RenderEditor
END SetBuildTarget;

(* a fresh empty document in a new tab *)
PROCEDURE NewTab;
BEGIN
  IF gNDoc >= MaxDocs THEN SetStatus("too many tabs (close one)"); RenderEditor; RETURN END;
  DocSaveActive;
  gActiveDoc := gNDoc; INC(gNDoc);
  IF gDocs[gActiveDoc].text = NIL THEN NEW(gDocs[gActiveDoc].text) END;
  gDocs[gActiveDoc].used := TRUE;
  nLines := 1; line[0][0] := 0C; curRow := 0; curCol := 0; top := 0; gLeft := 0;
  gSelActive := FALSE; gNErr := 0; gUN := 0; gRN := 0; gLastKind := 0;
  SCopy(gFile, "untitled"); SCopy(gDocs[gActiveDoc].path, "untitled");
  gDocs[gActiveDoc].dirty := FALSE; gDirty := FALSE;
  SetStatus("new file"); RenderEditor
END NewTab;

PROCEDURE OpenDialog;
  VAR pathBuf: ARRAY [0..511] OF CHAR;
BEGIN
  SCopy(pathBuf, gFile);
  IF OpenFile(FrameOf(win), pathBuf, "Modula-2|*.mod;*.def|All files|*.*", "Open") THEN OpenInTab(pathBuf) END
END OpenDialog;

PROCEDURE SaveAs;
  VAR pathBuf: ARRAY [0..511] OF CHAR; i: CARDINAL;
BEGIN
  i := 0; WHILE (i <= HIGH(gFile)) AND (gFile[i] # 0C) DO pathBuf[i] := gFile[i]; INC(i) END; pathBuf[i] := 0C;
  IF SaveFile(FrameOf(win), pathBuf, "Modula-2|*.mod;*.def|All files|*.*", "Save As", "mod") THEN
    IF SaveTo(pathBuf) THEN
      i := 0; WHILE (i <= HIGH(pathBuf)) AND (i < 255) AND (pathBuf[i] # 0C) DO gFile[i] := pathBuf[i]; INC(i) END;
      gFile[i] := 0C; SetStatus("saved")
    ELSE SetStatus("save FAILED") END
  END;
  RenderEditor
END SaveAs;

PROCEDURE About;                              (* non-modal in-grid overlay (cooler than a MessageBox) *)
BEGIN gAboutMode := TRUE; SetStatus("about"); RenderEditor END About;

(* ---- find ---- *)
PROCEDURE FindIn (VAR ln: ARRAY OF CHAR; from: CARDINAL; VAR at: CARDINAL): BOOLEAN;
  VAR i, j, n, tlen: CARDINAL; ok: BOOLEAN;
BEGIN
  tlen := SLen(gFindTerm); n := SLen(ln);
  IF (tlen = 0) OR (tlen > n) THEN RETURN FALSE END;
  i := from;
  WHILE i + tlen <= n DO
    j := 0; ok := TRUE;
    WHILE (j < tlen) AND ok DO IF ln[i+j] # gFindTerm[j] THEN ok := FALSE END; INC(j) END;
    IF ok THEN at := i; RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END FindIn;

PROCEDURE DoFind;                             (* forward from just past the cursor, wrapping; selects the hit *)
  VAR r, startCol, at, tlen, scanned: CARDINAL; found: BOOLEAN;
BEGIN
  tlen := SLen(gFindTerm); IF tlen = 0 THEN RETURN END;
  found := FALSE; r := curRow; startCol := curCol + 1; scanned := 0;
  WHILE (scanned <= nLines) AND (NOT found) DO
    IF FindIn(line[r], startCol, at) THEN
      curRow := r; curCol := at; gAnchRow := r; gAnchCol := at + tlen; gSelActive := TRUE; found := TRUE
    ELSE
      INC(r); IF r >= nLines THEN r := 0 END; startCol := 0; INC(scanned)
    END
  END;
  IF found THEN SetStatus("found") ELSE gSelActive := FALSE; SetStatus("not found") END
END DoFind;

PROCEDURE StartFind;
BEGIN gFindMode := TRUE; gFindTerm[0] := 0C; RenderEditor END StartFind;

PROCEDURE FindNext;
BEGIN IF SLen(gFindTerm) > 0 THEN DoFind; RenderEditor END END FindNext;

(* ---- menu bar (a Terminal menu on the editor grid; F10 / mouse drive it) ---- *)
PROCEDURE MenuAction (mi, it: CARDINAL);
  VAR okg: BOOLEAN;
BEGIN
  Terminal.Use(edT); Terminal.MenuClose; Terminal.MenuSetFocus(FALSE); gMenuMode := FALSE;
  IF mi = 0 THEN                                    (* File: New Open Save SaveAs Exit *)
    IF    it = 0 THEN NewTab
    ELSIF it = 1 THEN OpenDialog
    ELSIF it = 2 THEN Save
    ELSIF it = 3 THEN SaveAs
    ELSIF it = 4 THEN Quit(ws) END
  ELSIF mi = 1 THEN                                 (* Edit: Cut Copy Paste SelectAll *)
    IF    it = 0 THEN CutSel
    ELSIF it = 1 THEN okg := CopySel()
    ELSIF it = 2 THEN PasteClip
    ELSIF it = 3 THEN SelectAll END
  ELSIF mi = 2 THEN                                 (* Search: Find / Find Next *)
    IF it = 0 THEN StartFind ELSIF it = 1 THEN FindNext END
  ELSIF mi = 3 THEN                                 (* View: compiler inspector *)
    IF    it = 0 THEN Dump("dump-tokens", "tokens")
    ELSIF it = 1 THEN Dump("dump-ast",    "AST")
    ELSIF it = 2 THEN Dump("dump-sema",   "sema")
    ELSIF it = 3 THEN Dump("dump-ir",     "IR")
    ELSIF it = 4 THEN Dump("dump-llvm",   "LLVM") END
  ELSIF mi = 4 THEN                                 (* Build: Build / Run / Analyze / Run+Guard *)
    IF it = 0 THEN SaveAllDirty; Build ELSIF it = 1 THEN SaveAllDirty; DoRun
    ELSIF it = 2 THEN DoAnalyze ELSIF it = 3 THEN DoGuardRun ELSIF it = 4 THEN SetBuildTarget END
  ELSIF mi = 5 THEN                                 (* Help: About *)
    IF it = 0 THEN About END
  END;
  RenderEditor
END MenuAction;

PROCEDURE EnterMenu;
BEGIN gMenuMode := TRUE; Terminal.Use(edT); Terminal.MenuSetFocus(TRUE); Terminal.MenuSelect(0); RenderEditor END EnterMenu;

PROCEDURE LeaveMenu;
BEGIN gMenuMode := FALSE; Terminal.Use(edT); Terminal.MenuClose; Terminal.MenuSetFocus(FALSE); RenderEditor END LeaveMenu;

PROCEDURE OpenCur;                            (* open the selected menu + highlight its first item *)
BEGIN Terminal.MenuOpen; Terminal.MenuItemSelect(0) END OpenCur;

PROCEDURE MenuKey (key: CARDINAL);
  VAR b: BOOLEAN;
BEGIN
  Terminal.Use(edT);                          (* arrows + F10 only; Enter/Esc come via EvChar (avoid the dual keydown+char) *)
  IF Terminal.MenuIsOpen() THEN
    IF    key = 38 THEN b := Terminal.MenuItemPrev()                                  (* Up *)
    ELSIF key = 40 THEN b := Terminal.MenuItemNext()                                  (* Down *)
    ELSIF key = 37 THEN Terminal.MenuClose; b := Terminal.MenuPrev(); OpenCur   (* Left *)
    ELSIF key = 39 THEN Terminal.MenuClose; b := Terminal.MenuNext(); OpenCur   (* Right *)
    ELSIF key = 121 THEN LeaveMenu; RETURN                                            (* F10 *)
    END
  ELSE
    IF    key = 37 THEN b := Terminal.MenuPrev()
    ELSIF key = 39 THEN b := Terminal.MenuNext()
    ELSIF key = 40 THEN OpenCur
    ELSIF key = 121 THEN LeaveMenu; RETURN
    END
  END;
  RenderEditor
END MenuKey;

PROCEDURE MenuEnter;                          (* Enter while in the menu: open the bar item, or run the drop-down item *)
BEGIN
  Terminal.Use(edT);
  IF Terminal.MenuIsOpen() THEN MenuAction(Terminal.MenuSelected(), Terminal.MenuItemSelected())
  ELSE OpenCur; RenderEditor END
END MenuEnter;

(* map a pixel point in the editor body to a clamped buffer (row,col) *)
PROCEDURE BodyPos (col, row: CARDINAL; VAR br, bc: CARDINAL);
BEGIN
  IF row < EdTop THEN row := EdTop END;
  br := top + (row - EdTop); IF br >= nLines THEN br := nLines - 1 END;
  IF col >= Gutter + 1 THEN bc := gLeft + (col - (Gutter + 1)) ELSE bc := gLeft END;
  IF bc > SLen(line[br]) THEN bc := SLen(line[br]) END
END BodyPos;

PROCEDURE PressAt (px, py: INTEGER);             (* a left-button press: menu, drop-down, or start a body selection *)
  VAR cw, ch, col, row, mi, it, br, bc, ti, tvc, tvr: CARDINAL;
BEGIN
  CellSize(edB, cw, ch); IF (cw = 0) OR (ch = 0) THEN RETURN END;
  col := VAL(CARDINAL, px) DIV cw; row := VAL(CARDINAL, py) DIV ch;
  Terminal.Use(edT);
  IF row = 0 THEN                                   (* menu bar *)
    mi := Terminal.MenuBarHit(col);
    IF mi # MAX(CARDINAL) THEN
      Terminal.MenuSetFocus(TRUE); Terminal.MenuSelect(mi); OpenCur;
      gMenuMode := Terminal.MenuIsOpen()
    END;
    RenderEditor
  ELSIF gMenuMode AND Terminal.MenuIsOpen() THEN    (* an open drop-down *)
    it := Terminal.MenuPopupHit(col, row);
    IF it # MAX(CARDINAL) THEN MenuAction(Terminal.MenuSelected(), it) ELSE LeaveMenu END
  ELSIF row = TabRow THEN                           (* the tab strip: arrows / close 'x' / switch *)
    VisibleCells(edB, tvc, tvr); IF tvc = 0 THEN tvc := Terminal.Cols() END;
    IF (gTabTop > 0) AND (col < 2) THEN DEC(gTabTop); RenderEditor              (* '<' scroll left *)
    ELSIF gTabRight AND (col >= tvc - 2) THEN INC(gTabTop); RenderEditor        (* '>' scroll right *)
    ELSIF col >= 2 THEN
      ti := gTabTop + (col - 2) DIV TabW;
      IF ti < gNDoc THEN
        IF (col - 2) MOD TabW = TabClose THEN CloseDoc(ti) ELSE SwitchToDoc(ti) END
      END
    END
  ELSE                                              (* the body *)
    IF gMenuMode THEN LeaveMenu END;
    BodyPos(col, row, br, bc);
    IF KeyDown(16) THEN                              (* Shift+click -> extend from the existing anchor *)
      IF NOT gSelActive THEN gAnchRow := curRow; gAnchCol := curCol; gSelActive := TRUE END
    ELSE                                            (* plain press -> new anchor here (empty until dragged) *)
      gAnchRow := br; gAnchCol := bc; gSelActive := TRUE
    END;
    curRow := br; curCol := bc; gMouseSel := TRUE; gLastKind := 0;
    RenderEditor
  END
END PressAt;

PROCEDURE DragTo (px, py: INTEGER);              (* extend the selection to the dragged point (anchor stays) *)
  VAR cw, ch, col, row, br, bc: CARDINAL;
BEGIN
  CellSize(edB, cw, ch); IF (cw = 0) OR (ch = 0) THEN RETURN END;
  col := VAL(CARDINAL, px) DIV cw; row := VAL(CARDINAL, py) DIV ch;
  IF row < EdTop THEN RETURN END;                   (* don't drag-select up into the menu / tab rows *)
  BodyPos(col, row, br, bc);
  curRow := br; curCol := bc; RenderEditor
END DragTo;

(* click a line in the OUTPUT pane: if it names "line N, column M", jump there (Problems) *)
PROCEDURE OutClick (py: INTEGER);
  VAR cw, ch, row, i, ln, n, m: CARDINAL; fh: HWND;
BEGIN
  CellSize(outB, cw, ch); IF ch = 0 THEN RETURN END;
  row := VAL(CARDINAL, py) DIV ch;
  ln := 0; i := 0;                                  (* find the start of logical line (outTop + row) *)
  WHILE (ln < outTop + row) AND (i <= HIGH(gOut)) AND (gOut[i] # 0C) DO
    IF gOut[i] = CHR(10) THEN INC(ln) END; INC(i)
  END;
  n := 0; m := 0;                                   (* scan that line for line/column *)
  WHILE (i <= HIGH(gOut)) AND (gOut[i] # 0C) AND (gOut[i] # CHR(10)) DO
    IF MatchAt(i, "line ")   THEN n := NumAt(i + 5) END;
    IF MatchAt(i, "column ") THEN m := NumAt(i + 7) END;
    INC(i)
  END;
  IF (n > 0) AND (n <= nLines) THEN
    curRow := n - 1; IF m > 0 THEN curCol := m - 1 END;
    IF curCol > SLen(line[curRow]) THEN curCol := SLen(line[curRow]) END;
    gSelActive := FALSE; top := 0; gLeft := 0;
    fh := SetFocus(CAST(HWND, HostOf(edPane))); RenderEditor
  END
END OutClick;

(* click a row in the SIDEBAR: toggle a folder, or open a file in a tab *)
PROCEDURE SidebarClick (py: INTEGER);
  VAR cw, ch, row, i: CARDINAL;
BEGIN
  CellSize(sidB, cw, ch); IF ch = 0 THEN RETURN END;
  gCompMode := FALSE;                               (* a tree click dismisses any open completion popup *)
  row := VAL(CARDINAL, py) DIV ch;
  i := gTreeTop + row;
  IF i >= gTreeN THEN RETURN END;
  gTreeSel := i;
  IF gTree[i].isDir THEN ToggleNode(i) ELSE OpenInTab(gTree[i].path) END;
  RenderSidebar
END SidebarClick;

(* ---- ptcl host verbs: editor commands exposed to the scripting language ---- *)
PROCEDURE VGoto (): BOOLEAN;                  (* goto N -> move the cursor to line N *)
  VAR n: INTEGER;
BEGIN
  n := Ptcl.ArgInt(1);
  IF (n >= 1) AND (VAL(CARDINAL, n) <= nLines) THEN curRow := VAL(CARDINAL, n) - 1; ClampCol; gLastKind := 0 END;
  RETURN TRUE
END VGoto;

PROCEDURE VFind (): BOOLEAN;                  (* find PATTERN -> search + select the hit *)
  VAR a: ARRAY [0..127] OF CHAR; i: CARDINAL;
BEGIN
  Ptcl.Arg(1, a);
  i := 0; WHILE (a[i] # 0C) AND (i < 127) DO gFindTerm[i] := a[i]; INC(i) END; gFindTerm[i] := 0C;
  DoFind; RETURN TRUE
END VFind;

PROCEDURE VBuild   (): BOOLEAN; BEGIN Build; RETURN TRUE END VBuild;
PROCEDURE VRun     (): BOOLEAN; BEGIN DoRun; RETURN TRUE END VRun;
PROCEDURE VAnalyze (): BOOLEAN; BEGIN DoAnalyze; RETURN TRUE END VAnalyze;     (* static NEW/DISPOSE check *)
PROCEDURE VGuard   (): BOOLEAN; BEGIN DoGuardRun; RETURN TRUE END VGuard;      (* run under the heap guard *)

PROCEDURE VLineCount (): BOOLEAN;             (* linecount -> the number of lines *)
  VAR s: ARRAY [0..15] OF CHAR; p: CARDINAL;
BEGIN p := 0; AppendCard(s, p, nLines); Ptcl.Result(s); RETURN TRUE END VLineCount;

PROCEDURE VCursor (): BOOLEAN;                (* cursor -> "<line> <col>" *)
  VAR s: ARRAY [0..31] OF CHAR; p: CARDINAL;
BEGIN
  p := 0; AppendCard(s, p, curRow + 1); AppendStr(s, p, " "); AppendCard(s, p, curCol + 1);
  Ptcl.Result(s); RETURN TRUE
END VCursor;

PROCEDURE VStatus (): BOOLEAN;                (* status MSG -> set the status line *)
  VAR a: ARRAY [0..127] OF CHAR;
BEGIN Ptcl.Arg(1, a); SetStatus(a); RETURN TRUE END VStatus;

PROCEDURE VInsert (): BOOLEAN;                (* insert TEXT -> type TEXT at the cursor *)
  VAR a: ARRAY [0..511] OF CHAR; i: CARDINAL;
BEGIN
  Ptcl.Arg(1, a); BeginEdit(1); IF HasSel() THEN DeleteSel END;
  i := 0; WHILE a[i] # 0C DO InsertCh(a[i]); INC(i) END;
  RETURN TRUE
END VInsert;

PROCEDURE RegisterVerbs;
BEGIN
  Ptcl.Register("goto", VGoto);       Ptcl.Register("find", VFind);
  Ptcl.Register("build", VBuild);     Ptcl.Register("run", VRun);
  Ptcl.Register("analyze", VAnalyze); Ptcl.Register("guard", VGuard);
  Ptcl.Register("linecount", VLineCount);  Ptcl.Register("cursor", VCursor);
  Ptcl.Register("status", VStatus);   Ptcl.Register("insert", VInsert)
END RegisterVerbs;

PROCEDURE StartCmd;   (* open the ptcl command prompt (Ctrl+P) *)
BEGIN gCmdMode := TRUE; gCmdLine[0] := 0C; SetStatus("ptcl"); RenderEditor END StartCmd;

PROCEDURE RunCmd;     (* evaluate the typed command; show its result in the status line *)
  VAR out: ARRAY [0..1023] OF CHAR; m: ARRAY [0..255] OF CHAR; p: CARDINAL; ok: BOOLEAN;
BEGIN
  ok := Ptcl.Eval(gCmdLine, out);
  p := 0; IF ok THEN AppendStr(m, p, "=> ") ELSE AppendStr(m, p, "ptcl error: ") END;
  AppendStr(m, p, out);
  SetStatus(m); RenderEditor                (* verbs like build/run paint the output pane themselves *)
END RunCmd;

(* Exec-over-pipe: poll the IDE's own pipe; run any external ptcl command through the
   SAME interpreter, on the UI thread (so its verbs touch panes safely). Non-blocking. *)
PROCEDURE ServePipe;
  VAR cmd: ARRAY [0..4095] OF CHAR; out: ARRAY [0..1023] OF CHAR;
      m: ARRAY [0..1151] OF CHAR; p: CARDINAL;
BEGIN
  IF PipeServer.Poll(cmd) THEN
    IF Ptcl.Eval(cmd, out) THEN PipeServer.Reply(out)
    ELSE p := 0; AppendStr(m, p, "error: "); AppendStr(m, p, out); PipeServer.Reply(m) END;
    RenderEditor; ShowOutput(gOut)          (* the command may have changed editor / output state *)
  END
END ServePipe;

(* ---- autocomplete (Ctrl+Space or `.` -> daemon `complete` verb -> popup) ---- *)

PROCEDURE IsIdentCh (c: CHAR): BOOLEAN;
BEGIN
  RETURN ((c >= 'A') AND (c <= 'Z')) OR ((c >= 'a') AND (c <= 'z'))
      OR ((c >= '0') AND (c <= '9')) OR (c = '_')
END IsIdentCh;

PROCEDURE LowerC (c: CHAR): CHAR;
BEGIN IF (c >= 'A') AND (c <= 'Z') THEN RETURN CHR(ORD(c) + 32) ELSE RETURN c END END LowerC;

PROCEDURE PrefixMatch (VAR name: ARRAY OF CHAR; VAR pfx: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE pfx[i] # 0C DO
    IF (name[i] = 0C) OR (LowerC(name[i]) # LowerC(pfx[i])) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END PrefixMatch;

(* The word being completed: line[curRow][gCompStart .. curCol). *)
PROCEDURE CompPartial (VAR p: ARRAY OF CHAR);
  VAR i, n: CARDINAL;
BEGIN
  i := gCompStart; n := 0;
  WHILE (i < curCol) AND (n < HIGH(p)) DO p[n] := line[curRow][i]; INC(i); INC(n) END;
  p[n] := 0C
END CompPartial;

(* Rebuild gVis (the candidates matching the typed partial) + clamp the selection.
   Client-side narrowing: the daemon returned the full member list once. *)
PROCEDURE FilterComp;
  VAR i: CARDINAL; pfx: ARRAY [0..63] OF CHAR;
BEGIN
  CompPartial(pfx); gVisN := 0; i := 0;
  WHILE i < gCompN DO
    IF PrefixMatch(gCompName[i], pfx) THEN gVis[gVisN] := i; INC(gVisN) END;
    INC(i)
  END;
  IF gCompSel >= gVisN THEN gCompSel := 0 END;
  IF gVisN = 0 THEN gCompMode := FALSE END
END FilterComp;

(* Parse the daemon reply (`name<TAB>kind<TAB>detail` lines; `ok`/`error…` = none). *)
PROCEDURE ParseCompletions;
  VAR i, f, col: CARDINAL; ch: CHAR;
BEGIN
  gCompN := 0;
  IF (gReply[0] = 'o') AND (gReply[1] = 'k') THEN RETURN END;
  IF (gReply[0] = 'e') AND (gReply[1] = 'r') AND (gReply[2] = 'r') THEN RETURN END;
  i := 0;
  WHILE (gReply[i] # 0C) AND (gCompN < MaxComp) DO
    f := 0; col := 0;
    gCompName[gCompN][0] := 0C; gCompKind[gCompN][0] := 0C; gCompDetail[gCompN][0] := 0C;
    WHILE (gReply[i] # 0C) AND (gReply[i] # CHR(10)) DO
      ch := gReply[i];
      IF ch = CHR(9) THEN INC(f); col := 0
      ELSIF f = 0 THEN IF col < 63 THEN gCompName[gCompN][col] := ch; gCompName[gCompN][col+1] := 0C; INC(col) END
      ELSIF f = 1 THEN IF col < 11 THEN gCompKind[gCompN][col] := ch; gCompKind[gCompN][col+1] := 0C; INC(col) END
      ELSE IF col < 63 THEN gCompDetail[gCompN][col] := ch; gCompDetail[gCompN][col+1] := 0C; INC(col) END
      END;
      INC(i)
    END;
    IF gReply[i] = CHR(10) THEN INC(i) END;
    IF SLen(gCompName[gCompN]) > 0 THEN INC(gCompN) END
  END
END ParseCompletions;

(* Ask the daemon for the members visible at the cursor, then show the popup.
   Query at gCompStart (empty prefix) so the daemon returns the FULL member
   list; FilterComp narrows it client-side as you type (one query per trigger). *)
PROCEDURE TriggerCompletion;
  VAR cmd: ARRAY [0..1023] OF CHAR; pos: CARDINAL;
BEGIN
  gCompStart := curCol;
  WHILE (gCompStart > 0) AND IsIdentCh(line[curRow][gCompStart-1]) DO DEC(gCompStart) END;
  IF NOT WriteWork() THEN gCompMode := FALSE; SetStatus("complete: write failed"); RenderEditor; RETURN END;
  pos := 0; AppendStr(cmd, pos, 'complete "'); AppendStr(cmd, pos, WorkFile);
  AppendStr(cmd, pos, '" '); AppendCard(cmd, pos, curRow + 1);
  AppendStr(cmd, pos, " "); AppendCard(cmd, pos, gCompStart);
  IF NOT DaemonAsk(cmd, gReply) THEN gCompMode := FALSE; SetStatus("complete: no daemon"); RenderEditor; RETURN END;
  ParseCompletions;
  IF gCompN = 0 THEN gCompMode := FALSE; SetStatus("no completions"); RenderEditor; RETURN END;
  gCompSel := 0; gCompTop := 0; gCompMode := TRUE;
  FilterComp;
  RenderEditor
END TriggerCompletion;

(* Replace the partial word with the selected candidate. *)
PROCEDURE AcceptCompletion;
  VAR nm: ARRAY [0..63] OF CHAR; src, dst, i: CARDINAL;
BEGIN
  gCompMode := FALSE;
  IF (gVisN = 0) OR (gCompSel >= gVisN) THEN RenderEditor; RETURN END;
  nm := gCompName[gVis[gCompSel]];
  BeginEdit(1); MarkDirty;
  src := curCol; dst := gCompStart;                       (* delete [gCompStart, curCol) on the current line *)
  WHILE line[curRow][src] # 0C DO line[curRow][dst] := line[curRow][src]; INC(dst); INC(src) END;
  line[curRow][dst] := 0C; curCol := gCompStart;
  i := 0; WHILE nm[i] # 0C DO InsertCh(nm[i]); INC(i) END;
  RenderEditor
END AcceptCompletion;

PROCEDURE OnEvent (VAR e: Event): BOOLEAN;
  VAR rows, btn, flen: CARDINAL; mx, my: INTEGER; fh: HWND; ok: BOOLEAN;
BEGIN
  IF e.kind = EvCloseRequest THEN Quit(ws)
  ELSIF e.kind = EvResize THEN
    fh := SetFocus(CAST(HWND, HostOf(edPane)));     (* the editor grid (a child host) must hold focus to get keys *)
    RenderSidebar; RenderEditor; ShowOutput(gOut)
  ELSIF e.kind = EvTimer THEN                        (* idle tick: re-check after a typing pause + serve the Exec pipe *)
    IF gDirty AND (VAL(CARDINAL, GetTickCount()) - gEditTime >= 300) THEN gDirty := FALSE; DoCheck END;
    ServePipe
  ELSIF e.kind = EvMouse THEN
    MouseAt(mx, my, btn);                            (* Event has no button field -> poll: press / drag / release *)
    IF (btn MOD 2 = 1) AND (gPrevBtn MOD 2 = 0) THEN            (* press edge *)
      IF gAboutMode THEN gAboutMode := FALSE; SetStatus("ready"); RenderEditor   (* click anywhere closes About *)
      ELSIF e.pane = edPane THEN PressAt(e.x, e.y)
      ELSIF e.pane = sidPane THEN SidebarClick(e.y)            (* click a tree row -> toggle / open *)
      ELSIF e.pane = outPane THEN OutClick(e.y) END             (* click a problem -> jump *)
    ELSIF (btn MOD 2 = 1) AND (gPrevBtn MOD 2 = 1) AND gMouseSel AND (e.pane = edPane) THEN  (* dragging *)
      DragTo(e.x, e.y)
    ELSIF (btn MOD 2 = 0) AND (gPrevBtn MOD 2 = 1) THEN         (* release *)
      gMouseSel := FALSE
    END;
    gPrevBtn := btn
  ELSIF e.kind = EvWheel THEN
    IF e.pane = outPane THEN                          (* scroll the output pane *)
      IF e.y > 0 THEN IF outTop >= 3 THEN outTop := outTop - 3 ELSE outTop := 0 END ELSE INC(outTop, 3) END;
      ShowOutput(gOut)
    ELSIF e.pane = sidPane THEN                       (* scroll the file tree *)
      IF e.y > 0 THEN IF gTreeTop >= 3 THEN gTreeTop := gTreeTop - 3 ELSE gTreeTop := 0 END
      ELSE INC(gTreeTop, 3); IF (gTreeN > 0) AND (gTreeTop >= gTreeN) THEN gTreeTop := gTreeN - 1 END END;
      RenderSidebar
    ELSE                                             (* scroll the editor (free scroll, cursor may leave view) *)
      IF e.y > 0 THEN IF top >= 3 THEN top := top - 3 ELSE top := 0 END
      ELSE INC(top, 3); IF top >= nLines THEN top := nLines - 1 END END;
      gFollow := FALSE; RenderEditor
    END
  ELSIF e.kind = EvChar THEN
    IF gAboutMode THEN gAboutMode := FALSE; SetStatus("ready"); RenderEditor   (* any key closes About *)
    ELSIF gFindMode THEN                             (* the status line is a Find prompt *)
      IF    e.ch = CHR(13) THEN gFindMode := FALSE; DoFind; RenderEditor          (* Enter -> search *)
      ELSIF e.ch = CHR(27) THEN gFindMode := FALSE; SetStatus("find cancelled"); RenderEditor   (* Esc *)
      ELSIF e.ch = CHR(8)  THEN flen := SLen(gFindTerm); IF flen > 0 THEN gFindTerm[flen-1] := 0C END; RenderEditor
      ELSIF e.ch >= ' '    THEN flen := SLen(gFindTerm); IF flen < 127 THEN gFindTerm[flen] := e.ch; gFindTerm[flen+1] := 0C END; RenderEditor
      END
    ELSIF gCmdMode THEN                             (* the status line is a ptcl prompt *)
      IF    e.ch = CHR(13) THEN gCmdMode := FALSE; RunCmd                          (* Enter -> evaluate *)
      ELSIF e.ch = CHR(27) THEN gCmdMode := FALSE; SetStatus("cancelled"); RenderEditor   (* Esc *)
      ELSIF e.ch = CHR(8)  THEN flen := SLen(gCmdLine); IF flen > 0 THEN gCmdLine[flen-1] := 0C END; RenderEditor
      ELSIF e.ch >= ' '    THEN flen := SLen(gCmdLine); IF flen < 511 THEN gCmdLine[flen] := e.ch; gCmdLine[flen+1] := 0C END; RenderEditor
      END
    ELSIF gCompMode THEN                            (* the autocomplete popup is open *)
      IF    e.ch = CHR(13) THEN AcceptCompletion                            (* Enter  -> accept *)
      ELSIF e.ch = CHR(9)  THEN AcceptCompletion                            (* Tab    -> accept *)
      ELSIF e.ch = CHR(27) THEN gCompMode := FALSE; SetStatus("ready"); RenderEditor   (* Esc -> cancel *)
      ELSIF e.ch = CHR(8)  THEN gCompMode := FALSE; BeginEdit(2);          (* Backspace -> dismiss *)
            IF HasSel() THEN DeleteSel ELSE Backspace END; RenderEditor
      ELSIF IsIdentCh(e.ch) THEN BeginEdit(1); InsertCh(e.ch); FilterComp; RenderEditor   (* type -> narrow *)
      ELSIF e.ch >= ' '    THEN gCompMode := FALSE; BeginEdit(1);          (* non-ident -> dismiss + insert *)
            IF HasSel() THEN DeleteSel END; InsertCh(e.ch); RenderEditor
      END
    ELSIF gMenuMode THEN                            (* Enter activates, Esc leaves; other typing swallowed *)
      IF e.ch = CHR(13) THEN MenuEnter ELSIF e.ch = CHR(27) THEN LeaveMenu END
    ELSIF e.ch = CHR(16) THEN StartCmd              (* Ctrl+P = ptcl command line *)
    ELSIF e.ch = CHR(6)  THEN StartFind             (* Ctrl+F *)
    ELSIF e.ch = CHR(14) THEN NewTab                (* Ctrl+N *)
    ELSIF e.ch = CHR(15) THEN OpenDialog            (* Ctrl+O *)
    ELSIF e.ch = CHR(23) THEN CloseDoc(gActiveDoc)  (* Ctrl+W = close tab *)
    ELSIF e.ch = CHR(19) THEN Save                  (* Ctrl+S *)
    ELSIF e.ch = CHR(26) THEN DoUndo                (* Ctrl+Z *)
    ELSIF e.ch = CHR(25) THEN DoRedo                (* Ctrl+Y *)
    ELSIF e.ch = CHR(3)  THEN ok := CopySel(); RenderEditor       (* Ctrl+C *)
    ELSIF e.ch = CHR(24) THEN PushUndo; gLastKind := 0; CutSel; RenderEditor          (* Ctrl+X *)
    ELSIF e.ch = CHR(22) THEN PushUndo; gLastKind := 0; PasteClip; RenderEditor        (* Ctrl+V *)
    ELSIF e.ch = CHR(1)  THEN SelectAll; RenderEditor             (* Ctrl+A *)
    ELSIF e.ch = CHR(13) THEN BeginEdit(2); IF HasSel() THEN DeleteSel END; ok := NewLine(); RenderEditor
    ELSIF e.ch = CHR(8)  THEN BeginEdit(2); IF HasSel() THEN DeleteSel ELSE Backspace END; RenderEditor
    ELSIF e.ch = CHR(9)  THEN BeginEdit(1); IF HasSel() THEN DeleteSel END; InsertCh(' '); InsertCh(' '); RenderEditor
    ELSIF e.ch = '.'     THEN BeginEdit(1); IF HasSel() THEN DeleteSel END; InsertCh('.'); TriggerCompletion   (* member access -> autocomplete *)
    ELSIF e.ch >= ' '    THEN BeginEdit(1); IF HasSel() THEN DeleteSel END; InsertCh(e.ch); RenderEditor END
  ELSIF e.kind = EvKey THEN
    IF gAboutMode THEN gAboutMode := FALSE; SetStatus("ready"); RenderEditor    (* any key closes About *)
    ELSIF gFindMode THEN RETURN TRUE                              (* find prompt active: swallow keys (text goes via EvChar) *)
    ELSIF gCmdMode THEN RETURN TRUE                               (* ptcl prompt active: swallow keys (text goes via EvChar) *)
    ELSIF gCompMode THEN                                          (* popup open: arrows navigate, rest swallowed (accept/cancel via EvChar) *)
      IF    e.key = 38 THEN IF gCompSel > 0 THEN DEC(gCompSel) END; RenderEditor          (* Up *)
      ELSIF e.key = 40 THEN IF gCompSel + 1 < gVisN THEN INC(gCompSel) END; RenderEditor  (* Down *)
      END;
      RETURN TRUE
    ELSIF (e.key = 32) AND KeyDown(17) THEN TriggerCompletion     (* Ctrl+Space = autocomplete *)
    ELSIF e.key = 117 THEN TriggerCompletion                      (* F6 = autocomplete (chord-free alternative) *)
    ELSIF gMenuMode THEN MenuKey(e.key)
    ELSIF e.key = 121 THEN EnterMenu                              (* F10 = menu *)
    ELSIF e.key = 120 THEN SaveAllDirty; Build                   (* F9 = save all + build the target *)
    ELSIF e.key = 118 THEN DoAnalyze                              (* F7 = analyze NEW/DISPOSE *)
    ELSIF e.key = 119 THEN DoGuardRun                             (* F8 = run under the heap guard *)
    ELSIF e.key = 116 THEN SaveAllDirty; DoRun                    (* F5 = save all + run the target *)
    ELSIF e.key = 114 THEN FindNext                               (* F3 = find next *)
    ELSIF (e.key = 37) OR (e.key = 39) OR (e.key = 38) OR (e.key = 40)
       OR (e.key = 36) OR (e.key = 35) OR (e.key = 33) OR (e.key = 34) THEN  (* navigation keys only *)
      PreMove;                                                    (* Shift extends, else drops, the selection *)
      IF    e.key = 37 THEN IF curCol > 0 THEN DEC(curCol) ELSIF curRow > 0 THEN DEC(curRow); curCol := CurLen() END   (* Left *)
      ELSIF e.key = 39 THEN IF curCol < CurLen() THEN INC(curCol) ELSIF curRow+1 < nLines THEN INC(curRow); curCol := 0 END  (* Right *)
      ELSIF e.key = 38 THEN IF curRow > 0 THEN DEC(curRow); ClampCol END                (* Up *)
      ELSIF e.key = 40 THEN IF curRow+1 < nLines THEN INC(curRow); ClampCol END         (* Down *)
      ELSIF e.key = 36 THEN curCol := 0                                                 (* Home *)
      ELSIF e.key = 35 THEN curCol := CurLen()                                          (* End *)
      ELSIF e.key = 33 THEN Terminal.Use(edT); rows := Terminal.Rows();                 (* PgUp *)
            IF curRow > rows THEN curRow := curRow - rows ELSE curRow := 0 END; ClampCol
      ELSIF e.key = 34 THEN Terminal.Use(edT); rows := Terminal.Rows();                 (* PgDn *)
            curRow := curRow + rows; IF curRow >= nLines THEN curRow := nLines-1 END; ClampCol
      END;
      gLastKind := 0;                                            (* a cursor move ends the current undo group *)
      RenderEditor
    (* control VKs (Backspace=8, Tab=9, Enter=13, Esc=27) are handled via EvChar — ignored here *)
    END
  END;
  RETURN (e.kind = EvKey) OR (e.kind = EvChar)         (* consumed -> PaneShell swallows the keydown (no DefWindowProc) *)
END OnEvent;

PROCEDURE StartIdleTimer;                              (* 200ms frame timer -> EvTimer (drives check-on-idle) *)
  VAR t: ADRCARD;
BEGIN t := SetTimer(CAST(HWND, FrameOf(win)), 1, 200, NIL) END StartIdleTimer;

(* ---- headless self-drive: if a marker file exists, drive the IDE through the
   reactive event loop (synthetic events = exactly what a user does — events into the
   model, view updates) and snapshot the client area to PNGs at each step, then exit.
   No marker -> normal interactive Run. ---- *)
PROCEDURE MarkerExists (): BOOLEAN;
  VAR h: CARDINAL64; nm: ARRAY [0..511] OF CHAR;
BEGIN
  JoinPath(nm, BaseDir, "fastpanes_drive.txt");        (* relocatable: marker beside the exe *)
  h := NM2File.Open(ADR(nm), NM2File.ReadFlag);
  IF h # 0 THEN NM2File.Close(h); RETURN TRUE END;
  RETURN FALSE
END MarkerExists;

PROCEDURE SelfTest;
  VAR b: BOOLEAN; h: ADDRESS; mb: BOOL;
  PROCEDURE Key (vk: CARDINAL);   BEGIN SendKey(h, vk); RunBounded(ws, 6) END Key;
  PROCEDURE Chr_ (c: CHAR);       BEGIN SendChar(h, c); RunBounded(ws, 6) END Chr_;
  PROCEDURE Str_ (s: ARRAY OF CHAR);
    VAR i: CARDINAL;
  BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO SendChar(h, s[i]); RunBounded(ws, 3); INC(i) END END Str_;
  PROCEDURE OpenProj (name: ARRAY OF CHAR);       (* open a project-folder file in a tab *)
    VAR p: ARRAY [0..511] OF CHAR;
  BEGIN Join(gProjRoot, name, p); OpenInTab(p); RunBounded(ws, 4) END OpenProj;
BEGIN
  RunBounded(ws, 8);                              (* show window + auto-retile + pump *)
  RenderEditor;
  h := HostOf(edPane);                            (* drive the editor host with REAL input (PostMessage) *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap1_initial.png");

  (* compiler inspector: View -> AST *)
  Key(121); Key(39); Key(39); Key(39);             (* F10 -> File, Right x3 -> View *)
  Key(40); Key(40);                                (* open View, Down -> AST *)
  Chr_(CHR(13));                                   (* Enter -> Dump AST into the output pane *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap2_ast.png");
  RunBounded(ws, 60);                              (* drain any queued input before driving more (slow-op race) *)

  (* CHECK-ON-IDLE: type a SEMA error, then just WAIT (no F9) -> the idle timer re-checks *)
  Key(40); Key(40); Key(40); Key(40); Key(40); Key(40);   (* Down x6 -> line 7 (body) *)
  Key(36);                                                 (* Home *)
  Chr_('z'); Chr_('z'); Chr_('z'); Chr_(' '); Chr_(':'); Chr_('=');
  Chr_(' '); Chr_('1'); Chr_(';'); Chr_(' ');             (* "zzz := 1; " -> zzz undeclared *)
  Sleep(450); RunBounded(ws, 20); Sleep(450); RunBounded(ws, 20);   (* idle -> EvTimer -> live check, NO F9 *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap3_errors.png");

  Chr_(CHR(26));                                           (* Ctrl+Z -> the bad edit disappears *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap4_undo.png");

  Chr_(CHR(25));                                           (* Ctrl+Y -> it comes back *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap5_redo.png");

  (* ptcl REPL: Ctrl+P opens the command line; type a script with $/[] substitution *)
  Chr_(CHR(16)); Str_('puts "line [linecount], at [cursor]"');   (* nested [] + "" subst *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap6_ptcl_prompt.png");
  Chr_(CHR(13));                                           (* Enter -> evaluate -> "=> line 11, at 7 11" *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap7_ptcl_result.png");

  Chr_(CHR(16)); Str_("goto 3"); Chr_(CHR(13));            (* a verb that mutates editor state *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap8_ptcl_goto.png");

  (* static analyze via the ptcl `analyze` verb (Ctrl+P) on a buggy program *)
  b := LoadFile("e:\NewModula2\demos\heap_analyze_test.mod"); RenderEditor; RunBounded(ws, 6);
  Chr_(CHR(16)); Str_("analyze"); Chr_(CHR(13)); RunBounded(ws, 10);   (* ptcl verb -> daemon analyze -> warnings + marks *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap9_analyze.png");

  (* run under the heap guard via the ptcl `guard` verb (a program with a real double-free) *)
  b := LoadFile("e:\NewModula2\demos\heap_guard_test.mod"); RenderEditor; RunBounded(ws, 6);
  Chr_(CHR(16)); Str_("guard"); Chr_(CHR(13)); RunBounded(ws, 30);     (* ptcl verb -> run --protect-heap -> guard report *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap10_guard.png");

  (* AUTOCOMPLETE: an interface variable's method call (b. -> Backend methods),
     then narrow by typing, then accept with Enter. The "object method call" case.
     OpenInTab also exercises the document model: cmpl_demo opens as a 2nd tab. *)
  OpenInTab(DemoFile); RunBounded(ws, 6);
  Key(40); Key(40); Key(40); Key(40); Key(40);            (* Down x5 -> line 6 (blank body) *)
  Key(35);                                                 (* End -> after the indent *)
  Str_("b"); Chr_('.');                                   (* 'b.' -> autocomplete popup (Backend methods) *)
  RunBounded(ws, 10);
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap11_complete.png");
  Str_("Pa");                                             (* type -> narrow the list client-side (Paint) *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap12_complete_filtered.png");
  Chr_(CHR(13));                                           (* Enter -> accept the selected candidate *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap13_complete_accepted.png");

  (* AUTOCOMPLETE via Ctrl+Space on the default sample (bare in-scope names) *)
  b := LoadFile(Sample); RenderEditor; RunBounded(ws, 6);
  Key(40); Key(40); Key(40); Key(40); Key(40); Key(40);   (* Down x6 -> body *)
  Key(35); Chr_(CHR(13)); Str_("Write");                  (* blank line, type a partial in-scope name *)
  Key(117); RunBounded(ws, 10);                           (* F6 = autocomplete (reliable single key) *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap15_ctrlspace.png");

  (* FILL-ON-RESIZE: load a file, then enlarge the frame -> WM_SIZE -> auto-retile
     -> TextGrid model reflows to the new pane -> the editor/output panes fill the
     whole (bigger) window instead of leaving a black margin. *)
  b := LoadFile(Sample); RenderEditor; RunBounded(ws, 6);
  mb := MoveWindow(CAST(HWND, FrameOf(win)), 60, 30, 1500, 1000, 1);
  RunBounded(ws, 14);                                   (* pump the WM_SIZE + the EvResize re-render *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap14_resize.png");

  (* SIDEBAR -> TAB: click a file row in the project tree; it opens in a new tab.
     Row ~3 is a real source file (a big one -> exercises the heap doc buffer). *)
  SendClick(CAST(HWND, HostOf(sidPane)), 40, 70); RunBounded(ws, 10);
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap16_sidebar_open.png");

  (* TABS: open enough files to overflow the strip -> close 'x' on each + the '>' arrow *)
  OpenProj("README.md"); OpenProj("RELEASE.md"); OpenProj("make-release.sh");
  OpenProj("snap.sh"); OpenProj("ide_exec.ps1"); OpenProj("pipe_client.ps1");
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap17_tabs_overflow.png");
  SendClick(CAST(HWND, HostOf(edPane)), 163, 28); RunBounded(ws, 8);   (* click the 1st tab's 'x' -> close *)
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap18_tab_closed.png");

  (* PROJECT BUILD (P3): save all + build the active file; the compiler follows its
     imports (sample.mod -> STextIO/SWholeIO) = a multi-module build. *)
  OpenInTab(Sample); RunBounded(ws, 6);
  SaveAllDirty; Build; RunBounded(ws, 25);
  b := SnapClient(FrameOf(win), "e:\NewModula2\projects\FastPanesM2\snap19_build.png")
END SelfTest;

BEGIN
  GetExeDir(BaseDir);                                   (* relocatable: everything lives beside this exe *)
  JoinPath(Compiler, BaseDir, "newm2-driver.exe");
  IF NOT FileExists(Compiler) THEN JoinPath(Compiler, BaseDir, "..\..\target\debug\newm2-driver.exe") END;  (* dev fallback *)
  JoinPath(LibPath,  BaseDir, "library");
  IF NOT DirExists(LibPath)   THEN JoinPath(LibPath,  BaseDir, "..\..\library") END;                        (* dev fallback *)
  JoinPath(WorkFile, BaseDir, "fastpanes_work.mod");
  JoinPath(ExeFile,  BaseDir, "fastpanes_work.exe");
  JoinPath(OutFile,  BaseDir, "fastpanes_out.txt");
  JoinPath(Sample,   BaseDir, "sample.mod");
  JoinPath(DemoFile, BaseDir, "cmpl_demo.mod");
  ws := Init();
  edB  := NewTextGrid(EdCols,   EdRows,   "Consolas", 15.0);
  outB := NewTextGrid(OutCols,  OutRows,  "Consolas", 15.0);
  sidB := NewTextGrid(SideCols, SideRows, "Consolas", 15.0);
  edT  := TermOf(edB);  outT := TermOf(outB);  sidT := TermOf(sidB);
  gNDoc := 0; gActiveDoc := 0; gTabTop := 0; gTabPerPage := 6; gTabRight := FALSE; gTreeN := 0;   (* docs / tabs / tree *)
  di := 0; WHILE di < MaxDocs DO gDocs[di].text := NIL; gDocs[di].used := FALSE; INC(di) END;
  SCopy(gProjRoot, BaseDir);                                (* default project root = this exe's folder *)
  gBuildTarget[0] := 0C;                                    (* no pinned target -> build the active file *)
  outTop := 0; gOut[0] := 0C; gLeft := 0; gFile := "untitled";
  gFollow := TRUE; gFindMode := FALSE; gFindTerm[0] := 0C; gSelActive := FALSE; gAboutMode := FALSE; gMouseSel := FALSE; gNErr := 0;
  gUN := 0; gRN := 0; gLastKind := 0; gDirty := FALSE; gEditTime := 0;
  gCmdMode := FALSE; gCmdLine[0] := 0C; RegisterVerbs;  (* ptcl command line + editor verbs *)
  gCompMode := FALSE; gCompN := 0; gCompSel := 0; gCompTop := 0; gVisN := 0;   (* autocomplete *)

  Terminal.Use(edT);                                   (* menu bar lives on the editor grid (row 0) *)
  Terminal.MenuClear;
  Terminal.MenuAdd("File"); Terminal.MenuAdd("Edit"); Terminal.MenuAdd("Search");
  Terminal.MenuAdd("View"); Terminal.MenuAdd("Build"); Terminal.MenuAdd("Help");
  Terminal.MenuAddItem(0, "New        Ctrl+N"); Terminal.MenuAddItem(0, "Open       Ctrl+O");
  Terminal.MenuAddItem(0, "Save       Ctrl+S"); Terminal.MenuAddItem(0, "Save As...");
  Terminal.MenuAddItem(0, "Exit");
  Terminal.MenuAddItem(1, "Cut        Ctrl+X"); Terminal.MenuAddItem(1, "Copy       Ctrl+C");
  Terminal.MenuAddItem(1, "Paste      Ctrl+V"); Terminal.MenuAddItem(1, "Select All Ctrl+A");
  Terminal.MenuAddItem(2, "Find       Ctrl+F"); Terminal.MenuAddItem(2, "Find Next  F3");
  Terminal.MenuAddItem(3, "Tokens"); Terminal.MenuAddItem(3, "AST"); Terminal.MenuAddItem(3, "Sema");
  Terminal.MenuAddItem(3, "IR"); Terminal.MenuAddItem(3, "LLVM");
  Terminal.MenuAddItem(4, "Build      F9"); Terminal.MenuAddItem(4, "Run        F5");
  Terminal.MenuAddItem(4, "Analyze    F7"); Terminal.MenuAddItem(4, "Run+Guard  F8");
  Terminal.MenuAddItem(4, "Set Target");
  Terminal.MenuAddItem(5, "About");

  NEW(gDocs[0].text);                                (* first document = the sample *)
  IF NOT LoadFile(Sample) THEN NewFile END;
  gNDoc := 1; gActiveDoc := 0; gDocs[0].used := TRUE; SCopy(gDocs[0].path, gFile); gDocs[0].dirty := FALSE;
  gDirty := FALSE; SetStatus("ready");
  InitTree;                                          (* PROJECT + LIBRARY roots in the sidebar *)

  sidPane := LeafPane("sidebar", sidB);
  edPane  := LeafPane("editor", edB);
  outPane := LeafPane("output", outB);
  edOut := Split(Vertical, 0.74, 40, 8, edPane, outPane);          (* editor over output *)
  root  := Split(Horizontal, SideFrac, 16, 60, sidPane, edOut);    (* sidebar | (editor/output) *)
  SetRect(root, 0, 0, 1280, 800);
  win := OpenWindow(ws, "FastPanesM2 - Modula-2 IDE on PaneShell", 1280, 800, root, OnEvent);
  Retile(win);
  StartIdleTimer;                                    (* check-on-idle: re-check after a typing pause *)
  IF NOT Ask(PipeName, "ping", gReply) THEN SpawnDaemon END;   (* always have a warm compiler *)
  gPipeUp := PipeServer.Start(IdePipe);              (* the IDE is remote-drivable: ptcl over \\.\pipe\fastpanes *)
  ShowOutput(gOut); RenderSidebar; RenderEditor;
  IF MarkerExists() THEN SelfTest ELSE Run(ws) END   (* marker -> headless self-drive + PNG snaps; else interactive *)
END FastPanesM2.
