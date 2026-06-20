(* PaneLayout implementation — S8 (P4 part 1/2): the reactive facade. Split and
   Stack are built as PaneShell.Layout STRATEGIES (D7) from birth — not free
   procedures — so the substrate's Retile drives them through Arrange and S11
   only adds the DockLayout sibling. layout = f(structure), retained not diffed
   (D1): the change path is mutate the held tree (SetWeight/Replace/SetHidden)
   then PaneShell.Retile. Splitter DRAG + fixed Tabs (TabLayout) are S9. *)
IMPLEMENTATION MODULE PaneLayout;

FROM SYSTEM IMPORT CAST;
IMPORT PaneShell;

CONST
  GutterTol = 8;        (* px tolerance below the divider line *)
  GripUp    = 24;        (* px tolerance ABOVE it — a top pane's bottom edge (e.g. a status bar) is a natural grab *)
  MaxTabs   = 16;
  TabStripH = 24;       (* tab-strip height reserved above the active tab's child *)

PROCEDURE IAbs (a: INTEGER): INTEGER; BEGIN IF a < 0 THEN RETURN -a ELSE RETURN a END END IAbs;

(* weighted first-pane size along the split axis, with min-size clamps *)
PROCEDURE SplitSize (total: CARDINAL; weight: REAL; minA, minB: CARDINAL): CARDINAL;
  VAR s: CARDINAL;
BEGIN
  s := VAL(CARDINAL, TRUNC(VAL(REAL, total) * weight));
  IF s < minA THEN s := minA END;                    (* first never below minA *)
  IF s + minB > total THEN                           (* second never below minB *)
    IF total > minB THEN s := total - minB ELSE s := 0 END
  END;
  IF s > total THEN s := total END;
  RETURN s
END SplitSize;

(* ---- SplitLayout: a weighted two-pane split with min-size clamps ---- *)
CLASS SplitLayout;
  INHERIT PaneShell.Layout;
  VAR dir: Orientation; weight: REAL; minFirst, minSecond: CARDINAL;
  OVERRIDE PROCEDURE Arrange (host: PaneShell.Pane; x, y, w, h: CARDINAL);
    VAR c0, c1: PaneShell.Pane; h0, h1: BOOLEAN; s0: CARDINAL;
  BEGIN
    IF PaneShell.ChildCount(host) < 2 THEN RETURN END;
    c0 := PaneShell.Child(host, 0); c1 := PaneShell.Child(host, 1);
    h0 := PaneShell.IsHidden(c0); h1 := PaneShell.IsHidden(c1);
    IF h0 AND h1 THEN
      PaneShell.SetRect(c0, x, y, 0, 0); PaneShell.SetRect(c1, x, y, 0, 0); RETURN
    ELSIF h0 THEN
      PaneShell.SetRect(c0, x, y, 0, 0); PaneShell.SetRect(c1, x, y, w, h); RETURN
    ELSIF h1 THEN
      PaneShell.SetRect(c1, x, y, 0, 0); PaneShell.SetRect(c0, x, y, w, h); RETURN
    END;
    IF dir = Horizontal THEN
      s0 := SplitSize(w, weight, minFirst, minSecond);
      PaneShell.SetRect(c0, x, y, s0, h);
      PaneShell.SetRect(c1, x + s0, y, w - s0, h)
    ELSE
      s0 := SplitSize(h, weight, minFirst, minSecond);
      PaneShell.SetRect(c0, x, y, w, s0);
      PaneShell.SetRect(c1, x, y + s0, w, h - s0)
    END
  END Arrange;
  OVERRIDE PROCEDURE HitTest (host: PaneShell.Pane; px, py: INTEGER): CARDINAL;
    VAR x, y, w, h, s0: CARDINAL; bnd: INTEGER;
  BEGIN
    PaneShell.RectOf(host, x, y, w, h);
    IF dir = Horizontal THEN
      s0 := SplitSize(w, weight, minFirst, minSecond);
      bnd := VAL(INTEGER, x) + VAL(INTEGER, s0);
      IF (px >= bnd - GripUp) AND (px <= bnd + GutterTol)
         AND (py >= VAL(INTEGER, y)) AND (py < VAL(INTEGER, y) + VAL(INTEGER, h)) THEN
        RETURN 0
      END
    ELSE
      s0 := SplitSize(h, weight, minFirst, minSecond);
      bnd := VAL(INTEGER, y) + VAL(INTEGER, s0);
      IF (py >= bnd - GripUp) AND (py <= bnd + GutterTol)
         AND (px >= VAL(INTEGER, x)) AND (px < VAL(INTEGER, x) + VAL(INTEGER, w)) THEN
        RETURN 0
      END
    END;
    RETURN MAX(CARDINAL)                              (* not on the divider *)
  END HitTest;
  OVERRIDE PROCEDURE Drag (host: PaneShell.Pane; handle: CARDINAL; dx, dy: INTEGER);
    VAR x, y, w, h: CARDINAL; cur, ns, tot: INTEGER;
  BEGIN
    IF handle # 0 THEN RETURN END;                    (* handle 0 = the divider *)
    PaneShell.RectOf(host, x, y, w, h);
    IF dir = Horizontal THEN
      tot := VAL(INTEGER, w); cur := VAL(INTEGER, SplitSize(w, weight, minFirst, minSecond)); ns := cur + dx
    ELSE
      tot := VAL(INTEGER, h); cur := VAL(INTEGER, SplitSize(h, weight, minFirst, minSecond)); ns := cur + dy
    END;
    IF ns < 0 THEN ns := 0 END;
    IF ns > tot THEN ns := tot END;
    IF tot > 0 THEN weight := VAL(REAL, ns) / VAL(REAL, tot) END;   (* new weight; clamps reapply on Retile *)
    PaneShell.RaiseEvent(host, PaneShell.EvSplitterMoved)
  END Drag;
  OVERRIDE PROCEDURE DropAt (host: PaneShell.Pane; px, py: INTEGER; moved: PaneShell.Pane;
                             VAR zone: PaneShell.DropZone; VAR x, y, w, h: CARDINAL): BOOLEAN;
  BEGIN zone := PaneShell.NoDrop; RETURN FALSE END DropAt;   (* reactive: not a drop target *)
  OVERRIDE PROCEDURE Save (host: PaneShell.Pane; VAR blob: ARRAY OF CHAR): BOOLEAN;
  BEGIN RETURN FALSE END Save;                       (* reactive: recomputed from structure (D1) *)
  OVERRIDE PROCEDURE Load (host: PaneShell.Pane; blob: ARRAY OF CHAR): BOOLEAN;
  BEGIN RETURN FALSE END Load;
END SplitLayout;

(* ---- StackLayout: N children divided equally along an axis, with a gap ---- *)
CLASS StackLayout;
  INHERIT PaneShell.Layout;
  VAR dir: Orientation; gap: CARDINAL;
  OVERRIDE PROCEDURE Arrange (host: PaneShell.Pane; x, y, w, h: CARDINAL);
    VAR n, vis, i, avail, each, off: CARDINAL; ch: PaneShell.Pane;
  BEGIN
    n := PaneShell.ChildCount(host);
    vis := 0; i := 0;
    WHILE i < n DO
      IF NOT PaneShell.IsHidden(PaneShell.Child(host, i)) THEN INC(vis) END; INC(i)
    END;
    IF vis = 0 THEN RETURN END;
    IF dir = Vertical THEN
      avail := h;
      IF vis > 1 THEN
        IF h > (vis-1)*gap THEN avail := h - (vis-1)*gap ELSE avail := 0 END
      END;
      each := avail DIV vis; off := y; i := 0;
      WHILE i < n DO
        ch := PaneShell.Child(host, i);
        IF PaneShell.IsHidden(ch) THEN PaneShell.SetRect(ch, x, y, 0, 0)
        ELSE PaneShell.SetRect(ch, x, off, w, each); off := off + each + gap END;
        INC(i)
      END
    ELSE
      avail := w;
      IF vis > 1 THEN
        IF w > (vis-1)*gap THEN avail := w - (vis-1)*gap ELSE avail := 0 END
      END;
      each := avail DIV vis; off := x; i := 0;
      WHILE i < n DO
        ch := PaneShell.Child(host, i);
        IF PaneShell.IsHidden(ch) THEN PaneShell.SetRect(ch, x, y, 0, 0)
        ELSE PaneShell.SetRect(ch, off, y, each, h); off := off + each + gap END;
        INC(i)
      END
    END
  END Arrange;
  OVERRIDE PROCEDURE HitTest (host: PaneShell.Pane; px, py: INTEGER): CARDINAL;
  BEGIN RETURN MAX(CARDINAL) END HitTest;
  OVERRIDE PROCEDURE Drag (host: PaneShell.Pane; handle: CARDINAL; dx, dy: INTEGER);
  BEGIN END Drag;
  OVERRIDE PROCEDURE DropAt (host: PaneShell.Pane; px, py: INTEGER; moved: PaneShell.Pane;
                             VAR zone: PaneShell.DropZone; VAR x, y, w, h: CARDINAL): BOOLEAN;
  BEGIN zone := PaneShell.NoDrop; RETURN FALSE END DropAt;
  OVERRIDE PROCEDURE Save (host: PaneShell.Pane; VAR blob: ARRAY OF CHAR): BOOLEAN;
  BEGIN RETURN FALSE END Save;
  OVERRIDE PROCEDURE Load (host: PaneShell.Pane; blob: ARRAY OF CHAR): BOOLEAN;
  BEGIN RETURN FALSE END Load;
END StackLayout;

(* ---- TabLayout: fixed author tabs — the active tab's child fills the area below
   a tab strip; the others get a 0-rect. (Distinct from MDI draggable tabs, S11.) ---- *)
CLASS TabLayout;
  INHERIT PaneShell.Layout;
  VAR active, nTabs: CARDINAL; titles: ARRAY [0..MaxTabs-1] OF ARRAY [0..31] OF CHAR;
  OVERRIDE PROCEDURE Arrange (host: PaneShell.Pane; x, y, w, h: CARDINAL);
    VAR n, i, body: CARDINAL; ch: PaneShell.Pane;
  BEGIN
    n := PaneShell.ChildCount(host);
    IF h > TabStripH THEN body := h - TabStripH ELSE body := 0 END;
    i := 0;
    WHILE i < n DO
      ch := PaneShell.Child(host, i);
      IF i = active THEN PaneShell.SetRect(ch, x, y + TabStripH, w, body)
      ELSE PaneShell.SetRect(ch, x, y, 0, 0) END;
      INC(i)
    END
  END Arrange;
  OVERRIDE PROCEDURE HitTest (host: PaneShell.Pane; px, py: INTEGER): CARDINAL;
  BEGIN RETURN MAX(CARDINAL) END HitTest;            (* tab-strip click routing: app/demo *)
  OVERRIDE PROCEDURE Drag (host: PaneShell.Pane; handle: CARDINAL; dx, dy: INTEGER);
  BEGIN END Drag;
  OVERRIDE PROCEDURE DropAt (host: PaneShell.Pane; px, py: INTEGER; moved: PaneShell.Pane;
                             VAR zone: PaneShell.DropZone; VAR x, y, w, h: CARDINAL): BOOLEAN;
  BEGIN zone := PaneShell.NoDrop; RETURN FALSE END DropAt;
  OVERRIDE PROCEDURE Save (host: PaneShell.Pane; VAR blob: ARRAY OF CHAR): BOOLEAN;
  BEGIN RETURN FALSE END Save;
  OVERRIDE PROCEDURE Load (host: PaneShell.Pane; blob: ARRAY OF CHAR): BOOLEAN;
  BEGIN RETURN FALSE END Load;
END TabLayout;

(* ---- builders: attach a strategy to an arrangement Pane ---- *)
PROCEDURE Split (dir: Orientation; weight: REAL; minFirst, minSecond: CARDINAL;
                 first, second: PaneShell.Pane): PaneShell.Pane;
  VAR p: PaneShell.Pane; sl: SplitLayout;
BEGIN
  p := PaneShell.Arrange("split");
  PaneShell.AddChild(p, first); PaneShell.AddChild(p, second);
  NEW(sl); sl.dir := dir; sl.weight := weight; sl.minFirst := minFirst; sl.minSecond := minSecond;
  PaneShell.SetLayout(p, sl);
  RETURN p
END Split;

PROCEDURE NewStack (dir: Orientation; gap: CARDINAL): PaneShell.Pane;
  VAR p: PaneShell.Pane; st: StackLayout;
BEGIN
  p := PaneShell.Arrange("stack");
  NEW(st); st.dir := dir; st.gap := gap;
  PaneShell.SetLayout(p, st);
  RETURN p
END NewStack;

PROCEDURE AddChild (stack, child: PaneShell.Pane);
BEGIN PaneShell.AddChild(stack, child) END AddChild;

(* ---- D1 reactive mutators: mutate the held tree, then the app calls Retile ---- *)
PROCEDURE SetWeight (split: PaneShell.Pane; weight: REAL);
  VAR lay: PaneShell.Layout; sl: SplitLayout;
BEGIN
  lay := PaneShell.LayoutOf(split);
  IF lay # NIL THEN sl := CAST(SplitLayout, lay); sl.weight := weight END
END SetWeight;

PROCEDURE Replace (old, new: PaneShell.Pane);
BEGIN PaneShell.ReplaceChild(old, new) END Replace;

PROCEDURE SetHidden (p: PaneShell.Pane; hidden: BOOLEAN);
BEGIN PaneShell.SetHidden(p, hidden) END SetHidden;

(* ---- fixed author tabs (TabLayout) ---- *)
PROCEDURE NewTabs (): PaneShell.Pane;
  VAR p: PaneShell.Pane; tl: TabLayout;
BEGIN
  p := PaneShell.Arrange("tabs");
  NEW(tl); tl.active := 0; tl.nTabs := 0;
  PaneShell.SetLayout(p, tl);
  RETURN p
END NewTabs;

PROCEDURE AddTab (tabs: PaneShell.Pane; title: ARRAY OF CHAR; child: PaneShell.Pane);
  VAR lay: PaneShell.Layout; tl: TabLayout; i: CARDINAL;
BEGIN
  lay := PaneShell.LayoutOf(tabs);
  IF lay = NIL THEN RETURN END;
  tl := CAST(TabLayout, lay);
  IF tl.nTabs < MaxTabs THEN
    i := 0;
    WHILE (i <= HIGH(title)) AND (i < 31) AND (title[i] # 0C) DO tl.titles[tl.nTabs][i] := title[i]; INC(i) END;
    tl.titles[tl.nTabs][i] := 0C;
    INC(tl.nTabs);
    PaneShell.AddChild(tabs, child)
  END
END AddTab;

PROCEDURE SelectTab (tabs: PaneShell.Pane; index: CARDINAL);
  VAR lay: PaneShell.Layout; tl: TabLayout;
BEGIN
  lay := PaneShell.LayoutOf(tabs);
  IF lay # NIL THEN
    tl := CAST(TabLayout, lay);
    IF index < tl.nTabs THEN tl.active := index; PaneShell.RaiseEvent(tabs, PaneShell.EvTabChanged) END
  END
END SelectTab;

PROCEDURE ActiveTab (tabs: PaneShell.Pane): CARDINAL;
  VAR lay: PaneShell.Layout; tl: TabLayout;
BEGIN
  lay := PaneShell.LayoutOf(tabs);
  IF lay = NIL THEN RETURN 0 END;
  tl := CAST(TabLayout, lay);
  RETURN tl.active
END ActiveTab;

END PaneLayout.
