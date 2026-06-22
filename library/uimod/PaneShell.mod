(* PaneShell implementation — S7 (P3, the shared substrate).

   Slice 1 (this cut): the universal Pane as a heap tree node + the named-pane
   registry (PaneByName/BackendOf/RectOf) + tree building (Arrange/AddChild/
   SetRect) + the DumpTree introspection probe. All fully headless — no host
   HWNDs, no window, no solver yet. A Pane is the currency: a LEAF (wraps a
   Surface.Backend) or an ARRANGEMENT (holds child Panes). The HWND tree (host
   windows mirroring the Pane tree), the event router, the per-pane channel and
   the Layout ABSTRACT CLASS land in the next slices; their procedures are stubs
   below. *)
IMPLEMENTATION MODULE PaneShell;

FROM SYSTEM IMPORT ADDRESS, ADR, CAST, SIZE;
FROM Storage IMPORT ALLOCATE, DEALLOCATE;
IMPORT Surface;
FROM WIN32 IMPORT HWND, HINSTANCE, DWORD, WPARAM, LPARAM, LRESULT, BOOL, WORD, PWSTR, HDC, HBRUSH;
FROM UI_WindowsAndMessaging IMPORT
  WNDCLASSEXW, MSG, RegisterClassExW, CreateWindowExW, DefWindowProcW, DestroyWindow,
  LoadCursorW, GetParent, SetWindowLongPtrW, GetWindowLongPtrW, MoveWindow, ShowWindow,
  GetMessageW, PeekMessageW, TranslateMessage, DispatchMessageW, PostQuitMessage, GetClientRect,
  WS_OVERLAPPEDWINDOW, WS_CHILD, CW_USEDEFAULT, GWLP_USERDATA, SW_SHOW, PM_REMOVE, WM_QUIT;
FROM UI_Input_KeyboardAndMouse IMPORT SetCapture, ReleaseCapture;
FROM Graphics_Gdi IMPORT ValidateRect, GetSysColorBrush, InvalidateRect,
  GetDC, ReleaseDC, FillRect, CreateSolidBrush;
FROM Foundation IMPORT RECT, COLORREF;
FROM System_LibraryLoader IMPORT GetModuleHandleW;
FROM MemUtils IMPORT ZeroMem;
IMPORT Threads;

(* The pluggable arrangement algorithm (D7) — RE-DECLARED verbatim from the def
   (the CLASS-in-DEF contract). References Pane + DropZone from the definition. *)
ABSTRACT CLASS Layout;
  ABSTRACT PROCEDURE Arrange (host: Pane; x, y, w, h: CARDINAL);
  ABSTRACT PROCEDURE HitTest (host: Pane; px, py: INTEGER): CARDINAL;
  ABSTRACT PROCEDURE Drag    (host: Pane; handle: CARDINAL; dx, dy: INTEGER);
  ABSTRACT PROCEDURE DropAt  (host: Pane; px, py: INTEGER; moved: Pane;
                              VAR zone: DropZone; VAR x, y, w, h: CARDINAL): BOOLEAN;
  ABSTRACT PROCEDURE Save    (host: Pane; VAR blob: ARRAY OF CHAR): BOOLEAN;
  ABSTRACT PROCEDURE Load    (host: Pane; blob: ARRAY OF CHAR): BOOLEAN;
END Layout;

CONST
  MaxId       = 63;
  MaxChildren = 32;
  ChanCap     = 16;                             (* per-pane channel ring capacity *)
  WS_CLIPCHILDREN = 33554432;                   (* 0x02000000 *)
  WS_VISIBLE      = 268435456;                   (* 0x10000000 *)
  MaxWindows      = 16;                           (* per-workspace top-level windows *)
  (* Win32 messages the event router translates into semantic Events *)
  WM_SIZE = 5; WM_SETFOCUS = 7; WM_CLOSE = 16; WM_PAINT = 15;
  WM_KEYDOWN = 256; WM_KEYUP = 257; WM_CHAR = 258; WM_COMMAND = 273;
  WM_SYSKEYDOWN = 260; WM_SYSKEYUP = 261;        (* F10 / Alt+key — so apps can drive a menu bar *)
  WM_TIMER = 275;                                (* frame timer -> EvTimer (idle ticks, e.g. check-on-pause) *)
  WM_MOUSEMOVE = 512; WM_LBUTTONDOWN = 513; WM_LBUTTONUP = 514;
  WM_MOUSEWHEEL = 522;                            (* 0x020A — vertical wheel; HIWORD(wParam) = signed delta *)
  WM_CAPTURECHANGED = 533;                       (* 0x0215 — capture stolen: abort an in-flight drag *)

TYPE
  PaneKind = (PkLeaf, PkArrange);
  PanePtr  = POINTER TO PaneRec;
  PWinPtr  = POINTER TO PWinRec;                 (* forward — PWinRec declared below *)
  WsPtr    = POINTER TO WsRec;                   (* forward — WsRec declared below *)
  PaneRec  = RECORD
    id:     ARRAY [0..MaxId] OF CHAR;
    kind:   PaneKind;
    back:   Surface.Backend;                   (* leaf only; NIL otherwise *)
    host:   ADDRESS;                           (* host HWND (WS_CHILD|WS_CLIPCHILDREN); NIL until OpenWindow *)
    x, y, w, h: CARDINAL;                       (* rect (the solver's output) *)
    parent: PanePtr;
    nChild: CARDINAL;
    child:  ARRAY [0..MaxChildren-1] OF PanePtr;
    win:    PWinPtr;                            (* the owning PaneWindow (the router's path to the handler) *)
    layout: Layout;                            (* arrangement algorithm (D7); NIL for leaves/plain nodes *)
    chan:   ARRAY [0..ChanCap-1] OF ADDRESS;   (* per-pane channel: frame buffers / state deltas (§7) *)
    chHead, chCount: CARDINAL;
    chLock: Threads.Lock;                      (* CRITICAL_SECTION — lock-based, not lock-free (amendment C) *)
    threaded: BOOLEAN;                         (* SetThreaded dark seam (D2); inline-drained until P8 *)
    hidden:   BOOLEAN;                         (* SetHidden — the parent Layout skips it (D1) *)
    divHover: BOOLEAN;                          (* mouse is over this split's divider -> draw it glowing *)
  END;

  PWinRec = RECORD                              (* a top-level pane window *)
    frame: ADDRESS;                             (* the top-level frame HWND *)
    root:  PanePtr;
    on:    Handler;                             (* the app's event handler (control plane, §7) *)
    ws:    WsPtr;                                (* owning workspace (NIL if none) — for CloseWindow unregister *)
    closing: BOOLEAN;                           (* re-entrancy guard: a re-entrant CloseWindow is a no-op *)
    (* --- S10 splitter-drag session: per-window HEAP, never a module global
       (the window class is process-wide; one WNDPROC serves every JIT instance's
       windows under the parallel harness — mutable drag state must hang off the
       HWND-recovered PWinRec, the same path the router uses for `on`). --- *)
    dragActive: BOOLEAN;
    dragHost:   PanePtr;                        (* the arrangement Pane whose Layout owns the handle *)
    dragLayout: Layout;
    dragHandle: CARDINAL;
    anchorX, anchorY: INTEGER;                  (* last point, pane-frame absolute coords *)
  END;

  WsRec = RECORD                                (* the workspace: its top-level windows + a quit latch *)
    nWindows: CARDINAL;
    quit:     BOOLEAN;                          (* Quit() sets it; Run/RunBounded check it each iteration *)
    wins:     ARRAY [0..MaxWindows-1] OF PWinPtr;
  END;

VAR
  gClassReg:  BOOLEAN;                          (* the host window class is registered once *)
  gClassName: ARRAY [0..31] OF CHAR;
  (* polled-input snapshot — the fast sensor lane (§10.2); zero-init *)
  gKeyState:  ARRAY [0..255] OF BOOLEAN;
  gMouseX, gMouseY: INTEGER;
  gMouseBtn:  CARDINAL;
  gHoverPane: PanePtr;                          (* the split whose divider the mouse is over (NIL = none) *)
  gDivBrush:  HBRUSH;                           (* cached divider brushes (created lazily) *)
  gGlowBrush: HBRUSH;

(* ---- node allocation ---- *)
PROCEDURE NewNode (id: ARRAY OF CHAR; k: PaneKind): PanePtr;
  VAR a: ADDRESS; p: PanePtr; i: CARDINAL;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(PaneRec)); p := CAST(PanePtr, a);
  i := 0;
  WHILE (i <= HIGH(id)) AND (i < MaxId) AND (id[i] # 0C) DO p^.id[i] := id[i]; INC(i) END;
  p^.id[i] := 0C;
  p^.kind := k; p^.back := NIL; p^.host := NIL;
  p^.x := 0; p^.y := 0; p^.w := 0; p^.h := 0;
  p^.parent := NIL; p^.nChild := 0; p^.win := NIL;
  p^.layout := NIL; p^.chHead := 0; p^.chCount := 0; p^.threaded := FALSE; p^.hidden := FALSE;
  p^.divHover := FALSE;
  Threads.InitLock(p^.chLock);
  RETURN p
END NewNode;

PROCEDURE LeafPane (id: ARRAY OF CHAR; back: Surface.Backend): Pane;
  VAR p: PanePtr;
BEGIN
  p := NewNode(id, PkLeaf); p^.back := back;
  RETURN CAST(Pane, p)
END LeafPane;

PROCEDURE Arrange (id: ARRAY OF CHAR): Pane;
BEGIN
  RETURN CAST(Pane, NewNode(id, PkArrange))
END Arrange;

PROCEDURE AddChild (parent, child: Pane);
  VAR p, c: PanePtr;
BEGIN
  IF (parent = NIL) OR (child = NIL) THEN RETURN END;
  p := CAST(PanePtr, parent); c := CAST(PanePtr, child);
  IF p^.nChild < MaxChildren THEN
    p^.child[p^.nChild] := c; INC(p^.nChild); c^.parent := p
  END
END AddChild;

PROCEDURE SetRect (p: Pane; x, y, w, h: CARDINAL);
  VAR n: PanePtr;
BEGIN
  IF p = NIL THEN RETURN END;
  n := CAST(PanePtr, p); n^.x := x; n^.y := y; n^.w := w; n^.h := h
END SetRect;

PROCEDURE RectOf (p: Pane; VAR x, y, w, h: CARDINAL);
  VAR n: PanePtr;
BEGIN
  IF p = NIL THEN x := 0; y := 0; w := 0; h := 0; RETURN END;
  n := CAST(PanePtr, p); x := n^.x; y := n^.y; w := n^.w; h := n^.h
END RectOf;

PROCEDURE BackendOf (p: Pane): Surface.Backend;
  VAR n: PanePtr;
BEGIN
  IF p = NIL THEN RETURN NIL END;
  n := CAST(PanePtr, p);
  IF n^.kind = PkLeaf THEN RETURN n^.back END;
  RETURN NIL
END BackendOf;

(* ---- named-pane registry: DFS the live tree by id ---- *)
PROCEDURE IdEq (n: PanePtr; id: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL; ca, cb: CHAR;
BEGIN
  i := 0;
  LOOP
    IF i <= MaxId THEN ca := n^.id[i] ELSE ca := 0C END;
    IF i <= HIGH(id) THEN cb := id[i] ELSE cb := 0C END;
    IF ca # cb THEN RETURN FALSE END;
    IF ca = 0C THEN RETURN TRUE END;
    INC(i)
  END
END IdEq;

PROCEDURE FindIn (n: PanePtr; id: ARRAY OF CHAR): PanePtr;
  VAR i: CARDINAL; r: PanePtr;
BEGIN
  IF n = NIL THEN RETURN NIL END;
  IF IdEq(n, id) THEN RETURN n END;
  i := 0;
  WHILE i < n^.nChild DO
    r := FindIn(n^.child[i], id);
    IF r # NIL THEN RETURN r END;
    INC(i)
  END;
  RETURN NIL
END FindIn;

PROCEDURE PaneByName (root: Pane; id: ARRAY OF CHAR): Pane;
BEGIN
  IF root = NIL THEN RETURN NIL END;
  RETURN CAST(Pane, FindIn(CAST(PanePtr, root), id))
END PaneByName;

(* ---- DumpTree introspection probe: id:kind(x,y,w,h)[children] ---- *)
PROCEDURE AppStr (VAR s: ARRAY OF CHAR; VAR pos: CARDINAL; t: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(t)) AND (t[i] # 0C) AND (pos < HIGH(s)) DO s[pos] := t[i]; INC(pos); INC(i) END;
  s[pos] := 0C
END AppStr;

PROCEDURE AppId (VAR s: ARRAY OF CHAR; VAR pos: CARDINAL; n: PanePtr);
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= MaxId) AND (n^.id[i] # 0C) AND (pos < HIGH(s)) DO s[pos] := n^.id[i]; INC(pos); INC(i) END;
  s[pos] := 0C
END AppId;

PROCEDURE AppCard (VAR s: ARRAY OF CHAR; VAR pos: CARDINAL; v: CARDINAL);
  VAR d: ARRAY [0..15] OF CHAR; k: CARDINAL;
BEGIN
  IF v = 0 THEN AppStr(s, pos, "0"); RETURN END;
  k := 0;
  WHILE v > 0 DO d[k] := CHR(ORD('0') + (v MOD 10)); INC(k); v := v DIV 10 END;
  WHILE k > 0 DO DEC(k); IF pos < HIGH(s) THEN s[pos] := d[k]; INC(pos) END END;
  s[pos] := 0C
END AppCard;

PROCEDURE DumpNode (VAR s: ARRAY OF CHAR; VAR pos: CARDINAL; n: PanePtr);
  VAR i: CARDINAL;
BEGIN
  IF n = NIL THEN RETURN END;
  AppId(s, pos, n);
  IF n^.kind = PkLeaf THEN AppStr(s, pos, ":L(") ELSE AppStr(s, pos, ":A(") END;
  AppCard(s, pos, n^.x); AppStr(s, pos, ",");
  AppCard(s, pos, n^.y); AppStr(s, pos, ",");
  AppCard(s, pos, n^.w); AppStr(s, pos, ",");
  AppCard(s, pos, n^.h); AppStr(s, pos, ")");
  IF n^.nChild > 0 THEN
    AppStr(s, pos, "[");
    i := 0;
    WHILE i < n^.nChild DO
      IF i > 0 THEN AppStr(s, pos, " ") END;
      DumpNode(s, pos, n^.child[i]);
      INC(i)
    END;
    AppStr(s, pos, "]")
  END
END DumpNode;

PROCEDURE DumpTree (root: Pane; VAR s: ARRAY OF CHAR);
  VAR pos: CARDINAL;
BEGIN
  pos := 0; s[0] := 0C;
  IF root # NIL THEN DumpNode(s, pos, CAST(PanePtr, root)) END
END DumpTree;

(* ---- arrangement children + pluggable Layout (D7) ---- *)
PROCEDURE ChildCount (p: Pane): CARDINAL;
  VAR n: PanePtr;
BEGIN IF p = NIL THEN RETURN 0 END; n := CAST(PanePtr, p); RETURN n^.nChild END ChildCount;

PROCEDURE Child (p: Pane; i: CARDINAL): Pane;
  VAR n: PanePtr;
BEGIN
  IF p = NIL THEN RETURN NIL END;
  n := CAST(PanePtr, p);
  IF i < n^.nChild THEN RETURN CAST(Pane, n^.child[i]) END;
  RETURN NIL
END Child;

PROCEDURE SetLayout (p: Pane; lay: Layout);
  VAR n: PanePtr;
BEGIN IF p # NIL THEN n := CAST(PanePtr, p); n^.layout := lay END END SetLayout;

PROCEDURE LayoutOf (p: Pane): Layout;
  VAR n: PanePtr;
BEGIN IF p = NIL THEN RETURN NIL END; n := CAST(PanePtr, p); RETURN n^.layout END LayoutOf;

PROCEDURE SetHidden (p: Pane; hidden: BOOLEAN);
  VAR n: PanePtr;
BEGIN IF p # NIL THEN n := CAST(PanePtr, p); n^.hidden := hidden END END SetHidden;

PROCEDURE IsHidden (p: Pane): BOOLEAN;
  VAR n: PanePtr;
BEGIN IF p = NIL THEN RETURN FALSE END; n := CAST(PanePtr, p); RETURN n^.hidden END IsHidden;

PROCEDURE ReplaceChild (old, new: Pane);
  VAR o, n, par: PanePtr; i: CARDINAL;
BEGIN
  IF (old = NIL) OR (new = NIL) THEN RETURN END;
  o := CAST(PanePtr, old); n := CAST(PanePtr, new);
  par := o^.parent;
  IF par = NIL THEN RETURN END;
  i := 0;
  WHILE i < par^.nChild DO
    IF par^.child[i] = o THEN
      par^.child[i] := n; n^.parent := par; o^.parent := NIL; RETURN
    END;
    INC(i)
  END
END ReplaceChild;

(* ---- per-pane channel (§7): a lock-guarded FIFO ring, drained inline (D2).
   The Threads.Lock (CRITICAL_SECTION) makes it thread-safe the moment a producer
   thread attaches at P8 — same API, no change (amendment C: lock-based, not
   lock-free). Uncontended on the single UI thread today. ---- *)
PROCEDURE Submit (p: Pane; buf: ADDRESS): BOOLEAN;
  VAR n: PanePtr; ok: BOOLEAN;
BEGIN
  IF p = NIL THEN RETURN FALSE END;
  n := CAST(PanePtr, p);
  Threads.Acquire(n^.chLock);
  IF n^.chCount < ChanCap THEN
    n^.chan[(n^.chHead + n^.chCount) MOD ChanCap] := buf; INC(n^.chCount); ok := TRUE
  ELSE ok := FALSE END;
  Threads.Release(n^.chLock);
  RETURN ok
END Submit;

PROCEDURE ChannelDepth (p: Pane): CARDINAL;
  VAR n: PanePtr; d: CARDINAL;
BEGIN
  IF p = NIL THEN RETURN 0 END;
  n := CAST(PanePtr, p);
  Threads.Acquire(n^.chLock); d := n^.chCount; Threads.Release(n^.chLock);
  RETURN d
END ChannelDepth;

PROCEDURE ChannelNext (p: Pane; VAR buf: ADDRESS): BOOLEAN;
  VAR n: PanePtr; ok: BOOLEAN;
BEGIN
  buf := NIL;
  IF p = NIL THEN RETURN FALSE END;
  n := CAST(PanePtr, p);
  Threads.Acquire(n^.chLock);
  IF n^.chCount > 0 THEN
    buf := n^.chan[n^.chHead]; n^.chHead := (n^.chHead + 1) MOD ChanCap; DEC(n^.chCount); ok := TRUE
  ELSE ok := FALSE END;
  Threads.Release(n^.chLock);
  RETURN ok
END ChannelNext;

(* ======================================================================== *)
(* Slice 2: the host-HWND tree. Each Pane owns a WS_CHILD|WS_CLIPCHILDREN host *)
(* window so the OS handle tree is a projection of the Pane tree (§4/§5); a   *)
(* leaf's Backend attaches to its host. The event router, per-pane channel    *)
(* and Layout class are the next slices — their procs are still stubs.         *)
(* ======================================================================== *)

(* Re-solve a window's tree: top-down, each pane's host is moved to its rect and,
   if it carries a Layout (D7), that strategy assigns its children's rects. A pane
   with NO Layout is left untouched (the non-Layout guard) — its children keep
   their rects. The substrate never knows the algorithm. Host windows are placed
   RELATIVE to their parent host's client (subtract the parent's pane-frame origin)
   so the on-screen HWND tree matches nested layouts and the drag parent-walk
   (child-client + child.x = pane-frame absolute) is exact at any depth. *)
PROCEDURE RetileNode (n: PanePtr);
  VAR i, rx, ry: CARDINAL; ok: BOOL; rz: BOOLEAN; lay: Layout;
BEGIN
  IF n = NIL THEN RETURN END;
  rx := n^.x; ry := n^.y;
  IF n^.parent # NIL THEN rx := n^.x - n^.parent^.x; ry := n^.y - n^.parent^.y END;
  IF n^.host # NIL THEN
    ok := MoveWindow(CAST(HWND, n^.host), VAL(INTEGER32, rx), VAL(INTEGER32, ry),
                     VAL(INTEGER32, n^.w), VAL(INTEGER32, n^.h), VAL(BOOL, 0))
  END;
  IF (n^.kind = PkLeaf) AND (n^.back # NIL) AND (n^.w > 0) AND (n^.h > 0) THEN
    rz := n^.back.Resize(n^.w, n^.h)                 (* a leaf's content tracks its host (skip hidden 0x0) *)
  END;
  IF n^.layout # NIL THEN                            (* guard: no Layout -> children untouched *)
    lay := n^.layout; lay.Arrange(CAST(Pane, n), n^.x, n^.y, n^.w, n^.h)
  END;
  i := 0;
  WHILE i < n^.nChild DO RetileNode(n^.child[i]); INC(i) END
END RetileNode;

PROCEDURE Retile (win: PaneWindow);
  VAR pw: PWinPtr;
BEGIN
  IF win = NIL THEN RETURN END;
  pw := CAST(PWinPtr, win);
  IF pw^.root # NIL THEN RetileNode(pw^.root) END
END Retile;

(* ---- splitter drag, the control plane for a live mouse (S10). The Pane tree is
   an HWND tree, so the split-parent's gutter is OCCLUDED by its children; we use
   the parent-walk: a child's WM_LBUTTONDOWN converts to pane-frame coords and
   hit-tests the PARENT's Layout. On a hit we open a per-window drag session and
   SetCapture the parent host, so the subsequent move/up route there. The headless
   gates drive HitTest/Drag directly; this path is exercised only under a real
   loop and asserts nothing through a module global. ---- *)
PROCEDURE BeginSplitDrag (pw: PWinPtr; childPane: PanePtr; lp: CARDINAL);
  VAR anc: PanePtr; lay: Layout; cx, cy, px, py: INTEGER; handle: CARDINAL; prev: HWND;
BEGIN
  IF pw^.dragActive THEN RETURN END;
  cx := VAL(INTEGER, lp BAND 0FFFFH);
  cy := VAL(INTEGER, (lp DIV 65536) BAND 0FFFFH);
  px := cx + VAL(INTEGER, childPane^.x);             (* child-client -> pane-frame absolute *)
  py := cy + VAL(INTEGER, childPane^.y);
  (* climb from the pane itself (the visible gap belongs to the split parent) then its
     ancestors: the same absolute (px,py) hit-tests any depth, so the first Layout whose
     divider is under the press wins — nested splits and gap-presses both work *)
  anc := childPane;
  WHILE anc # NIL DO
    IF anc^.layout # NIL THEN
      lay := anc^.layout;
      handle := lay.HitTest(CAST(Pane, anc), px, py);
      IF handle # MAX(CARDINAL) THEN
        pw^.dragActive := TRUE; pw^.dragHost := anc; pw^.dragLayout := lay;
        pw^.dragHandle := handle; pw^.anchorX := px; pw^.anchorY := py;
        prev := SetCapture(CAST(HWND, anc^.host));
        RETURN
      END
    END;
    anc := anc^.parent
  END
END BeginSplitDrag;

PROCEDURE ContinueSplitDrag (pw: PWinPtr; pane: PanePtr; lp: CARDINAL);
  VAR cx, cy, dx, dy: INTEGER;
BEGIN
  IF NOT pw^.dragActive THEN RETURN END;
  (* lp is in the ARRIVING host's client frame; absolutise with that pane's origin
     (= dragHost under capture, but frame-agnostic if a move reaches another host) *)
  cx := VAL(INTEGER, lp BAND 0FFFFH) + VAL(INTEGER, pane^.x);
  cy := VAL(INTEGER, (lp DIV 65536) BAND 0FFFFH) + VAL(INTEGER, pane^.y);
  dx := cx - pw^.anchorX; dy := cy - pw^.anchorY;
  pw^.dragLayout.Drag(CAST(Pane, pw^.dragHost), pw^.dragHandle, dx, dy);   (* re-weights + raises EvSplitterMoved *)
  pw^.anchorX := cx; pw^.anchorY := cy;
  Retile(CAST(PaneWindow, pw))
END ContinueSplitDrag;

PROCEDURE EndSplitDrag (pw: PWinPtr);
  VAR ok: BOOL;
BEGIN
  IF pw^.dragActive THEN
    ok := ReleaseCapture();
    pw^.dragActive := FALSE; pw^.dragHost := NIL; pw^.dragLayout := NIL
  END
END EndSplitDrag;

PROCEDURE CancelSplitDrag (pw: PWinPtr);             (* capture already lost — clear, do NOT ReleaseCapture *)
BEGIN
  pw^.dragActive := FALSE; pw^.dragHost := NIL; pw^.dragLayout := NIL
END CancelSplitDrag;

(* ---- divider hover glow (direct-draw). The split parent owns a Direct2D target;
   its children occlude all but the divider gap, so a full Clear shows only there.
   On mouse-move we parent-walk the same way the drag does to find the divider under
   the cursor, then light that split and invalidate it (-> PaintDivider re-Clears it
   bright). Leaving it (or landing on another) un-lights the previous one. ---- *)
PROCEDURE DividerUnder (pane: PanePtr; lp: CARDINAL): PanePtr;
  VAR anc: PanePtr; px, py: INTEGER;
BEGIN
  px := VAL(INTEGER, lp BAND 0FFFFH) + VAL(INTEGER, pane^.x);
  py := VAL(INTEGER, (lp DIV 65536) BAND 0FFFFH) + VAL(INTEGER, pane^.y);
  anc := pane;
  WHILE anc # NIL DO
    IF anc^.layout # NIL THEN
      IF anc^.layout.HitTest(CAST(Pane, anc), px, py) # MAX(CARDINAL) THEN RETURN anc END
    END;
    anc := anc^.parent
  END;
  RETURN NIL
END DividerUnder;

PROCEDURE UpdateHover (pane: PanePtr; lp: CARDINAL);
  VAR found: PanePtr; ig: BOOL;
BEGIN
  found := DividerUnder(pane, lp);
  IF found # gHoverPane THEN
    IF (gHoverPane # NIL) AND (gHoverPane^.host # NIL) THEN
      gHoverPane^.divHover := FALSE;
      ig := InvalidateRect(CAST(HWND, gHoverPane^.host), NIL, VAL(BOOL, 0))
    END;
    gHoverPane := found;
    IF (gHoverPane # NIL) AND (gHoverPane^.host # NIL) THEN
      gHoverPane^.divHover := TRUE;
      ig := InvalidateRect(CAST(HWND, gHoverPane^.host), NIL, VAL(BOOL, 0))
    END
  END
END UpdateHover;

(* WM_PAINT for a split host: fill the divider gap (glowing if hovered). GDI, not D2D
   — a D2D HwndRenderTarget on a parent that HAS child HWNDs does not respect
   WS_CLIPCHILDREN and blanks the panes; a GDI DC clips children out, so this only
   ever touches the thin divider gap between them. Uses GetDC + ValidateRect rather
   than BeginPaint: the generated PAINTSTRUCT is wrongly sized (rgbReserved is an
   ADDRESS, not BYTE[32]), so BeginPaint would overrun the stack. *)
PROCEDURE PaintDivider (pane: PanePtr);
  CONST DivCol = 0504A3AH; GlowCol = 0FFD060H;       (* COLORREF 0x00BBGGRR: dim slate / bright cyan *)
  VAR rc: RECT; hdc: HDC; hw: HWND; cr: COLORREF; ok, vok: BOOL; n: INTEGER32;
BEGIN
  hw := CAST(HWND, pane^.host);
  ok := GetClientRect(hw, ADR(rc));
  hdc := GetDC(hw);
  IF pane^.divHover THEN
    IF gGlowBrush = NIL THEN cr.Value := GlowCol; gGlowBrush := CreateSolidBrush(cr) END;
    n := FillRect(hdc, ADR(rc), gGlowBrush)
  ELSE
    IF gDivBrush = NIL THEN cr.Value := DivCol; gDivBrush := CreateSolidBrush(cr) END;
    n := FillRect(hdc, ADR(rc), gDivBrush)
  END;
  n := ReleaseDC(hw, hdc);
  vok := ValidateRect(hw, NIL)
END PaintDivider;

(* The one event router (§7 control plane): every host HWND shares this WNDPROC.
   The Pane under the message is recovered from the host's GWLP_USERDATA, the raw
   WM_* is packaged into a semantic Event keyed to that Pane, the polled-input
   snapshot is updated, and the Event is fanned to the owning window's Handler.
   Synchronously drivable headlessly (SendMessage -> here), the t-90-243 pattern. *)
PROCEDURE PaneWndProc (hWnd: HWND; msg: DWORD; wParam: WPARAM; lParam: LPARAM): LRESULT;
  VAR pane: PanePtr; pw: PWinPtr; ev: Event; consumed, swallow, wasDrag: BOOLEAN;
      ud: ADRINT; m, wp, lp, cx, cy, hw: CARDINAL; wd: INTEGER; vok: BOOL;
BEGIN
  swallow := FALSE; consumed := FALSE;                 (* consumed read on the syskey path even when pw=NIL *)
  ud := GetWindowLongPtrW(hWnd, GWLP_USERDATA);
  pane := CAST(PanePtr, ud);
  IF pane # NIL THEN
    m  := VAL(CARDINAL, msg);
    (* the top-level FRAME carries USERDATA=root but routes only window-level msgs
       (WM_CLOSE / WM_SIZE); every per-pane event arrives via the pane's OWN host. *)
    IF (CAST(ADDRESS, hWnd) = pane^.host) OR (m = WM_CLOSE) OR (m = WM_SIZE) OR (m = WM_TIMER) THEN
      wp := CAST(CARDINAL, wParam);
      lp := CAST(CARDINAL, lParam);
      pw := pane^.win;
      ev.window := 0; ev.pane := CAST(Pane, pane); ev.kind := EvNone;
      ev.key := 0; ev.ch := 0C; ev.x := 0; ev.y := 0; ev.command := 0; ev.doc := 0;

      (* paint pump (§10.2): a leaf's custom/GPU surface (TextGrid/Canvas/Raster/…)
         renders here on WM_PAINT; native controls have a no-op Paint (the OS draws). *)
      IF (m = WM_PAINT) AND (pane^.kind = PkLeaf) AND (pane^.back # NIL) THEN
        pane^.back.Paint(); vok := ValidateRect(CAST(HWND, pane^.host), NIL); swallow := TRUE
      ELSIF (m = WM_PAINT) AND (pane^.kind = PkArrange) AND (pane^.layout # NIL)
            AND (CAST(ADDRESS, hWnd) = pane^.host) THEN
        PaintDivider(pane); swallow := TRUE        (* split host: draw its (glowing) divider line *)
      END;

      (* polled-input lane *)
      IF (m = WM_KEYDOWN) OR (m = WM_SYSKEYDOWN) THEN gKeyState[wp MOD 256] := TRUE
      ELSIF (m = WM_KEYUP) OR (m = WM_SYSKEYUP) THEN gKeyState[wp MOD 256] := FALSE
      ELSIF (m = WM_MOUSEMOVE) OR (m = WM_LBUTTONDOWN) OR (m = WM_LBUTTONUP) THEN
        gMouseX := VAL(INTEGER, lp BAND 0FFFFH);
        gMouseY := VAL(INTEGER, (lp DIV 65536) BAND 0FFFFH);
        IF m = WM_LBUTTONDOWN THEN gMouseBtn := gMouseBtn BOR 1
        ELSIF m = WM_LBUTTONUP THEN gMouseBtn := gMouseBtn BAND 0FFFFFFFEH END
      END;

      (* semantic translation *)
      IF m = WM_COMMAND THEN ev.kind := EvControl; ev.command := wp BAND 0FFFFH
      ELSIF (m = WM_KEYDOWN) OR (m = WM_SYSKEYDOWN) THEN ev.kind := EvKey; ev.key := wp
      ELSIF m = WM_CHAR THEN ev.kind := EvChar; ev.ch := CHR(wp)
      ELSIF (m = WM_MOUSEMOVE) OR (m = WM_LBUTTONDOWN) OR (m = WM_LBUTTONUP) THEN
        ev.kind := EvMouse; ev.x := gMouseX; ev.y := gMouseY
      ELSIF m = WM_MOUSEWHEEL THEN
        hw := (wp DIV 65536) BAND 0FFFFH;                (* HIWORD(wParam) = signed wheel delta *)
        IF hw >= 8000H THEN wd := VAL(INTEGER, hw) - 65536 ELSE wd := VAL(INTEGER, hw) END;
        ev.kind := EvWheel; ev.y := wd                   (* +ve = wheel up/away; multiples of 120 *)
      ELSIF m = WM_SIZE THEN
        cx := lp BAND 0FFFFH; cy := (lp DIV 65536) BAND 0FFFFH;
        ev.kind := EvResize; ev.x := VAL(INTEGER, cx); ev.y := VAL(INTEGER, cy);
        IF (CAST(ADDRESS, hWnd) # pane^.host) AND (pane^.parent = NIL) AND (pw # NIL)
           AND (NOT pw^.closing) AND (cx > 0) AND (cy > 0) THEN
          SetRect(CAST(Pane, pane), 0, 0, cx, cy);      (* the frame: fit root to the new client + re-solve *)
          Retile(CAST(PaneWindow, pw))
        END
      ELSIF m = WM_SETFOCUS THEN ev.kind := EvPaneFocus
      ELSIF m = WM_TIMER THEN ev.kind := EvTimer                          (* idle tick *)
      ELSIF m = WM_CLOSE THEN ev.kind := EvCloseRequest; swallow := TRUE   (* app-controlled close *)
      END;

      (* splitter-drag control plane (per-window session, §8 D7): begin on a child
         press over a divider, track under capture, end on release. Coexists with the
         EvMouse fan-out below — the app still sees the raw mouse. *)
      IF pw # NIL THEN
        wasDrag := pw^.dragActive;
        IF m = WM_LBUTTONDOWN THEN BeginSplitDrag(pw, pane, lp)
        ELSIF m = WM_MOUSEMOVE THEN ContinueSplitDrag(pw, pane, lp)
        ELSIF m = WM_LBUTTONUP THEN EndSplitDrag(pw)
        ELSIF m = WM_CAPTURECHANGED THEN CancelSplitDrag(pw)   (* capture stolen -> abort, no stuck drag *)
        END;
        (* hover glow: light the divider under the cursor when not mid-drag *)
        IF (m = WM_MOUSEMOVE) AND (NOT pw^.dragActive) THEN UpdateHover(pane, lp) END;
        (* the splitter owns the mouse for the press that started a drag, the moves
           during it, and the release that ended it -> don't ALSO fan those to the
           app (else a divider-grab would reposition the editor caret) *)
        IF (m = WM_LBUTTONDOWN) AND pw^.dragActive THEN consumed := TRUE
        ELSIF (m = WM_MOUSEMOVE) AND pw^.dragActive THEN consumed := TRUE
        ELSIF (m = WM_LBUTTONUP) AND wasDrag THEN consumed := TRUE
        ELSIF ev.kind # EvNone THEN consumed := pw^.on(ev) END
      END;
      IF ((m = WM_SYSKEYDOWN) OR (m = WM_KEYDOWN)) AND consumed THEN swallow := TRUE END   (* app handled it -> no DefWindowProc (else F10/Alt enters Windows' menu loop) *)
    END
  END;
  IF swallow THEN RETURN CAST(LRESULT, 0) END;        (* consumed (WM_CLOSE / WM_PAINT / handled syskey) *)
  RETURN DefWindowProcW(hWnd, msg, wParam, lParam)
END PaneWndProc;

PROCEDURE EnsureClass (): HINSTANCE;
  VAR wc: WNDCLASSEXW; hInst: HINSTANCE; atom: WORD;
BEGIN
  hInst := GetModuleHandleW(NIL);
  gClassName := "NewM2PaneHost";
  IF NOT gClassReg THEN
    ZeroMem(ADR(wc), SIZE(wc));
    wc.cbSize := VAL(DWORD, SIZE(wc));
    wc.lpfnWndProc := CAST(ADDRESS, PaneWndProc);    (* M2 proc as a native WNDPROC *)
    wc.hInstance := hInst;
    wc.hCursor := LoadCursorW(NIL, CAST(PWSTR, 32512));   (* IDC_ARROW *)
    wc.hbrBackground := GetSysColorBrush(VAL(INTEGER32, 15));  (* COLOR_BTNFACE — bare hosts paint grey, not black *)
    wc.lpszClassName := ADR(gClassName);
    atom := RegisterClassExW(ADR(wc));
    gClassReg := TRUE
  END;
  RETURN hInst
END EnsureClass;

(* recursively create a host HWND for `n` as a child of `parentHwnd`, then for a
   leaf attach its Backend, then recurse — the HWND tree mirrors the Pane tree. *)
PROCEDURE BuildHosts (n: PanePtr; parentHwnd: ADDRESS; hInst: HINSTANCE; pw: PWinPtr);
  VAR i, rx, ry: CARDINAL; ok: BOOLEAN; ud: ADRINT;
BEGIN
  n^.win := pw;
  rx := n^.x; ry := n^.y;                               (* place RELATIVE to the parent host's client *)
  IF n^.parent # NIL THEN rx := n^.x - n^.parent^.x; ry := n^.y - n^.parent^.y END;
  n^.host := CreateWindowExW(0, ADR(gClassName), NIL,
                             WS_CHILD BOR WS_CLIPCHILDREN BOR WS_VISIBLE,
                             VAL(INTEGER32, rx), VAL(INTEGER32, ry),
                             VAL(INTEGER32, n^.w), VAL(INTEGER32, n^.h),
                             CAST(HWND, parentHwnd), NIL, hInst, NIL);
  IF n^.host # NIL THEN                                 (* host -> Pane back-ref for the router *)
    ud := SetWindowLongPtrW(CAST(HWND, n^.host), GWLP_USERDATA, CAST(ADRINT, n))
  END;
  IF (n^.kind = PkLeaf) AND (n^.host # NIL) AND (n^.back # NIL) THEN
    ok := n^.back.Attach(n^.host, n^.w, n^.h)
  END;
  i := 0;
  WHILE i < n^.nChild DO BuildHosts(n^.child[i], n^.host, hInst, pw); INC(i) END
END BuildHosts;

(* create a top-level frame HWND (the shared OpenWindow/ReparentToNewWindow piece) *)
PROCEDURE CreateFrame (title: ARRAY OF CHAR; w, h: CARDINAL): ADDRESS;
  VAR hInst: HINSTANCE; titleBuf: ARRAY [0..127] OF CHAR; i: CARDINAL;
BEGIN
  hInst := EnsureClass();
  i := 0;
  WHILE (i <= HIGH(title)) AND (i < 127) AND (title[i] # 0C) DO titleBuf[i] := title[i]; INC(i) END;
  titleBuf[i] := 0C;
  RETURN CreateWindowExW(0, ADR(gClassName), ADR(titleBuf), WS_OVERLAPPEDWINDOW,
                         CW_USEDEFAULT, CW_USEDEFAULT, VAL(INTEGER32, w), VAL(INTEGER32, h),
                         NIL, NIL, hInst, NIL)
END CreateFrame;

(* allocate a PWinRec, init its fields (incl. the empty drag session), and register
   it with the workspace if any. Caller has already checked overflow. *)
PROCEDURE AllocRegisterPWin (ws: Workspace; frame: ADDRESS; root: Pane; on: Handler): PWinPtr;
  VAR pw: PWinPtr; a: ADDRESS; wsp: WsPtr;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(PWinRec)); pw := CAST(PWinPtr, a);
  pw^.frame := frame; pw^.root := CAST(PanePtr, root); pw^.on := on; pw^.ws := NIL; pw^.closing := FALSE;
  pw^.dragActive := FALSE; pw^.dragHost := NIL; pw^.dragLayout := NIL;
  pw^.dragHandle := 0; pw^.anchorX := 0; pw^.anchorY := 0;
  IF ws # NIL THEN
    wsp := CAST(WsPtr, ws);
    IF wsp^.nWindows < MaxWindows THEN
      pw^.ws := wsp; wsp^.wins[wsp^.nWindows] := pw; INC(wsp^.nWindows)
    END
  END;
  RETURN pw
END AllocRegisterPWin;

PROCEDURE Init (): Workspace;
  VAR a: ADDRESS; ws: WsPtr;
BEGIN
  a := NIL; ALLOCATE(a, SIZE(WsRec)); ws := CAST(WsPtr, a);
  ws^.nWindows := 0; ws^.quit := FALSE;
  RETURN CAST(Workspace, ws)
END Init;

PROCEDURE OpenWindow (ws: Workspace; title: ARRAY OF CHAR; w, h: CARDINAL;
                      root: Pane; on: Handler): PaneWindow;
  VAR frame: ADDRESS; pw: PWinPtr; hInst: HINSTANCE; wsp: WsPtr; ud: ADRINT;
BEGIN
  IF ws # NIL THEN                                 (* explicit overflow: no orphaned-but-returned window *)
    wsp := CAST(WsPtr, ws); IF wsp^.nWindows >= MaxWindows THEN RETURN NIL END
  END;
  frame := CreateFrame(title, w, h);
  IF frame = NIL THEN RETURN NIL END;
  pw := AllocRegisterPWin(ws, frame, root, on);
  hInst := GetModuleHandleW(NIL);
  IF root # NIL THEN
    BuildHosts(CAST(PanePtr, root), frame, hInst, pw);
    ud := SetWindowLongPtrW(CAST(HWND, frame), GWLP_USERDATA, CAST(ADRINT, root))  (* frame WM_CLOSE -> handler *)
  END;
  RETURN CAST(PaneWindow, pw)
END OpenWindow;

(* nil host/win on the panes THIS window still owns (skip any re-parented away —
   their n^.win already points elsewhere), so a closed window leaves no dangling
   host/win in the surviving Pane tree (the app keeps the panes). *)
PROCEDURE ClearOwned (n: PanePtr; pw: PWinPtr);
  VAR i: CARDINAL;
BEGIN
  IF n = NIL THEN RETURN END;
  IF n^.win = pw THEN
    n^.host := NIL; n^.win := NIL;
    i := 0; WHILE i < n^.nChild DO ClearOwned(n^.child[i], pw); INC(i) END
  END
END ClearOwned;

PROCEDURE CloseWindow (VAR win: PaneWindow);
  VAR pw: PWinPtr; wsp: WsPtr; ok: BOOL; i: CARDINAL; ev: Event; consumed: BOOLEAN;
      a, frame: ADDRESS; root: PanePtr;
BEGIN
  IF win = NIL THEN RETURN END;
  pw := CAST(PWinPtr, win);
  win := NIL;                                         (* detach the caller's handle up front *)
  IF pw^.closing THEN RETURN END;                     (* re-entrant close of the same window -> no-op *)
  pw^.closing := TRUE;
  IF pw^.dragActive THEN ok := ReleaseCapture(); pw^.dragActive := FALSE END;  (* abort in-flight drag *)
  wsp := pw^.ws; frame := pw^.frame; root := pw^.root;
  IF wsp # NIL THEN                                   (* unregister BEFORE notifying (re-entry / WindowCount honest) *)
    i := 0;
    WHILE i < wsp^.nWindows DO
      IF wsp^.wins[i] = pw THEN
        wsp^.wins[i] := wsp^.wins[wsp^.nWindows - 1];
        wsp^.wins[wsp^.nWindows - 1] := NIL;
        DEC(wsp^.nWindows);
        i := wsp^.nWindows                            (* found -> stop *)
      ELSE INC(i) END
    END
  END;
  ev.window := 0; ev.pane := CAST(Pane, root); ev.kind := EvWindowClosed;  (* notify the app (hosts still alive) *)
  ev.key := 0; ev.ch := 0C; ev.x := 0; ev.y := 0; ev.command := 0; ev.doc := 0;
  consumed := pw^.on(ev);
  IF frame # NIL THEN ok := DestroyWindow(CAST(HWND, frame)) END;  (* child hosts go too *)
  IF root # NIL THEN ClearOwned(root, pw) END;        (* drop host/win refs we owned (no dangling) *)
  a := CAST(ADDRESS, pw); DEALLOCATE(a, SIZE(PWinRec))
END CloseWindow;

(* ======================================================================== *)
(* Re-parenting (S12): Float a Pane subtree into its own top-level window, and *)
(* Dock it back — mechanic (B), destroy + rebuild. BuildHosts IS the Pane->HWND *)
(* projection, so reusing it repoints win/host/USERDATA + re-Attaches the whole  *)
(* subtree by construction; the only new code is unlink + host teardown.        *)
(* ======================================================================== *)

(* unlink p from its parent's child[] (compacting), p^.parent := NIL. HWND side
   untouched — the caller decides destroy-vs-rebuild. FALSE if already a root. *)
PROCEDURE Detach (p: Pane): BOOLEAN;
  VAR n, par: PanePtr; i, j: CARDINAL; found: BOOLEAN;
BEGIN
  IF p = NIL THEN RETURN FALSE END;
  n := CAST(PanePtr, p); par := n^.parent;
  IF par = NIL THEN RETURN FALSE END;
  found := FALSE; i := 0;
  WHILE i < par^.nChild DO
    IF par^.child[i] = n THEN
      found := TRUE;
      j := i;
      WHILE j + 1 < par^.nChild DO par^.child[j] := par^.child[j+1]; INC(j) END;
      DEC(par^.nChild); i := par^.nChild                (* compacted -> stop *)
    ELSE INC(i) END
  END;
  n^.parent := NIL;
  RETURN found
END Detach;

(* clear host/win across a subtree (after the top host is destroyed) *)
PROCEDURE ClearHosts (n: PanePtr);
  VAR i: CARDINAL;
BEGIN
  IF n = NIL THEN RETURN END;
  n^.host := NIL; n^.win := NIL;
  i := 0; WHILE i < n^.nChild DO ClearHosts(n^.child[i]); INC(i) END
END ClearHosts;

(* DestroyWindow the subtree's top host (the OS recurses the child hosts), then
   clear host/win on every node so BuildHosts rebuilds cleanly. *)
PROCEDURE TeardownHosts (root: PanePtr);
  VAR ok: BOOL;
BEGIN
  IF root = NIL THEN RETURN END;
  IF root^.host # NIL THEN ok := DestroyWindow(CAST(HWND, root^.host)) END;
  ClearHosts(root)
END TeardownHosts;

(* Float: open a NEW top-level window whose root is an EXISTING subtree. root must
   still belong to a window (to inherit its workspace + handler) but be detached
   from its parent (call Detach first). Tears down the old hosts, then BuildHosts
   fresh under a new frame — repointing win/host/USERDATA across the subtree. *)
PROCEDURE ReparentToNewWindow (title: ARRAY OF CHAR; w, h: CARDINAL; root: Pane): PaneWindow;
  VAR rn: PanePtr; oldPw: PWinPtr; ws: Workspace; on: Handler; frame: ADDRESS; pw: PWinPtr; hInst: HINSTANCE; ud: ADRINT;
BEGIN
  IF root = NIL THEN RETURN NIL END;
  rn := CAST(PanePtr, root); oldPw := rn^.win;
  IF oldPw = NIL THEN RETURN NIL END;                   (* must currently belong to a window *)
  ws := CAST(Workspace, oldPw^.ws); on := oldPw^.on;
  IF (oldPw^.ws # NIL) AND (oldPw^.ws^.nWindows >= MaxWindows) THEN RETURN NIL END;
  frame := CreateFrame(title, w, h);                     (* create the frame BEFORE the destructive *)
  IF frame = NIL THEN RETURN NIL END;                    (* teardown, so a failure leaves the old hosts *)
  TeardownHosts(rn);                                     (* intact and the caller can roll back (mirror OpenWindow) *)
  pw := AllocRegisterPWin(ws, frame, root, on);
  hInst := GetModuleHandleW(NIL);
  BuildHosts(rn, frame, hInst, pw);
  ud := SetWindowLongPtrW(CAST(HWND, frame), GWLP_USERDATA, CAST(ADRINT, root));  (* frame WM_CLOSE -> handler *)
  RETURN CAST(PaneWindow, pw)
END ReparentToNewWindow;

(* Dock back: tear down child's (float) hosts, re-link it under parent, rebuild its
   hosts under parent's host — repointing win across the subtree. Caller then closes
   the now-empty float frame. parent must be realized (have a host). *)
PROCEDURE ReparentInto (parent, child: Pane): BOOLEAN;
  VAR pn, cn: PanePtr; hInst: HINSTANCE;
BEGIN
  IF (parent = NIL) OR (child = NIL) THEN RETURN FALSE END;
  pn := CAST(PanePtr, parent); cn := CAST(PanePtr, child);
  IF pn^.host = NIL THEN RETURN FALSE END;
  IF pn^.nChild >= MaxChildren THEN RETURN FALSE END;  (* no room — don't tear the child into limbo *)
  TeardownHosts(cn);
  AddChild(parent, child);                              (* re-link (sets cn^.parent := pn) *)
  hInst := GetModuleHandleW(NIL);
  BuildHosts(cn, pn^.host, hInst, pn^.win);
  RETURN TRUE
END ReparentInto;

(* Realize a child whose parent is ALREADY windowed but which has no host yet (e.g.
   a document added at runtime, after OpenWindow). BuildHosts gives it host/win so
   it displays on the next Retile and can be Floated. No-op if already realized. *)
PROCEDURE Realize (parent, child: Pane): BOOLEAN;
  VAR pn, cn: PanePtr; hInst: HINSTANCE;
BEGIN
  IF (parent = NIL) OR (child = NIL) THEN RETURN FALSE END;
  pn := CAST(PanePtr, parent); cn := CAST(PanePtr, child);
  IF pn^.host = NIL THEN RETURN FALSE END;             (* parent not windowed -> nothing to do *)
  IF cn^.host # NIL THEN RETURN TRUE END;              (* already realized *)
  hInst := GetModuleHandleW(NIL);
  BuildHosts(cn, pn^.host, hInst, pn^.win);
  RETURN TRUE
END Realize;

PROCEDURE ParentOf (p: Pane): Pane;                      (* NIL if a root / detached *)
  VAR n: PanePtr;
BEGIN IF p = NIL THEN RETURN NIL END; n := CAST(PanePtr, p); RETURN CAST(Pane, n^.parent) END ParentOf;

PROCEDURE WindowOf (p: Pane): PaneWindow;                (* the window p belongs to (NIL if none) *)
  VAR n: PanePtr;
BEGIN IF p = NIL THEN RETURN NIL END; n := CAST(PanePtr, p); RETURN CAST(PaneWindow, n^.win) END WindowOf;

PROCEDURE RootOf (win: PaneWindow): Pane;
  VAR pw: PWinPtr;
BEGIN IF win = NIL THEN RETURN NIL END; pw := CAST(PWinPtr, win); RETURN CAST(Pane, pw^.root) END RootOf;

PROCEDURE HostOf (p: Pane): ADDRESS;
  VAR n: PanePtr;
BEGIN
  IF p = NIL THEN RETURN NIL END;
  n := CAST(PanePtr, p); RETURN n^.host
END HostOf;

PROCEDURE FrameOf (win: PaneWindow): ADDRESS;
  VAR pw: PWinPtr;
BEGIN
  IF win = NIL THEN RETURN NIL END;
  pw := CAST(PWinPtr, win); RETURN pw^.frame
END FrameOf;

(* A Layout strategy (or facade) raises a semantic Event keyed to a Pane — the
   control-plane path for EvSplitterMoved / EvTabChanged / EvDoc* that originate
   in a layout op rather than a raw Win32 message. Fans to the pane's window
   Handler (same as the router's WM_* path). *)
PROCEDURE RaiseEventDoc (p: Pane; kind: EventKind; doc: CARDINAL);
  VAR n: PanePtr; pw: PWinPtr; ev: Event; consumed: BOOLEAN;
BEGIN
  IF p = NIL THEN RETURN END;
  n := CAST(PanePtr, p); pw := n^.win;
  IF pw = NIL THEN RETURN END;
  ev.window := 0; ev.pane := p; ev.kind := kind;
  ev.key := 0; ev.ch := 0C; ev.x := 0; ev.y := 0; ev.command := 0; ev.doc := doc;
  consumed := pw^.on(ev)
END RaiseEventDoc;

PROCEDURE RaiseEvent (p: Pane; kind: EventKind);
BEGIN RaiseEventDoc(p, kind, 0) END RaiseEvent;

PROCEDURE SetRoot (win: PaneWindow; root: Pane);
BEGIN END SetRoot;

(* ---- the real message loop (§10.2). PumpOne is the single source of truth: one
   fetch-translate-dispatch step, parameterised by blocking. Run blocks on
   GetMessageW (interactive, sleeps when idle); RunBounded drains via PeekMessageW
   for a bounded number of iterations (deterministic + never blocks — the headless
   CI driver). Both honour the workspace quit latch, so Quit (flag + WM_QUIT) ends
   either. ---- *)
PROCEDURE PumpOne (blocking: BOOLEAN): BOOLEAN;       (* FALSE => a WM_QUIT was seen *)
  VAR msg: MSG; r, tr: BOOL; lr: LRESULT;
BEGIN
  IF blocking THEN
    r := GetMessageW(ADR(msg), NIL, VAL(DWORD, 0), VAL(DWORD, 0));
    IF r = 0 THEN RETURN FALSE                         (* WM_QUIT *)
    ELSIF r < 0 THEN RETURN FALSE END                 (* GetMessage error: stop, don't dispatch a garbage MSG *)
  ELSE
    r := PeekMessageW(ADR(msg), NIL, VAL(DWORD, 0), VAL(DWORD, 0), VAL(DWORD, PM_REMOVE));
    IF r = 0 THEN RETURN TRUE END;                    (* idle this tick — keep looping *)
    IF msg.message = VAL(DWORD, WM_QUIT) THEN RETURN FALSE END
  END;
  tr := TranslateMessage(ADR(msg));
  lr := DispatchMessageW(ADR(msg));
  RETURN TRUE
END PumpOne;

PROCEDURE ShowWorkspace (ws: WsPtr);                  (* show every top-level frame (children are WS_VISIBLE) *)
  VAR i: CARDINAL; ok: BOOL;
BEGIN
  IF ws = NIL THEN RETURN END;
  i := 0;
  WHILE i < ws^.nWindows DO
    IF (ws^.wins[i] # NIL) AND (ws^.wins[i]^.frame # NIL) THEN
      ok := ShowWindow(CAST(HWND, ws^.wins[i]^.frame), VAL(INTEGER32, SW_SHOW))
    END;
    INC(i)
  END
END ShowWorkspace;

PROCEDURE Run (ws: Workspace);                        (* interactive: block until WM_QUIT / Quit *)
  VAR w: WsPtr; cont: BOOLEAN;
BEGIN
  w := CAST(WsPtr, ws);
  ShowWorkspace(w);
  cont := TRUE;
  WHILE cont DO
    cont := PumpOne(TRUE);
    IF cont AND (w # NIL) AND w^.quit THEN cont := FALSE END
  END
END Run;

PROCEDURE RunBounded (ws: Workspace; maxIters: CARDINAL);   (* CI: bounded, never blocks *)
  VAR w: WsPtr; i: CARDINAL; cont: BOOLEAN;
BEGIN
  w := CAST(WsPtr, ws);
  ShowWorkspace(w);
  i := 0; cont := TRUE;
  WHILE (i < maxIters) AND cont DO
    cont := PumpOne(FALSE);
    IF (w # NIL) AND w^.quit THEN cont := FALSE END;
    INC(i)
  END
END RunBounded;

PROCEDURE WindowCount (ws: Workspace): CARDINAL;
  VAR w: WsPtr;
BEGIN
  IF ws = NIL THEN RETURN 0 END;
  w := CAST(WsPtr, ws); RETURN w^.nWindows
END WindowCount;

PROCEDURE Quit (ws: Workspace);
  VAR w: WsPtr;
BEGIN
  IF ws # NIL THEN w := CAST(WsPtr, ws); w^.quit := TRUE END;
  PostQuitMessage(VAL(INTEGER32, 0))
END Quit;

PROCEDURE SetThreaded (p: Pane; on: BOOLEAN);
  VAR n: PanePtr;
BEGIN
  IF p # NIL THEN n := CAST(PanePtr, p); n^.threaded := on END   (* dark seam: flag only (D2) *)
END SetThreaded;

PROCEDURE KeyDown (vk: CARDINAL): BOOLEAN;
BEGIN IF vk <= 255 THEN RETURN gKeyState[vk] END; RETURN FALSE END KeyDown;

PROCEDURE MouseAt (VAR x, y: INTEGER; VAR buttons: CARDINAL);
BEGIN x := gMouseX; y := gMouseY; buttons := gMouseBtn END MouseAt;

BEGIN
  gClassReg := FALSE
END PaneShell.
