
(* Surface implementation — S5 (PaneShell, P2 part 1/2): the custom-surface
   adapters. The ABSTRACT CLASS Backend (re-declared verbatim — the CLASS-in-DEF
   contract) is the one polymorphic handle the substrate drives; each concrete
   subclass wraps an *instance* of a P1-instanced renderer (Terminal+TermRender,
   RasterView, Canvas2D, GameView, GameViewGpu, ShaderView) and implements
   Attach/Resize/Paint/KindOf/Close by selecting that instance (Use) and calling
   its procs. Construction + KindOf + Close are headless; the real D2D/D3D
   Attach/Paint need a real window (the S7 leaf AOT demo). Native controls are
   the S6 half (still stubs here). *)
IMPLEMENTATION MODULE Surface;

FROM SYSTEM IMPORT ADDRESS, CAST;
IMPORT Terminal, TermRender, RasterView, Canvas2D, GameView, GameViewGpu, ShaderView;
FROM WIN32 IMPORT HWND, HINSTANCE, DWORD, WPARAM, LPARAM, LRESULT, BOOL, PWSTR;
FROM UI_WindowsAndMessaging IMPORT
  CreateWindowExW, SendMessageW, DestroyWindow, SetWindowTextW, GetWindowTextW, MoveWindow,
  WS_CHILD, WS_VISIBLE, WS_BORDER;
FROM System_LibraryLoader IMPORT GetModuleHandleW;

CONST                              (* native-control window styles + messages (S6) *)
  WS_VSCROLL       = 2097152;      (* 0x00200000 *)
  ES_MULTILINE     = 4;
  LBS_NOTIFY       = 1;
  CBS_DROPDOWNLIST = 3;
  LB_ADDSTRING = 384;  LB_GETCURSEL = 392;   (* 0x180 / 0x188 *)
  CB_ADDSTRING = 323;  CB_GETCURSEL = 327;   (* 0x143 / 0x147 *)
  KButton = 1; KEdit = 2; KList = 3; KTree = 4; KCombo = 5;   (* control-kind tags *)

ABSTRACT CLASS Backend;                              (* RE-DECLARED verbatim *)
  ABSTRACT PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  ABSTRACT PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  ABSTRACT PROCEDURE Paint;
  ABSTRACT PROCEDURE KindOf (): Kind;
  ABSTRACT PROCEDURE Close;
END Backend;

(* ---- text grid: a Terminal model + its TermRender (D2D/DWrite) renderer ---- *)
CLASS TextGridBackend;
  INHERIT Backend;
  VAR term: Terminal.Instance; rend: TermRender.Instance; cellW, cellH, lastW, lastH: CARDINAL;
  OVERRIDE PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
    VAR ok: BOOLEAN;
  BEGIN
    Terminal.Use(term); TermRender.Use(rend); TermRender.Bind(term);
    ok := TermRender.Attach(hwnd, pxW, pxH, cellW, cellH);
    IF ok THEN                                          (* record the realized pixel area only on success *)
      lastW := pxW; lastH := pxH;
      IF (cellW > 0) AND (cellH > 0) THEN              (* grow the cell model to fill the pane (reflow, not a fixed grid) *)
        Terminal.Use(term); Terminal.SetSize(pxW DIV cellW, pxH DIV cellH)
      END
    END;
    RETURN ok
  END Attach;
  OVERRIDE PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
    VAR ok: BOOLEAN;
  BEGIN
    TermRender.Use(rend); ok := TermRender.Resize(pxW, pxH);
    IF ok THEN
      lastW := pxW; lastH := pxH;
      IF (cellW > 0) AND (cellH > 0) THEN              (* reflow the cell model to the new pane size *)
        Terminal.Use(term); Terminal.SetSize(pxW DIV cellW, pxH DIV cellH)
      END
    END;
    RETURN ok
  END Resize;
  OVERRIDE PROCEDURE Paint;
  BEGIN TermRender.Use(rend); TermRender.Paint END Paint;
  OVERRIDE PROCEDURE KindOf (): Kind; BEGIN RETURN TextGrid END KindOf;
  OVERRIDE PROCEDURE Close;
  BEGIN TermRender.Free(rend); Terminal.Free(term) END Close;
END TextGridBackend;

(* ---- raster: a CPU RGBA framebuffer (RasterView) ---- *)
CLASS RasterBackend;
  INHERIT Backend;
  VAR rv: RasterView.Instance; host: ADDRESS;
  OVERRIDE PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN host := hwnd; RasterView.Use(rv); RETURN RasterView.Attach(hwnd, pxW, pxH) END Attach;
  OVERRIDE PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN RasterView.Use(rv); RETURN RasterView.Attach(host, pxW, pxH) END Resize;   (* re-bind size *)
  OVERRIDE PROCEDURE Paint;
  BEGIN RasterView.Use(rv); RasterView.Present END Paint;
  OVERRIDE PROCEDURE KindOf (): Kind; BEGIN RETURN Raster END KindOf;
  OVERRIDE PROCEDURE Close; BEGIN RasterView.Free(rv) END Close;
END RasterBackend;

(* ---- canvas: a Direct2D vector/text surface (Canvas2D) ---- *)
CLASS CanvasBackend;
  INHERIT Backend;
  VAR cv: Canvas2D.Instance; host: ADDRESS;
  OVERRIDE PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN host := hwnd; Canvas2D.Use(cv); RETURN Canvas2D.Attach(hwnd, pxW, pxH) END Attach;
  OVERRIDE PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN Canvas2D.Use(cv); RETURN Canvas2D.Attach(host, pxW, pxH) END Resize;   (* re-create target *)
  OVERRIDE PROCEDURE Paint;
  BEGIN (* Canvas2D is immediate-mode: the app brackets Begin/draw/Flush itself *) END Paint;
  OVERRIDE PROCEDURE KindOf (): Kind; BEGIN RETURN Canvas END KindOf;
  OVERRIDE PROCEDURE Close; BEGIN Canvas2D.Use(cv); Canvas2D.Free(cv) END Close;
END CanvasBackend;

(* ---- indexed (CPU): a palette+sprite surface (GameView) ---- *)
CLASS IndexedBackend;
  INHERIT Backend;
  VAR gv: GameView.Instance; iw, ih, scale: CARDINAL; host: ADDRESS;
  OVERRIDE PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN host := hwnd; GameView.Use(gv); RETURN GameView.Attach(hwnd, iw, ih, scale) END Attach;
  OVERRIDE PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN GameView.Use(gv); RETURN GameView.Attach(host, iw, ih, scale) END Resize;
  OVERRIDE PROCEDURE Paint;
  BEGIN GameView.Use(gv); GameView.Present END Paint;
  OVERRIDE PROCEDURE KindOf (): Kind; BEGIN RETURN Indexed END KindOf;
  OVERRIDE PROCEDURE Close; BEGIN GameView.Free(gv) END Close;
END IndexedBackend;

(* ---- indexed (GPU): the GameViewGpu surface (owns a ShaderView) ---- *)
CLASS IndexedGpuBackend;
  INHERIT Backend;
  VAR gp: GameViewGpu.Instance; iw, ih: CARDINAL; host: ADDRESS;
  OVERRIDE PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN
    host := hwnd; GameViewGpu.Use(gp);
    RETURN GameViewGpu.Attach(hwnd, iw, ih, iw, ih, pxW, pxH)   (* world = view = (iw,ih), surf = (pxW,pxH) *)
  END Attach;
  OVERRIDE PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN RETURN TRUE END Resize;                      (* GPU swapchain resize: S7+ *)
  OVERRIDE PROCEDURE Paint;
  BEGIN GameViewGpu.Use(gp); GameViewGpu.Present END Paint;
  OVERRIDE PROCEDURE KindOf (): Kind; BEGIN RETURN Indexed END KindOf;
  OVERRIDE PROCEDURE Close; BEGIN GameViewGpu.Free(gp) END Close;
END IndexedGpuBackend;

(* ---- shader: a full-screen pixel-shader host (ShaderView) ---- *)
CLASS ShaderBackend;
  INHERIT Backend;
  VAR sv: ShaderView.Instance;
  OVERRIDE PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN ShaderView.Use(sv); RETURN ShaderView.Attach(hwnd, pxW, pxH) END Attach;
  OVERRIDE PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  BEGIN ShaderView.Use(sv); ShaderView.Resize(pxW, pxH); RETURN TRUE END Resize;
  OVERRIDE PROCEDURE Paint;
  BEGIN (* ShaderView is driven via SetShader + Frame(constants); generic Paint is a no-op *) END Paint;
  OVERRIDE PROCEDURE KindOf (): Kind; BEGIN RETURN Shader END KindOf;
  OVERRIDE PROCEDURE Close; BEGIN ShaderView.Use(sv); ShaderView.Free(sv) END Close;
END ShaderBackend;

(* ---- native controls: the simplest leaf (§6). One class spans all five (a
   `kind` tag selects the Win32 class + value-message ids); Attach creates the
   control as a child HWND, Resize = MoveWindow, Paint is a NO-OP (the OS draws
   it). A control HWND is message-window-safe (unlike a D2D HwndRenderTarget),
   so this whole path is headless-testable. ---- *)
CLASS ControlBackend;
  INHERIT Backend;
  VAR cwin: HWND; kind, style: CARDINAL;
      cls:     ARRAY [0..15] OF CHAR;        (* the Win32 (wide) class name *)
      pending: ARRAY [0..255] OF CHAR;       (* text set before Attach (the window name) *)
  OVERRIDE PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
    VAR hInst: HINSTANCE;
  BEGIN
    hInst := GetModuleHandleW(NIL);
    cwin := CreateWindowExW(0, ADR(cls), ADR(pending), VAL(DWORD, style),
                            0, 0, VAL(INTEGER32, pxW), VAL(INTEGER32, pxH),
                            CAST(HWND, hwnd), NIL, hInst, NIL);
    RETURN cwin # NIL
  END Attach;
  OVERRIDE PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
    VAR ok: BOOL;
  BEGIN
    IF cwin = NIL THEN RETURN FALSE END;
    ok := MoveWindow(cwin, 0, 0, VAL(INTEGER32, pxW), VAL(INTEGER32, pxH), VAL(BOOL, 1));
    RETURN TRUE
  END Resize;
  OVERRIDE PROCEDURE Paint; BEGIN END Paint;          (* the OS paints the control *)
  OVERRIDE PROCEDURE KindOf (): Kind; BEGIN RETURN NativeControl END KindOf;
  OVERRIDE PROCEDURE Close;
    VAR ok: BOOL;
  BEGIN IF cwin # NIL THEN ok := DestroyWindow(cwin); cwin := NIL END END Close;
END ControlBackend;

(* copy an open-array string into a fixed buffer, NUL-terminated *)
PROCEDURE CopyStr (src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(src)) AND (i < HIGH(dst)) AND (src[i] # 0C) DO dst[i] := src[i]; INC(i) END;
  dst[i] := 0C
END CopyStr;

(* ---- custom-surface constructors (wrap an instance of a P1 renderer) ---- *)
PROCEDURE NewTextGrid (cols, rows: CARDINAL; font: ARRAY OF CHAR; pt: REAL): Backend;
  VAR b: TextGridBackend;
BEGIN
  NEW(b);
  b.term := Terminal.Create(cols, rows);
  b.rend := TermRender.Create(font, VAL(SHORTREAL, pt));
  b.cellW := VAL(CARDINAL, TRUNC(pt * 0.62)); IF b.cellW < 1 THEN b.cellW := 1 END;
  b.cellH := VAL(CARDINAL, TRUNC(pt * 1.35)); IF b.cellH < 1 THEN b.cellH := 1 END;
  b.lastW := 0; b.lastH := 0;                          (* 0 until Attach/Resize -> VisibleCells reports 0,0 *)
  RETURN b
END NewTextGrid;

(* expose the Terminal.Instance behind a TextGrid leaf so the app can render into it
   (Terminal.Use it, write cells, then b.Paint). NIL if b is not a TextGrid. *)
PROCEDURE TermOf (b: Backend): ADDRESS;
  VAR tg: TextGridBackend;
BEGIN
  IF (b # NIL) AND (b.KindOf() = TextGrid) THEN tg := CAST(TextGridBackend, b); RETURN tg.term END;
  RETURN NIL
END TermOf;

(* how many whole cells fit the TextGrid's current pixel area (after Attach/Resize).
   0,0 if not a TextGrid or not yet sized — caller should fall back to the model size. *)
PROCEDURE VisibleCells (b: Backend; VAR cols, rows: CARDINAL);
  VAR tg: TextGridBackend;
BEGIN
  cols := 0; rows := 0;
  IF (b # NIL) AND (b.KindOf() = TextGrid) THEN
    tg := CAST(TextGridBackend, b);
    IF (tg.cellW > 0) AND (tg.cellH > 0) THEN cols := tg.lastW DIV tg.cellW; rows := tg.lastH DIV tg.cellH END
  END
END VisibleCells;

(* the TextGrid leaf's cell size in pixels (0,0 if not a TextGrid) — for mouse hit-testing *)
PROCEDURE CellSize (b: Backend; VAR w, h: CARDINAL);
  VAR tg: TextGridBackend;
BEGIN
  w := 0; h := 0;
  IF (b # NIL) AND (b.KindOf() = TextGrid) THEN tg := CAST(TextGridBackend, b); w := tg.cellW; h := tg.cellH END
END CellSize;

PROCEDURE NewRaster (w, h: CARDINAL): Backend;
  VAR b: RasterBackend;
BEGIN
  NEW(b); b.rv := RasterView.Create(w, h); b.host := NIL;
  RETURN b
END NewRaster;

PROCEDURE NewCanvas (): Backend;
  VAR b: CanvasBackend;
BEGIN
  NEW(b); b.cv := Canvas2D.Create(); b.host := NIL;
  RETURN b
END NewCanvas;

PROCEDURE NewIndexed (w, h, scale: CARDINAL): Backend;
  VAR b: IndexedBackend;
BEGIN
  NEW(b); b.gv := GameView.Create(w, h, scale);
  b.iw := w; b.ih := h; b.scale := scale; b.host := NIL;
  RETURN b
END NewIndexed;

PROCEDURE NewIndexedGpu (w, h, scale: CARDINAL): Backend;
  VAR b: IndexedGpuBackend;
BEGIN
  NEW(b); b.gp := GameViewGpu.Create();
  b.iw := w; b.ih := h; b.host := NIL;
  RETURN b
END NewIndexedGpu;

PROCEDURE NewShader (w, h: CARDINAL): Backend;
  VAR b: ShaderBackend;
BEGIN
  NEW(b); b.sv := ShaderView.Create();
  RETURN b
END NewShader;

(* ---- native-control adapters (S6): each NEWs a ControlBackend with its Win32
   class + style; the OS-drawn control is created at Attach. `Kind.Custom` needs
   no constructor here — an app subclasses Backend directly (the §6 extension
   seam). ---- *)
PROCEDURE NewButton (label: ARRAY OF CHAR; event: ARRAY OF CHAR): Backend;
  VAR b: ControlBackend;
BEGIN
  NEW(b); b.cwin := NIL; b.kind := KButton; b.cls := "BUTTON";
  b.style := WS_CHILD BOR WS_VISIBLE;                 (* BS_PUSHBUTTON = 0 *)
  CopyStr(label, b.pending);
  RETURN b
END NewButton;

PROCEDURE NewEdit (multiline: BOOLEAN): Backend;
  VAR b: ControlBackend;
BEGIN
  NEW(b); b.cwin := NIL; b.kind := KEdit; b.cls := "EDIT"; b.pending[0] := 0C;
  IF multiline THEN b.style := WS_CHILD BOR WS_VISIBLE BOR WS_BORDER BOR ES_MULTILINE BOR WS_VSCROLL
  ELSE b.style := WS_CHILD BOR WS_VISIBLE BOR WS_BORDER END;
  RETURN b
END NewEdit;

PROCEDURE NewList (): Backend;
  VAR b: ControlBackend;
BEGIN
  NEW(b); b.cwin := NIL; b.kind := KList; b.cls := "LISTBOX"; b.pending[0] := 0C;
  b.style := WS_CHILD BOR WS_VISIBLE BOR WS_BORDER BOR LBS_NOTIFY;
  RETURN b
END NewList;

PROCEDURE NewTree (): Backend;
  VAR b: ControlBackend;
BEGIN
  NEW(b); b.cwin := NIL; b.kind := KTree; b.cls := "SysTreeView32"; b.pending[0] := 0C;
  b.style := WS_CHILD BOR WS_VISIBLE BOR WS_BORDER;   (* needs common-controls init to create *)
  RETURN b
END NewTree;

PROCEDURE NewCombo (): Backend;
  VAR b: ControlBackend;
BEGIN
  NEW(b); b.cwin := NIL; b.kind := KCombo; b.cls := "COMBOBOX"; b.pending[0] := 0C;
  b.style := WS_CHILD BOR WS_VISIBLE BOR CBS_DROPDOWNLIST;
  RETURN b
END NewCombo;

(* ---- generic value access over a control Backend (Q17.5: generic). Guarded by
   KindOf = NativeControl, then a CAST downcast to the concrete ControlBackend. ---- *)
PROCEDURE AsControl (b: Backend): ControlBackend;     (* the ControlBackend, or NIL *)
BEGIN
  IF (b # NIL) AND (b.KindOf() = NativeControl) THEN RETURN CAST(ControlBackend, b) END;
  RETURN NIL
END AsControl;

PROCEDURE SetText (b: Backend; s: ARRAY OF CHAR);
  VAR c: ControlBackend; ok: BOOL;
BEGIN
  c := AsControl(b);
  IF c # NIL THEN
    CopyStr(s, c.pending);
    IF c.cwin # NIL THEN ok := SetWindowTextW(c.cwin, ADR(c.pending)) END
  END
END SetText;

PROCEDURE GetText (b: Backend; VAR s: ARRAY OF CHAR);
  VAR c: ControlBackend; n: INTEGER32;
BEGIN
  s[0] := 0C;
  c := AsControl(b);
  IF c # NIL THEN
    IF c.cwin # NIL THEN n := GetWindowTextW(c.cwin, ADR(s), VAL(INTEGER32, HIGH(s)+1))
    ELSE CopyStr(c.pending, s) END
  END
END GetText;

PROCEDURE AddRow (b: Backend; s: ARRAY OF CHAR);
  VAR c: ControlBackend; buf: ARRAY [0..255] OF CHAR; r: LRESULT;
BEGIN
  c := AsControl(b);
  IF (c # NIL) AND (c.cwin # NIL) THEN
    CopyStr(s, buf);
    IF c.kind = KList THEN
      r := SendMessageW(c.cwin, VAL(DWORD, LB_ADDSTRING), CAST(WPARAM, 0), CAST(LPARAM, ADR(buf)))
    ELSIF c.kind = KCombo THEN
      r := SendMessageW(c.cwin, VAL(DWORD, CB_ADDSTRING), CAST(WPARAM, 0), CAST(LPARAM, ADR(buf)))
    END
  END
END AddRow;

PROCEDURE Selected (b: Backend): CARDINAL;
  VAR c: ControlBackend; r: LRESULT;
BEGIN
  c := AsControl(b);
  IF (c # NIL) AND (c.cwin # NIL) THEN
    IF c.kind = KList THEN
      r := SendMessageW(c.cwin, VAL(DWORD, LB_GETCURSEL), CAST(WPARAM, 0), CAST(LPARAM, 0));
      RETURN CAST(CARDINAL, r)
    ELSIF c.kind = KCombo THEN
      r := SendMessageW(c.cwin, VAL(DWORD, CB_GETCURSEL), CAST(WPARAM, 0), CAST(LPARAM, 0));
      RETURN CAST(CARDINAL, r)
    END
  END;
  RETURN 0
END Selected;

END Surface.
