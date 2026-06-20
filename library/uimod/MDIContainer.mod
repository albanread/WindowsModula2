(* MDIContainer implementation — S11 (arrangements) + S12 slice 1 (float/dock +
   drop zones). DockLayout is just ANOTHER PaneShell.Layout over the same Pane tree.
   Documents live in a STABLE registry (id = registry index, survives Float's
   detach); the container's CHILDREN are exactly the DOCKED docs, so a floated doc
   leaves the child list but keeps its id. Float pops a doc subtree into its own
   top-level window (substrate ReparentToNewWindow, mechanic destroy+rebuild); Dock
   is the inverse (ReparentInto + close the empty float frame). DropAt computes the
   dock zone (25% edge bands, nearest edge wins; centre = tabbed). Save/Load +
   Tile/Cascade/TabTogether are S12 slice 2. *)
IMPLEMENTATION MODULE MDIContainer;

FROM SYSTEM IMPORT CAST;
IMPORT PaneShell;

CONST
  MaxDocs     = 32;
  TabStripH   = 24;
  CascadeStep = 30;
  FloatW      = 400;     (* default floater size *)
  FloatH      = 300;

PROCEDURE GridCols (vis: CARDINAL): CARDINAL;        (* smallest c with c*c >= vis *)
  VAR c: CARDINAL;
BEGIN c := 1; WHILE c*c < vis DO INC(c) END; RETURN c END GridCols;

(* ---- DockLayout: the arrangement strategy (D7), with a stable doc registry ---- *)
CLASS DockLayout;
  INHERIT PaneShell.Layout;
  VAR style: Style; active, nDocs: CARDINAL;
      docPane:    ARRAY [0..MaxDocs-1] OF PaneShell.Pane;
      docFloated: ARRAY [0..MaxDocs-1] OF BOOLEAN;
      docWin:     ARRAY [0..MaxDocs-1] OF PaneShell.PaneWindow;
      titles:     ARRAY [0..MaxDocs-1] OF ARRAY [0..63] OF CHAR;
  OVERRIDE PROCEDURE Arrange (host: PaneShell.Pane; x, y, w, h: CARDINAL);
    VAR n, i, vis, k, cols, rows, cellW, cellH, dw, dh, span: CARDINAL;
        ch, activePane: PaneShell.Pane;
  BEGIN
    n := PaneShell.ChildCount(host);
    vis := 0; i := 0;
    WHILE i < n DO IF NOT PaneShell.IsHidden(PaneShell.Child(host, i)) THEN INC(vis) END; INC(i) END;
    IF vis = 0 THEN RETURN END;
    IF style = Tabbed THEN
      activePane := NIL;
      IF (active < nDocs) AND (NOT docFloated[active]) AND (NOT PaneShell.IsHidden(docPane[active])) THEN
        activePane := docPane[active]
      END;
      IF activePane = NIL THEN                         (* active floated/closed -> fall back to first visible doc *)
        i := 0;
        WHILE i < n DO
          ch := PaneShell.Child(host, i);
          IF NOT PaneShell.IsHidden(ch) THEN activePane := ch; i := n ELSE INC(i) END
        END
      END;
      i := 0;
      WHILE i < n DO
        ch := PaneShell.Child(host, i);
        IF (ch = activePane) AND (NOT PaneShell.IsHidden(ch)) THEN
          IF h > TabStripH THEN PaneShell.SetRect(ch, x, y + TabStripH, w, h - TabStripH)
          ELSE PaneShell.SetRect(ch, x, y, w, 0) END
        ELSE PaneShell.SetRect(ch, x, y, 0, 0) END;
        INC(i)
      END
    ELSIF style = Tiled THEN
      cols := GridCols(vis); rows := (vis + cols - 1) DIV cols;
      cellW := w DIV cols; cellH := h DIV rows;
      k := 0; i := 0;
      WHILE i < n DO
        ch := PaneShell.Child(host, i);
        IF PaneShell.IsHidden(ch) THEN PaneShell.SetRect(ch, x, y, 0, 0)
        ELSE
          PaneShell.SetRect(ch, x + (k MOD cols) * cellW, y + (k DIV cols) * cellH, cellW, cellH);
          INC(k)
        END;
        INC(i)
      END
    ELSE                                              (* Cascaded *)
      span := (vis - 1) * CascadeStep;
      IF w > span THEN dw := w - span ELSE dw := w END;
      IF h > span THEN dh := h - span ELSE dh := h END;
      k := 0; i := 0;
      WHILE i < n DO
        ch := PaneShell.Child(host, i);
        IF PaneShell.IsHidden(ch) THEN PaneShell.SetRect(ch, x, y, 0, 0)
        ELSE
          PaneShell.SetRect(ch, x + k * CascadeStep, y + k * CascadeStep, dw, dh);
          INC(k)
        END;
        INC(i)
      END
    END
  END Arrange;
  OVERRIDE PROCEDURE HitTest (host: PaneShell.Pane; px, py: INTEGER): CARDINAL;
  BEGIN RETURN MAX(CARDINAL) END HitTest;            (* tab/dock-handle hit-test is S12 slice 2 *)
  OVERRIDE PROCEDURE Drag (host: PaneShell.Pane; handle: CARDINAL; dx, dy: INTEGER);
  BEGIN END Drag;
  OVERRIDE PROCEDURE DropAt (host: PaneShell.Pane; px, py: INTEGER; moved: PaneShell.Pane;
                             VAR zone: PaneShell.DropZone; VAR x, y, w, h: CARDINAL): BOOLEAN;
    VAR hx, hy, hw, hh: CARDINAL; rx, ry, dl, dr, dt, db: INTEGER;
  BEGIN
    PaneShell.RectOf(host, hx, hy, hw, hh);
    rx := px - VAL(INTEGER, hx); ry := py - VAL(INTEGER, hy);
    IF (rx < 0) OR (rx >= VAL(INTEGER, hw)) OR (ry < 0) OR (ry >= VAL(INTEGER, hh)) THEN
      zone := PaneShell.NoDrop; RETURN FALSE          (* outside the region -> caller may NewFloat *)
    END;
    IF (rx >= VAL(INTEGER, hw DIV 4)) AND (rx < VAL(INTEGER, hw - hw DIV 4)) AND
       (ry >= VAL(INTEGER, hh DIV 4)) AND (ry < VAL(INTEGER, hh - hh DIV 4)) THEN
      zone := PaneShell.DockCentre; x := hx; y := hy; w := hw; h := hh        (* tab into the region *)
    ELSE
      dl := rx; dr := VAL(INTEGER, hw) - rx; dt := ry; db := VAL(INTEGER, hh) - ry;
      IF (dl <= dr) AND (dl <= dt) AND (dl <= db) THEN
        zone := PaneShell.DockLeft;   x := hx;            y := hy;            w := hw DIV 2;      h := hh
      ELSIF (dr <= dt) AND (dr <= db) THEN
        zone := PaneShell.DockRight;  x := hx + hw DIV 2; y := hy;            w := hw - hw DIV 2; h := hh
      ELSIF dt <= db THEN
        zone := PaneShell.DockTop;    x := hx;            y := hy;            w := hw;            h := hh DIV 2
      ELSE
        zone := PaneShell.DockBottom; x := hx;            y := hy + hh DIV 2; w := hw;            h := hh - hh DIV 2
      END
    END;
    RETURN TRUE
  END DropAt;
  OVERRIDE PROCEDURE Save (host: PaneShell.Pane; VAR blob: ARRAY OF CHAR): BOOLEAN;
  BEGIN RETURN FALSE END Save;                       (* arrangement persistence is S12 slice 2 *)
  OVERRIDE PROCEDURE Load (host: PaneShell.Pane; blob: ARRAY OF CHAR): BOOLEAN;
  BEGIN RETURN FALSE END Load;
END DockLayout;

PROCEDURE Create (style: Style): PaneShell.Pane;
  VAR p: PaneShell.Pane; dl: DockLayout;
BEGIN
  p := PaneShell.Arrange("mdi");
  NEW(dl); dl.style := style; dl.active := 0; dl.nDocs := 0;
  PaneShell.SetLayout(p, dl);
  RETURN p
END Create;

PROCEDURE AddDocument (c: PaneShell.Pane; title: ARRAY OF CHAR;
                       content: PaneShell.Pane): CARDINAL;
  VAR lay: PaneShell.Layout; dl: DockLayout; id, j: CARDINAL; ok: BOOLEAN;
BEGIN
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN MAX(CARDINAL) END;        (* sentinel: not added (no valid id) *)
  dl := CAST(DockLayout, lay);
  IF dl.nDocs >= MaxDocs THEN RETURN MAX(CARDINAL) END;
  id := dl.nDocs;                                    (* stable id = registry index *)
  dl.docPane[id] := content; dl.docFloated[id] := FALSE; dl.docWin[id] := NIL;
  j := 0;
  WHILE (j <= HIGH(title)) AND (j < 63) AND (title[j] # 0C) DO dl.titles[id][j] := title[j]; INC(j) END;
  dl.titles[id][j] := 0C;
  INC(dl.nDocs);
  PaneShell.AddChild(c, content);                    (* docked docs are the container's children *)
  IF PaneShell.WindowOf(c) # NIL THEN ok := PaneShell.Realize(c, content) END;  (* host a runtime-added doc *)
  RETURN id
END AddDocument;

PROCEDURE CloseDocument (c: PaneShell.Pane; doc: CARDINAL);
  VAR lay: PaneShell.Layout; dl: DockLayout; fw, cwin: PaneShell.PaneWindow; ok: BOOLEAN;
BEGIN
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN END;
  dl := CAST(DockLayout, lay);
  IF doc >= dl.nDocs THEN RETURN END;
  IF dl.docFloated[doc] THEN                          (* a floated doc: re-dock it, then drop its window *)
    fw := PaneShell.WindowOf(dl.docPane[doc]);        (* live float window (NIL if already closed) *)
    dl.docFloated[doc] := FALSE; dl.docWin[doc] := NIL;
    ok := PaneShell.ReparentInto(c, dl.docPane[doc]);
    IF fw # NIL THEN PaneShell.CloseWindow(fw) END
  END;
  PaneShell.SetHidden(dl.docPane[doc], TRUE);         (* mark closed -> 0-rect in the container *)
  PaneShell.RaiseEventDoc(c, PaneShell.EvDocClosed, doc);
  cwin := PaneShell.WindowOf(c);
  IF cwin # NIL THEN PaneShell.Retile(cwin) END
END CloseDocument;

PROCEDURE Activate (c: PaneShell.Pane; doc: CARDINAL);
  VAR lay: PaneShell.Layout; dl: DockLayout;
BEGIN
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN END;
  dl := CAST(DockLayout, lay);
  IF doc < dl.nDocs THEN
    dl.active := doc;
    PaneShell.RaiseEventDoc(c, PaneShell.EvDocActivated, doc)
  END
END Activate;

PROCEDURE ActiveDocument (c: PaneShell.Pane): CARDINAL;
  VAR lay: PaneShell.Layout; dl: DockLayout;
BEGIN
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN 0 END;
  dl := CAST(DockLayout, lay); RETURN dl.active
END ActiveDocument;

(* ---- float / dock (S12 slice 1): re-parent a doc subtree to/from its own window ---- *)
PROCEDURE Float (c: PaneShell.Pane; doc: CARDINAL);
  VAR lay: PaneShell.Layout; dl: DockLayout; d: PaneShell.Pane;
      win, cwin: PaneShell.PaneWindow; ok: BOOLEAN; i: CARDINAL;
BEGIN
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN END;
  dl := CAST(DockLayout, lay);
  IF (doc >= dl.nDocs) OR dl.docFloated[doc] THEN RETURN END;
  d := dl.docPane[doc];
  IF PaneShell.IsHidden(d) THEN RETURN END;          (* don't resurrect a closed doc as a floater *)
  IF PaneShell.WindowOf(d) = NIL THEN RETURN END;    (* fail BEFORE the irreversible Detach (un-hosted doc) *)
  cwin := PaneShell.WindowOf(c);
  ok := PaneShell.Detach(d);                         (* leave c's child list (id stays in the registry) *)
  IF NOT ok THEN RETURN END;
  win := PaneShell.ReparentToNewWindow(dl.titles[doc], FloatW, FloatH, d);
  IF win = NIL THEN                                   (* reparent failed (overflow / OS) -> roll back the detach *)
    PaneShell.AddChild(c, d);
    IF cwin # NIL THEN PaneShell.Retile(cwin) END;
    RETURN
  END;
  dl.docFloated[doc] := TRUE; dl.docWin[doc] := win;
  IF doc = dl.active THEN                             (* don't leave `active` on a floated doc (blank Tabbed) *)
    i := 0;
    WHILE i < dl.nDocs DO
      IF (i # doc) AND (NOT dl.docFloated[i]) AND (NOT PaneShell.IsHidden(dl.docPane[i])) THEN
        dl.active := i; i := dl.nDocs
      ELSE INC(i) END
    END
  END;
  PaneShell.SetRect(d, 0, 0, FloatW, FloatH);
  PaneShell.Retile(win);
  IF cwin # NIL THEN PaneShell.Retile(cwin) END;     (* container re-solves without the floated doc *)
  PaneShell.RaiseEventDoc(c, PaneShell.EvDocFloated, doc)
END Float;

PROCEDURE Dock (c: PaneShell.Pane; doc: CARDINAL; side: Side);
  VAR lay: PaneShell.Layout; dl: DockLayout; d: PaneShell.Pane;
      fw, cwin: PaneShell.PaneWindow; ok: BOOLEAN;
BEGIN
  (* side-specific splitting (edge -> split the region) is S12 slice 2; here the
     doc simply rejoins the container's arrangement. *)
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN END;
  dl := CAST(DockLayout, lay);
  IF (doc >= dl.nDocs) OR (NOT dl.docFloated[doc]) THEN RETURN END;
  d := dl.docPane[doc]; fw := PaneShell.WindowOf(d);  (* live float window (NIL if it was closed externally) *)
  ok := PaneShell.ReparentInto(c, d);                (* teardown float hosts + re-link under c + rebuild *)
  IF NOT ok THEN RETURN END;
  IF fw # NIL THEN PaneShell.CloseWindow(fw) END;    (* destroy the now-empty float frame + unregister *)
  dl.docFloated[doc] := FALSE; dl.docWin[doc] := NIL;
  cwin := PaneShell.WindowOf(c);
  IF cwin # NIL THEN PaneShell.Retile(cwin) END;
  PaneShell.RaiseEventDoc(c, PaneShell.EvDocDocked, doc)
END Dock;

(* apply a DropAt result: the bridge from a computed DropZone to the structural
   action. NewFloat pops the doc to its own window; any Dock* zone re-docks a
   floated doc (a docked doc dropped on a Dock* zone is a no-op via Dock's guard).
   (Edge-zone -> SPLIT the region is the dock-tree extension, deferred.) *)
PROCEDURE DockInto (c: PaneShell.Pane; doc: CARDINAL; zone: PaneShell.DropZone): BOOLEAN;
BEGIN
  IF    zone = PaneShell.NewFloat   THEN Float(c, doc); RETURN TRUE
  ELSIF zone = PaneShell.DockCentre THEN Dock(c, doc, Centre); RETURN TRUE
  ELSIF zone = PaneShell.DockLeft   THEN Dock(c, doc, Left);   RETURN TRUE
  ELSIF zone = PaneShell.DockRight  THEN Dock(c, doc, Right);  RETURN TRUE
  ELSIF zone = PaneShell.DockTop    THEN Dock(c, doc, Top);    RETURN TRUE
  ELSIF zone = PaneShell.DockBottom THEN Dock(c, doc, Bottom); RETURN TRUE
  ELSE RETURN FALSE END                                (* NoDrop *)
END DockInto;

(* ---- re-arrange commands: set the DockLayout style (or active) then Retile ---- *)
PROCEDURE ReStyle (c: PaneShell.Pane; st: Style);
  VAR lay: PaneShell.Layout; dl: DockLayout; cwin: PaneShell.PaneWindow;
BEGIN
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN END;
  dl := CAST(DockLayout, lay); dl.style := st;
  cwin := PaneShell.WindowOf(c);
  IF cwin # NIL THEN PaneShell.Retile(cwin) END
END ReStyle;

PROCEDURE Tile (c: PaneShell.Pane);
BEGIN ReStyle(c, Tiled) END Tile;

PROCEDURE Cascade (c: PaneShell.Pane);
BEGIN ReStyle(c, Cascaded) END Cascade;

PROCEDURE TabTogether (c: PaneShell.Pane; docA, docB: CARDINAL);
  VAR lay: PaneShell.Layout; dl: DockLayout; cwin: PaneShell.PaneWindow;
BEGIN
  (* minimal: switch to Tabbed showing docB; true per-group sub-tabbing is later *)
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN END;
  dl := CAST(DockLayout, lay); dl.style := Tabbed;
  IF (docB < dl.nDocs) AND (NOT dl.docFloated[docB]) AND (NOT PaneShell.IsHidden(dl.docPane[docB])) THEN
    dl.active := docB                                 (* only activate a docked, visible doc *)
  END;
  cwin := PaneShell.WindowOf(c);
  IF cwin # NIL THEN PaneShell.Retile(cwin) END
END TabTogether;

(* ---- arrangement persistence (arrangement ONLY, never content; §10.4). The blob
   is a versioned text record: PSL1;s=<style>;a=<active>;n=<ndocs>;c=<closedbits>;
   LoadLayout re-applies it to a container holding the same docs (the `supply` Pane
   for full content re-binding by id is a later refinement). ---- *)
PROCEDURE AppendCh (VAR b: ARRAY OF CHAR; VAR pos: CARDINAL; ch: CHAR);
BEGIN IF pos <= HIGH(b) THEN b[pos] := ch END; INC(pos) END AppendCh;   (* always INC -> pos = chars needed (overflow detectable) *)

PROCEDURE AppendStr (VAR b: ARRAY OF CHAR; VAR pos: CARDINAL; s: ARRAY OF CHAR);
  VAR i: CARDINAL;
BEGIN i := 0; WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO AppendCh(b, pos, s[i]); INC(i) END END AppendStr;

PROCEDURE AppendCard (VAR b: ARRAY OF CHAR; VAR pos: CARDINAL; n: CARDINAL);
  VAR digits: ARRAY [0..23] OF CHAR; k: CARDINAL;     (* 64-bit CARDINAL is up to 20 digits *)
BEGIN
  IF n = 0 THEN AppendCh(b, pos, '0'); RETURN END;
  k := 0;
  WHILE n > 0 DO digits[k] := CHR((n MOD 10) + ORD('0')); n := n DIV 10; INC(k) END;
  WHILE k > 0 DO DEC(k); AppendCh(b, pos, digits[k]) END
END AppendCard;

PROCEDURE SkipLit (b: ARRAY OF CHAR; VAR pos: CARDINAL; s: ARRAY OF CHAR): BOOLEAN;
  VAR i: CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(s)) AND (s[i] # 0C) DO
    IF (pos > HIGH(b)) OR (b[pos] # s[i]) THEN RETURN FALSE END;
    INC(pos); INC(i)
  END;
  RETURN TRUE
END SkipLit;

PROCEDURE ParseCardAt (b: ARRAY OF CHAR; VAR pos: CARDINAL): CARDINAL;
  VAR v: CARDINAL;
BEGIN
  v := 0;
  WHILE (pos <= HIGH(b)) AND (b[pos] >= '0') AND (b[pos] <= '9') DO
    v := v * 10 + (ORD(b[pos]) - ORD('0')); INC(pos)
  END;
  RETURN v
END ParseCardAt;

PROCEDURE SaveLayout (c: PaneShell.Pane; VAR blob: ARRAY OF CHAR): BOOLEAN;
  VAR lay: PaneShell.Layout; dl: DockLayout; pos, i: CARDINAL;
BEGIN
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN FALSE END;
  dl := CAST(DockLayout, lay);
  pos := 0;
  AppendStr(blob, pos, "PSL1;s=");  AppendCard(blob, pos, ORD(dl.style));
  AppendStr(blob, pos, ";a=");      AppendCard(blob, pos, dl.active);
  AppendStr(blob, pos, ";n=");      AppendCard(blob, pos, dl.nDocs);
  AppendStr(blob, pos, ";c=");
  i := 0;
  WHILE i < dl.nDocs DO
    IF PaneShell.IsHidden(dl.docPane[i]) THEN AppendCh(blob, pos, '1') ELSE AppendCh(blob, pos, '0') END;
    INC(i)
  END;
  AppendCh(blob, pos, ';');
  IF pos <= HIGH(blob) THEN blob[pos] := 0C; RETURN TRUE      (* room for the terminator *)
  ELSE blob[HIGH(blob)] := 0C; RETURN FALSE END              (* truncated: terminate + signal failure *)
END SaveLayout;

PROCEDURE LoadLayout (c: PaneShell.Pane; blob: ARRAY OF CHAR; supply: PaneShell.Pane): BOOLEAN;
  VAR lay: PaneShell.Layout; dl: DockLayout; pos, s, a, n, i, cnt, j: CARDINAL; cwin: PaneShell.PaneWindow;
BEGIN
  lay := PaneShell.LayoutOf(c);
  IF lay = NIL THEN RETURN FALSE END;
  dl := CAST(DockLayout, lay);
  pos := 0;
  IF NOT SkipLit(blob, pos, "PSL1;s=") THEN RETURN FALSE END;   (* magic + version: reject unknown *)
  s := ParseCardAt(blob, pos);
  IF NOT SkipLit(blob, pos, ";a=") THEN RETURN FALSE END;
  a := ParseCardAt(blob, pos);
  IF NOT SkipLit(blob, pos, ";n=") THEN RETURN FALSE END;
  n := ParseCardAt(blob, pos);
  IF NOT SkipLit(blob, pos, ";c=") THEN RETURN FALSE END;
  (* validate the whole closed-bit field BEFORE mutating anything (fail closed) *)
  cnt := n; IF dl.nDocs < cnt THEN cnt := dl.nDocs END;
  IF pos + cnt > HIGH(blob) + 1 THEN RETURN FALSE END;          (* truncated bit field *)
  j := pos;
  WHILE j < pos + cnt DO
    IF (blob[j] # '0') AND (blob[j] # '1') THEN RETURN FALSE END;
    INC(j)
  END;
  i := 0;                                                       (* validated -> apply (no partial mutation) *)
  WHILE i < cnt DO
    IF blob[pos] = '1' THEN PaneShell.SetHidden(dl.docPane[i], TRUE)
    ELSE PaneShell.SetHidden(dl.docPane[i], FALSE) END;
    INC(pos); INC(i)
  END;
  IF s = 0 THEN dl.style := Tabbed ELSIF s = 1 THEN dl.style := Tiled ELSE dl.style := Cascaded END;
  IF a < dl.nDocs THEN dl.active := a END;
  cwin := PaneShell.WindowOf(c);
  IF cwin # NIL THEN PaneShell.Retile(cwin) END;
  RETURN TRUE
END LoadLayout;

END MDIContainer.
