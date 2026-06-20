# PaneShell — reactive layout + MDI panes for the M2 runtime

**Status:** design (no code yet)
**Date:** 2026-06-17
**Branch:** `conformance-to-90`
**Source of requirements:** the C++ `multiwingui` framework at `e:\multiwingui`
re-imagined for native NewM2.
**Builds on:** the existing M2 GUI stack — `WinShell`, `Terminal`/`TermRender`,
`Canvas2D`, `RasterView`, `GameView`/`GameViewGpu`, `ShaderView`, `Dialogs`,
`Clipboard` — and is consumed first by the `FastM2` IDE.

---

## 1. Two concepts, one substrate

A multi-pane desktop framework is really **two different things**, distinguished by
*who owns the arrangement and how it changes*:

1. **Reactive / declarative layout.** The arrangement is a function of app structure:
   the author describes the window as a tree (splits with weights, tabs, flow boxes);
   the framework owns placement. The *user does not rearrange it* — it changes only when
   the app re-describes it. This is the IDE's chrome: menu + sidebar + editor/console
   split. `layout = f(structure)`.

2. **MDI / dock container management.** The arrangement is mutable, user-driven, and
   *persistent*. A container owns a dynamic set of document/tool panes with identity and
   lifecycle; the app issues imperative commands (open a document, close, activate, tile,
   cascade, float, dock, tab-together) and **the user drags things around**. The layout is
   its own state — you cannot recompute it, so you must save and restore it.

The tell is **mutation**: reactive layout changes by *re-describing*; an MDI container
changes by *commands and drags*, and must be *serialized*.

These are not rival designs to pick between. They sit on **one shared substrate** and
**nest mutually** (§4). `multiwingui` implements only the first kind (§2); the MDI half
is the part it lacks and the part that needs drag + persistence.

---

## 2. What multiwingui is (and isn't)

`multiwingui` is **almost entirely the reactive kind.** Its window is a JSON node tree
`{type, id, props, children}`; the load-bearing container is `split-view` (exactly two
weighted `split-pane`s, `minSize`/`maxSize` clamps) plus `tabs` and flow boxes; you
*"repaint by publishing a new full spec, not by attaching behavior to nodes,"* and the
runtime diffs old→new and patches. Leaves are named surfaces — **text-grid**, **rgba-pane**,
**indexed-graphics** (+ vector/sprite layers) — resolved by id and fed dense binary content
on a fast lane while structure flows on a slow lane.

What it calls "multi-window" is just *reactive interior + several top-level OS windows*
(`create_window`/`close_window`, events keyed by `window_id`). There is **no docking,
floating, drag-to-redock, tile, or cascade** — i.e. none of the classic MDI-container
behaviour. So the brief's word "MDI" oversells it: multiwingui = reactive layout, not an
MDI/dock container. We take its reactive model *and add* the MDI half it never had.

---

## 3. What M2 has today, and the gap

**Key finding: M2 already has *more* render surfaces than multiwingui's three — they cover
every pane kind. The renderers are not the gap.**

| Leaf kind | M2 module(s) today |
|---|---|
| text-grid surface | `Terminal` (cell model, menus, status, fields, events) + `TermRender` (Direct2D) |
| rgba surface | `RasterView` (CPU) / `Canvas2D` (D2D vector+text) / `ShaderView` (D3D11) |
| indexed / sprites | `GameView` (CPU) / `GameViewGpu` (GPU bg + sprite layer) |
| **native controls** | the Win32 common controls (button, edit, listview, treeview, combo, …) — already HWNDs |
| OS window + loop | `WinShell` — `CreateAppWindow`, `RunMessageLoop`/`PumpMessages`, one `MsgProc` |

The gap is everything *around* the surfaces:

1. **Surfaces are module singletons** — each holds one HWND and one buffer in module
   globals and assumes it owns the whole client area (Canvas2D is the exception: it does *not*
   retain the HWND in a global, only the derived D2D render target `gRT` — the hwnd flows into
   `CreateHwndRenderTarget`). **No surface is instantiable**; you
   cannot have two `Canvas2D` panes, or a `Terminal` beside a `RasterView`, in one window.
   This is the load-bearing obstacle.
2. **No layout engine.** The only layout in the tree is FastM2's 11-line `Layout`: five
   hand-computed layout globals (`gCodeW`, `gEdRows`, `gOutRows`, `gOutTitle`, `gOutTop2` — of
   which only `gEdRows`/`gOutTitle`/`gOutTop2` are strict row offsets), a hard-coded 3:1 split.
   No rectangle type, no tree, no splitter system, no tabs.
3. **No pane registry / hit-test routing.** Click→pane is an `IF`-ladder over row globals;
   `WinShell` delivers every message to one global handler.
4. **Single window / single handler** at the OS level. No child HWNDs, no window registry.
5. **No MDI anything** — no container, no docking, no floating, no persistence.

So the work is **instancing + a shared hosting substrate + two facades (reactive, MDI)** —
*not* porting renderers.

---

## 4. The unifying model — `Pane` as the universal currency

The whole design turns on one abstraction:

> A **`Pane`** is a rectangular region backed by a host window. Its *content* is one of:
> 1. a **leaf** — a `Surface.Backend` (a text grid / canvas / raster / indexed / shader, **or a
>    native control** — §6);
> 2. a **reactive arrangement** — a split / tabs / flow over child `Pane`s, placement owned
>    by the layout solver;
> 3. an **MDI container** — a mutable, user-driven, persistable set of child `Pane`s.

Because kinds (2) and (3) both **consume `Pane` children** and **are themselves `Pane`s**,
*any* composition is legal and they nest recursively in **both** directions:

```
reactive ⊃ container   IDE: declarative chrome wrapping a document area
container ⊃ reactive   a document that is itself a split of panes      ← the key case
reactive ⊃ reactive    nested splits / tabs of splits
container ⊃ container   a docked tool-group that is itself an MDI area
leaf                    the recursion bottoms out at a surface or a control
```

### The HWND tree mirrors the Pane tree

Every `Pane` owns a lightweight host window (`WS_CHILD | WS_CLIPCHILDREN`, no background
erase). The window hierarchy *is* the pane hierarchy:

- a **leaf**'s `Surface.Backend` attaches to its host HWND (surfaces unchanged from today);
- an **arrangement**'s child Panes are child HWNDs of its host → Win32 clips them to the
  arrangement's rectangle for free, and routes input/focus to the deepest child;
- moving / hiding / **floating / docking a whole subtree** is one `SetParent` + `MoveWindow`
  on its host HWND — every descendant follows automatically. This is what makes MDI drag,
  float and dock cheap, and what makes "pop a reactive subtree out into a floating window"
  a one-liner.

So the three layers exchange exactly one type — `Pane` — and the OS gives us subtree
relocation, clipping, hit-testing and focus as a side effect of the HWND nesting.

*(Optimization, deferred: a purely structural reactive split need not allocate an
intermediate host HWND. Default to "every Pane = one HWND"; flatten only if HWND count is
ever measured to matter.)*

### Reactive vs. container, side by side

| | Reactive arrangement | MDI container |
|---|---|---|
| Arrangement source | `f(structure)` — the app builds the tree | owned mutable state in the container |
| Changes by | mutating the held tree + `Retile` | imperative ops + **user drag** |
| User can rearrange? | no (author-designed) | yes (drag tabs, dock, float, tile, cascade) |
| Pane lifecycle | declared by the tree | explicit `AddDocument`/`Close`/`Activate`, active-doc, z-order |
| Persistence | none (recomputed from structure) | **must serialize** (arrangement is irreplaceable data) |
| multiwingui has it? | yes (its whole interior) | no |

`tabs` appears in both and must not be confused: reactive `Tabs` is a *fixed, author-declared*
set of views (a property inspector); MDI tabbed documents are *user-opened/closed/reordered/
draggable*. Same pixels, different ownership.

---

## 5. What this buys — Win32 as a declarative runtime

The payoff of §4 is bigger than "an MDI framework." It collapses the **entire Win32 GUI
surface into a declarative model**, and the mechanism is one specific move:

> **The HWND tree becomes a *projection* of the declared `Pane` tree.**

Once the structure you declare and the OS's handle hierarchy are the same object, the
imperative Win32 machinery stops being something you *call* and becomes something that
*emerges* from what you declared:

- **clipping** ← `WS_CLIPCHILDREN` on the nesting you wrote
- **hit-testing + focus** ← Win32 routing input to the deepest child, which is your deepest Pane
- **z-order, subtree move / float / dock** ← one `SetParent` on a node you already named

You declare structure; Win32 supplies the consequences. Three pillars then absorb the whole
Win32 surface:

1. **a declarative tree** → replaces window classes, the MDI client window, hand-rolled
   splitters, dialog templates, all the parent/child wiring;
2. **retained surfaces** (submit state, the runtime re-renders) → replaces the
   `WM_PAINT`/invalidate bookkeeping;
3. **semantic events keyed to panes** (§7) → replaces the `WNDPROC` message switch and
   hand hit-testing.

The message pump, the `WNDPROC`, the HWND lifecycle all sink below the waterline into the
runtime. The **window stops being special**: top-level frame, MDI child, control and dialog
all collapse into one recursive `Pane` — one structure instead of Win32's taxonomy — and the
three render backends (D2D/GDI/D3D) vanish behind the same leaf, the author never knowing which.

### The honest boundary

It is **not** "everything becomes declarative." Two things stay imperative *by necessity*,
and the design's value is that it **isolates exactly those two and still holds each as a node
in the declarative tree**:

- **drawn content** — you cannot declare a Mandelbrot or a cursor blink; pixels/cells are
  retained-imperative (the fast lane, §7);
- **the MDI arrangement** — user-owned, mutable, persistent state; it *literally cannot* be
  `f(app structure)` because the **user**, not the app, authors it (§1).

So the precise claim is stronger than a slogan: **declarative for all *structure*; the
residual imperative surface shrinks to the two things that are irreducibly imperative — and
both are still contained declaratively as Panes.** Conceptually this is the React/SwiftUI
retained-over-imperative move applied to Win32 — but *simpler*, because M2 holds the live
tree (D1), so there is no virtual DOM and no diff.

---

## 6. Surfaces first, controls as the simplest leaf

The defining feature of nearly every real Windows app is a **custom surface**: the editor
(VS Code, FastM2), the canvas (Photoshop, Figma), the grid (Excel), the timeline (a DAW),
the 3-D viewport (CAD, Blender, a game), the document (Word), the waveform. The standard
controls — buttons, edits, list/tree views, combos — *frame* that surface; they are not the
app.

Most frameworks invert this. MFC, WinForms, WPF and Qt are **control-centric**: laying out
standard widgets is easy and custom drawing is the painful escape hatch (owner-draw,
`WM_PAINT` overrides, register-a-custom-control). The thing that *is* the app is the thing
they make hardest. **This design is custom-surface-first**: a leaf is a `Surface.Backend`,
and the native render surfaces are the first-class leaves.

And native controls then fall out as **the simplest possible leaf** — because a Win32 common
control already *is* an HWND that paints itself. A control Backend needs no drawing at all:

| `Backend` method | custom surface | native control |
|---|---|---|
| `Attach(hwnd,…)` | create the renderer's target on the host HWND | create the control HWND as a child |
| `Resize` | resize the target | `MoveWindow` |
| `Paint` | re-render from retained state | **no-op** (the OS draws it) |
| value access | draw via the renderer module | `SetText`/`GetText`/list/selection procs |
| events | pane input → semantic events | `WM_COMMAND`/`WM_NOTIFY` → the same semantic events (§7) |

So controls slot into the **same tree, the same solver, the same event path** with **zero
special-casing** — they were HWNDs all along. The leaf spectrum runs *native control →
custom surface*, one abstraction spanning it, with the surface end primary. That makes this
a **complete** GUI framework: the two leaf families span everything a Windows app contains.

---

## 7. Concurrency — control plane, data plane

Events and content want *opposite* concurrency models, so split them into two planes.

### Control plane — one common event router

Input events, focus changes, z-order, window lifecycle and "which pane is under this click"
are low-volume, **ordered**, and inherently **cross-pane**, so they need a single
serialization point: **one event router on the UI thread**. It is *correct*, not a
bottleneck — it runs at human-input scale. It packages raw Win32 messages into **semantic
events** keyed to a `Pane`, and fans them out to the window `Handler` (and, optionally,
per-pane handlers). This is the §5 pillar 3 that replaces the `WNDPROC` switch.

### Data plane — one fast channel per pane

Pane content is high-volume, and each pane is already an independent ownership domain (its
own surface, buffer, HWND). So each pane gets its **own fast channel**: a typed, lock-free
**single-producer/single-consumer ring** carrying retained-state deltas / finished frame
buffers. One producer, one consumer → no locks, and **content never needs cross-pane
ordering**, so there is nothing to serialize globally.

> This is sharper than multiwingui, which funnels *all* panes through one client→UI command
> queue. **Per-pane channels** remove producer contention and the global content ordering
> entirely.

### Threads live on the channels

A producer thread generates **CPU-side content** (cells, pixels, a draw list, a vertex
buffer) and submits a finished buffer to its pane's channel. It **never touches the HWND or
the GPU device** (Win32/D3D have window + device affinity). Two drain modes share the *same*
channel API:

- **default** — the **UI thread** drains every channel and presents. Device-affinity-safe,
  simplest. This is the single-UI-thread phase.
- **opt-in, per pane (advanced)** — unlocked precisely by *child-HWND-per-pane*: the pane
  owns **its own swapchain + render thread** that drains its own channel and presents to its
  own HWND independently. Full isolation — a stalled or crashed producer cannot stall its
  siblings.

The property that matters: **no head-of-line blocking across panes.** Each pane updates at
its own cadence — compiler output streams into the console as fast as it arrives, the 3-D
viewport holds 60 fps, a chart redraws lazily — because the data plane is decoupled per
pane. A single-threaded immediate-mode model lets the *slowest* pane cap the frame rate;
per-pane channels remove that.

**This vindicates D2.** Content updates are designed as marshalable state-submits and the
channel exists from day one; the framework ships single-threaded (the UI thread drains
channels inline), then producer threads attach later **with no change to the app-facing
API**, because content was always "submit a buffer," never "draw now." So "threads on the
fast channels" is the target architecture and the single-thread phase is just the on-ramp.

The full picture: a declarative `Pane` tree (structure) → one event router (control plane) →
per-pane fast channels with optional producer threads (data plane).

---

## 8. Architecture — three layers, one currency

```
   ┌─────────────────────────┐     ┌──────────────────────────┐
   │  PaneLayout (reactive)   │     │  MDIContainer (MDI/dock)  │   ← FACADES
   │  Split / Tabs / Stack    │     │  AddDocument / Float /    │     (policy)
   │  layout = f(structure)   │     │  Dock / Tile / SaveLayout │
   └────────────┬────────────┘     └─────────────┬────────────┘
                │   both consume & produce PaneShell.Pane   │
                └─────────────────┬───────────────────────┘
                ┌─────────────────▼─────────────────┐
                │   PaneShell  —  SHARED SUBSTRATE   │            ← mechanism
                │   Pane (host HWND) · Workspace ·   │
                │   PaneWindow · event router ·      │
                │   per-pane channels · registry ·   │
                │   rectangle hosting · message loop │
                └─────────────────┬─────────────────┘
                ┌─────────────────▼─────────────────┐
                │   Surface  —  instanced leaves     │            ← pixels
                │   Backend (ABSTRACT CLASS vtable): │
                │   custom surfaces + native controls│
                └────────────────────────────────────┘
```

| Module | Owns | Role |
|---|---|---|
| **`Surface`** | the abstract `Backend` CLASS + adapters wrapping each (now-instanced) renderer **and the native controls** | the pixels of a leaf |
| **`PaneShell`** | the universal `Pane` (host HWND), `Workspace`, `PaneWindow`, the named registry, the **event router** + **per-pane channels**, the message loop | the shared substrate both facades stand on |
| **`PaneLayout`** | reactive `Split`/`Tabs`/`Stack` builders + the rectangle solver | the **reactive** facade |
| **`MDIContainer`** | a container `Pane`: `AddDocument`/`Close`/`Activate`/`Tile`/`Float`/`Dock` + `Save`/`LoadLayout` | the **MDI/dock** facade |

`WinShell` stays the low-level core (`PaneWindow` makes its top window through it). The
two facades never talk to each other; they meet only through `PaneShell.Pane`.

### The layout-strategy hook (extensibility)

`PaneLayout` and `MDIContainer` are not two separate engines — they are two **families of
*layout strategies*** over one interface the substrate drives. An arrangement Pane carries a
`Layout`: a pluggable algorithm that, given the container rectangle and the child Panes,
assigns rectangles (and z-order / visibility), hit-tests its own handles, mutates its
arrangement on a drag, answers drop-target queries for docking, and — if stateful —
serializes itself.

```modula2
TYPE
  DropZone = (NoDrop, DockLeft, DockRight, DockTop, DockBottom, DockCentre, NewFloat);
  Layout = ABSTRACT CLASS                 (* a pluggable arrangement algorithm; lives in PaneShell *)
    PROCEDURE Arrange (host: Pane; x, y, w, h: CARDINAL); ABSTRACT;        (* -> child rects *)
    PROCEDURE HitTest (host: Pane; px, py: INTEGER): CARDINAL; ABSTRACT;   (* divider/tab/handle *)
    PROCEDURE Drag    (host: Pane; handle: CARDINAL; dx, dy: INTEGER); ABSTRACT;
    PROCEDURE DropAt  (host: Pane; px, py: INTEGER; moved: Pane;
                       VAR zone: DropZone; VAR x, y, w, h: CARDINAL): BOOLEAN; ABSTRACT;
    PROCEDURE Save    (host: Pane; VAR blob: ARRAY OF CHAR): BOOLEAN; ABSTRACT;
    PROCEDURE Load    (host: Pane; blob: ARRAY OF CHAR): BOOLEAN; ABSTRACT;
  END;
```

Built-in strategies: `SplitLayout`, `TabLayout`, `StackLayout` (the reactive ones, with
no-op `Save`/`Load`) and `DockLayout` (the MDI/dock one, stateful). `PaneLayout.Split` /
`MDIContainer.Create` are thin builders that attach a strategy to an arrangement Pane. The
substrate's event router delegates every gutter / handle / drag / drop interaction to the
host Pane's `Layout` and never knows the algorithm. **So a new arrangement algorithm —
auto-grid, BSP tiling (i3/sway-style), a constraint solver, masonry, a ribbon — is just a new
`Layout`; nothing in the substrate or the app changes.** That is the hook: ship a reasonable
`DockLayout` now, add algorithms later without rework.

---

### Library placement

The framework lives in a **new library family** `library/uidef` + `library/uimod` (headline
module `PaneShell`; modules `Surface`, `PaneShell`, `PaneLayout`, `MDIContainer` + the built-in
`Layout` strategies). The OS-surface wrappers (`WinShell`, `Terminal`/`TermRender`, `Canvas2D`,
`RasterView`, `GameView`/`GameViewGpu`, `ShaderView`, `DWrite`, `Dialogs`, `Clipboard`, `Com`,
`Dispatch`) **stay in `library/winrtdef` + `library/winrtmod`** and are *instanced in place*
(D4), not moved. The loader auto-discovers any `library/*def` and resolves cross-family imports
by module name — two-pronged, not one flat path: Win32 defs (`WIN32`, `Graphics_Direct2D`)
resolve via an embedded `win32_finder` consulted *before* the filesystem
(`src/newm2-loader/src/loader.rs:293-305`, gated on `library/NewM2` existing with a `*_types.def`
`SearchPath` fallback), while sibling-family modules (`Terminal`, `DWrite`, `Guid`) resolve via
`SearchPath.find_def` (finder-first-then-SearchPath). The net zero-config result holds, so the
new family is zero driver config and the dependency direction stays one-way (`ui` → `winrt`
surfaces → Win32). The showcase/proof app is the rebuilt `FastM2` in
`projects/`. The sprint-by-sprint execution schedule is
[`pane-shell-sprints.md`](pane-shell-sprints.md) (Sprint 0 = placement & scaffolding).

---

## 9. Design decisions (where M2 diverges, and why)

**D1 — The reactive facade is *retained*, not diffed.** multiwingui re-publishes a whole
JSON spec and diffs old→new because it hosts foreign languages across a C ABI and cannot
hold the live tree. Native M2 *holds* the tree: a `Pane` is a live, HWND-backed object, so
"changing the layout" is *mutating the held tree* (`SetWeight`, `Replace`, `SetHidden`) +
`Retile` — there is nothing to diff. The diff/patch machinery, which only earned its keep
across the FFI, is dropped. No per-frame value-tree rebuild, no allocator churn.

**D2 — Single UI thread first; per-pane channels are the seam to threads (§7).** Pane
handlers and channel draining run on the UI thread initially. Because content updates are
state-submits onto per-pane channels, producer threads — and ultimately per-pane render
threads — attach later **without changing the app-facing API**. Design the seam; light up
the threads when there's a measured need.

**D3 — One child HWND per Pane (§4).** Buys clipping, hit-testing, focus and subtree
relocation from Win32; lets D2D / GDI-DIB / D3D11 panes coexist (each owns its own target);
is what makes MDI float/dock cheap *and* what makes per-pane independent present possible
(§7). Cost (seam flicker, HWND count) is mitigated by `WS_CLIPCHILDREN` + no-erase.

**D4 — Instance the surfaces behind a CLASS-as-vtable `Backend`.** The prerequisite
refactor: each renderer gains an instance handle; the substrate drives any leaf
polymorphically (the house COM idiom). Back-compat kept by leaving the singleton procs as
shims over a default instance (§10.1). Native controls are `Backend`s too (§6).

**D5 — Reuse the surfaces and the event vocabulary.** No new renderers; reuse `Terminal`'s
`EventKind`/`Key*` vocabulary, extended with pane/window/splitter/tab/dock events.

**D6 — One `Pane` currency; the two facades nest mutually (§4).** A leaf, a reactive
arrangement and an MDI container are all `Pane`, so they compose recursively in both
directions — the IDE is *reactive chrome around an MDI document area, each document itself a
reactive split*, with no special-case glue between facades.

**D7 — Layout is a pluggable strategy, not a fixed engine (§8).** Every arrangement (reactive
or MDI) delegates placement + interaction to a `Layout` strategy the substrate drives, so new
layout/docking algorithms plug in behind one interface without touching the substrate or the
app. Ship a reasonable `DockLayout`; reserve the seam for the rest. The same "reserve the
hook, ship a sensible default" discipline extends to the genuine frontier — accessibility,
IME, complex-text (§16).

---

## 10. API sketch (M2, house style)

Opaque handles are `ADDRESS` with `NIL` = none; results are `BOOLEAN`/`NIL`-sentinel;
callbacks are named `PROCEDURE` types; lifecycle verbs follow `Create/Attach/…/Destroy`.

### 10.1 `Surface` — instanced leaves: custom surfaces *and* native controls

```modula2
DEFINITION MODULE Surface;
FROM SYSTEM IMPORT ADDRESS;
TYPE
  Kind    = (TextGrid, Raster, Canvas, Indexed, Shader, NativeControl, Custom);
  Backend = ABSTRACT CLASS                       (* CLASS-as-vtable, the house idiom *)
    PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN; ABSTRACT;
    PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN; ABSTRACT;
    PROCEDURE Paint; ABSTRACT;                    (* re-render; a NO-OP for a control *)
    PROCEDURE KindOf (): Kind; ABSTRACT;
    PROCEDURE Close; ABSTRACT;
  END;

(* custom-surface adapters — each wraps an *instance* of an existing renderer *)
PROCEDURE NewTextGrid (cols, rows: CARDINAL; font: ARRAY OF CHAR; pt: REAL): Backend;
PROCEDURE NewRaster   (w, h: CARDINAL): Backend;
PROCEDURE NewCanvas   (): Backend;
PROCEDURE NewIndexed  (w, h, scale: CARDINAL): Backend;
PROCEDURE NewShader   (w, h: CARDINAL): Backend;

(* native-control adapters — the simplest leaves; the OS paints them (§6) *)
PROCEDURE NewButton (label: ARRAY OF CHAR; event: ARRAY OF CHAR): Backend;
PROCEDURE NewEdit   (multiline: BOOLEAN): Backend;
PROCEDURE NewList   (): Backend;
PROCEDURE NewTree   (): Backend;
PROCEDURE NewCombo  (): Backend;
(* control value access (a control Backend has no renderer module to drive) *)
PROCEDURE SetText   (b: Backend; s: ARRAY OF CHAR);
PROCEDURE GetText   (b: Backend; VAR s: ARRAY OF CHAR);
PROCEDURE AddRow    (b: Backend; s: ARRAY OF CHAR);     (* list/combo/tree *)
PROCEDURE Selected  (b: Backend): CARDINAL;
END Surface.
```

Each renderer is made instanced behind this (low-churn path: add `Instance`/`Create`/
`Use`/`Free`, keep singleton procs as shims over a default instance).

### 10.2 `PaneShell` — the shared substrate: `Pane`, windows, the router, channels

```modula2
DEFINITION MODULE PaneShell;
FROM SYSTEM IMPORT ADDRESS;
IMPORT Surface;
TYPE
  Workspace  = ADDRESS;
  PaneWindow = ADDRESS;
  Pane       = ADDRESS;            (* THE currency: leaf | reactive | container *)
  WindowId   = CARDINAL;

  EventKind = (EvNone, EvPaneFocus, EvPaneInput, EvKey, EvChar, EvMouse,
               EvSplitterMoved, EvTabChanged,
               EvDocActivated, EvDocClosed, EvDocFloated, EvDocDocked,  (* MDI *)
               EvControl,                                               (* WM_COMMAND/NOTIFY *)
               EvResize, EvCommand, EvCloseRequest, EvWindowClosed);
  Event = RECORD
    window: WindowId;  pane: Pane;  kind: EventKind;
    key: CARDINAL;  ch: CHAR;  x, y: INTEGER;  command: CARDINAL;  doc: CARDINAL;
  END;
  Handler = PROCEDURE (VAR Event): BOOLEAN;       (* TRUE = consumed; control plane, §7 *)

(* leaf constructor: wrap a surface or control as a Pane (recursion bottoms out here) *)
PROCEDURE LeafPane (id: ARRAY OF CHAR; back: Surface.Backend): Pane;

(* the named-pane bridge — find any Pane by id anywhere in a tree *)
PROCEDURE PaneByName (root: Pane; id: ARRAY OF CHAR): Pane;
PROCEDURE BackendOf  (p: Pane): Surface.Backend;  (* NIL unless p is a leaf *)
PROCEDURE RectOf     (p: Pane; VAR x, y, w, h: CARDINAL);

(* windows + loop *)
PROCEDURE Init       (): Workspace;
PROCEDURE OpenWindow (ws: Workspace; title: ARRAY OF CHAR; w, h: CARDINAL;
                      root: Pane; on: Handler): PaneWindow;
PROCEDURE CloseWindow(VAR win: PaneWindow);
PROCEDURE Retile     (win: PaneWindow);           (* re-solve after any tree mutation *)
PROCEDURE SetRoot    (win: PaneWindow; root: Pane);
PROCEDURE Run        (ws: Workspace);
PROCEDURE Quit       (ws: Workspace);

(* data plane (§7): a pane may opt into its own producer/render thread.
   The content API is unchanged — content ops are the channel's producer side. *)
PROCEDURE SetThreaded (p: Pane; on: BOOLEAN);

(* polled input snapshot (multiwingui's fast sensor lane) for game-loop panes *)
PROCEDURE KeyDown (vk: CARDINAL): BOOLEAN;
PROCEDURE MouseAt (VAR x, y: INTEGER; VAR buttons: CARDINAL);
END PaneShell.
```

### 10.3 `PaneLayout` — the reactive facade (consumes & produces `Pane`)

```modula2
DEFINITION MODULE PaneLayout;
IMPORT PaneShell;
TYPE Orientation = (Horizontal, Vertical);
PROCEDURE Split (dir: Orientation; weight: REAL; minFirst, minSecond: CARDINAL;
                 first, second: PaneShell.Pane): PaneShell.Pane;   (* draggable divider *)
PROCEDURE NewTabs  (): PaneShell.Pane;                              (* fixed, author tabs *)
PROCEDURE AddTab   (tabs: PaneShell.Pane; title: ARRAY OF CHAR; child: PaneShell.Pane);
PROCEDURE NewStack (dir: Orientation; gap: CARDINAL): PaneShell.Pane;
PROCEDURE AddChild (stack, child: PaneShell.Pane);
(* mutate the held tree, then PaneShell.Retile — the "reactive" change path (D1) *)
PROCEDURE SetWeight (split: PaneShell.Pane; weight: REAL);
PROCEDURE Replace   (old, new: PaneShell.Pane);
PROCEDURE SetHidden (p: PaneShell.Pane; hidden: BOOLEAN);
END PaneLayout.
```

### 10.4 `MDIContainer` — the MDI/dock facade (a container *is* a `Pane`)

```modula2
DEFINITION MODULE MDIContainer;
IMPORT PaneShell;
TYPE
  Style = (Tabbed, Tiled, Cascaded);
  Side  = (Left, Right, Top, Bottom, Centre);
PROCEDURE Create (style: Style): PaneShell.Pane;
(* documents are Panes — a document may be a leaf, a reactive split, or a container *)
PROCEDURE AddDocument (c: PaneShell.Pane; title: ARRAY OF CHAR;
                       content: PaneShell.Pane): CARDINAL;          (* -> doc id *)
PROCEDURE CloseDocument (c: PaneShell.Pane; doc: CARDINAL);
PROCEDURE Activate      (c: PaneShell.Pane; doc: CARDINAL);
PROCEDURE ActiveDocument(c: PaneShell.Pane): CARDINAL;
PROCEDURE Tile    (c: PaneShell.Pane);
PROCEDURE Cascade (c: PaneShell.Pane);
PROCEDURE Float   (c: PaneShell.Pane; doc: CARDINAL);              (* pop into a floater *)
PROCEDURE Dock    (c: PaneShell.Pane; doc: CARDINAL; side: Side);
PROCEDURE TabTogether (c: PaneShell.Pane; docA, docB: CARDINAL);
(* persistence — arrangement only, NOT content; the app re-supplies content by id *)
PROCEDURE SaveLayout (c: PaneShell.Pane; VAR blob: ARRAY OF CHAR): BOOLEAN;
PROCEDURE LoadLayout (c: PaneShell.Pane; blob: ARRAY OF CHAR; supply: PaneShell.Pane): BOOLEAN;
END MDIContainer.
```

---

## 11. Hard problems → solutions

| Problem | Solution |
|---|---|
| Two `Canvas2D`/`Terminal` panes can't coexist | **D4** — instance handles; substrate holds `Backend` refs; singleton procs become shims |
| Mixed D2D/GDI/D3D in one window | **D3** — one child HWND per Pane; each backend owns its target on its HWND |
| Native controls beside custom surfaces | **§6** — a control is a `Backend` whose `Paint` is a no-op; the OS draws it |
| "Which pane owns this click / has focus?" | **D3/§7** — Win32 routes to the child HWND; the event router emits a semantic event |
| Reactive resize / splitter drag | `PaneLayout` solver: tree → rects; gutter hit-test → `SetWeight` + `Retile` → `MoveWindow` |
| **Move / float / dock a whole subtree** | **§4** — `SetParent` + `MoveWindow` the subtree's host HWND; descendants follow |
| MDI document lifecycle, active-doc, z-order | `MDIContainer` owns the live set + arrangement; raises `EvDoc*` events |
| **Persisting a user arrangement** | `MDIContainer.Save/LoadLayout` — arrangement only; app re-supplies content by id (§1) |
| Reactive ⊂ MDI and MDI ⊂ reactive | **D6** — one `Pane` currency; `AddDocument`/`Split` both take any `Pane` |
| **Slow pane caps the frame rate** | **§7** — per-pane channels; no head-of-line blocking; each pane runs at its own cadence |
| Producer thread touching the device | **§7** — producers make CPU-side buffers; the present stays on the channel's consumer |
| Repaint after resize/expose | surfaces are retained; the consumer replays `Backend.Paint` from the channel |
| Seam flicker | `WS_CLIPCHILDREN` on hosts; panes don't erase background; parents paint only gutters |

---

## 12. Concept mapping (multiwingui ↔ M2)

| multiwingui | M2 |
|---|---|
| JSON spec, `publish`/`patch`/diff | `PaneLayout` live retained tree, mutate + `Retile` (D1) |
| `split-view` + two weighted `split-pane` | `PaneLayout.Split(dir, weight, minFirst, minSecond, …)` |
| `tabs` (fixed) | `PaneLayout.NewTabs`/`AddTab` |
| `resolve_pane_id(node_id)` / `get_pane_layout` | `PaneByName` / `RectOf` |
| text-grid / rgba / indexed pane | `Surface.NewTextGrid` / `NewRaster`·`NewCanvas`·`NewShader` / `NewIndexed` |
| native controls "as declarative chrome" | **first-class leaf `Backend`s** — `Surface.NewButton/NewEdit/NewList/…` (§6) |
| `SuperTerminalEvent` (typed, `window_id`) | `PaneShell.Event` via the one event router (control plane, §7) |
| **one client→UI command queue (all panes)** | **per-pane lock-free SPSC channels** — no contention, no global ordering (§7) |
| `create_window` / `close_window` | `OpenWindow` / `CloseWindow` |
| UI + client threads, 2 queues | one UI thread + per-pane channels; producer/render threads opt-in per pane (D2/§7) |
| **(absent — docking/float/tile/persistence)** | **`MDIContainer` — the half multiwingui lacks (§2)** |

---

## 13. Worked examples

### 13a. Simple reactive — canvas + console, split 70/30

```modula2
left  := PaneShell.LeafPane("canvas",  Surface.NewCanvas());
right := PaneShell.LeafPane("console", Surface.NewTextGrid(40, 25, "Cascadia Mono", 12.0));
root  := PaneLayout.Split(PaneLayout.Horizontal, 0.70, 240, 160, left, right);
win   := PaneShell.OpenWindow(ws, "Two-Pane", 1000, 640, root, OnEvent);
```

### 13b. The full nesting — reactive chrome ⊃ MDI documents ⊃ a reactive document

An IDE: a declarative outer layout (a file-tree sidebar beside the editor area), whose
editor area is an **MDI container** of documents, and one document is itself a **reactive
split** (source over its own output). All three facades, mutually nested, one `Pane`
currency, plus native-control chrome and a threaded producer pane:

```modula2
(* --- an MDI document that is itself a reactive split (container ⊃ reactive) --- *)
src  := PaneShell.LeafPane("src",  Surface.NewTextGrid(80, 40, "Cascadia Mono", 12.0));
out  := PaneShell.LeafPane("out",  Surface.NewTextGrid(80, 12, "Cascadia Mono", 12.0));
PaneShell.SetThreaded(out, TRUE);              (* compiler thread streams into this pane (§7) *)
doc1 := PaneLayout.Split(PaneLayout.Vertical, 0.75, 200, 80, src, out);

(* --- the MDI document area (container ⊃ reactive + a plain leaf) --- *)
docs := MDIContainer.Create(MDIContainer.Tabbed);
d1   := MDIContainer.AddDocument(docs, "hello.mod", doc1);
d2   := MDIContainer.AddDocument(docs, "README", PaneShell.LeafPane("readme", Surface.NewCanvas()));

(* --- reactive chrome wrapping the MDI area (reactive ⊃ container); sidebar is a control --- *)
tree := PaneShell.LeafPane("files", Surface.NewTree());      (* a native control leaf (§6) *)
root := PaneLayout.Split(PaneLayout.Horizontal, 0.22, 160, 400, tree, docs);

win  := PaneShell.OpenWindow(ws, "FastM2", 1280, 800, root, OnEvent);
```

The user can drag `hello.mod` out to float it; `MDIContainer.Float(docs, d1)` reparents that
whole reactive-split subtree into a floating window with one `SetParent`. The sidebar and the
split ratios are author-owned (reactive); the document set and its arrangement are user-owned
and saved via `MDIContainer.SaveLayout`. The `out` pane's compiler output arrives on its own
channel without stalling the editor.

---

## 14. Phased plan

Ordered so each phase is independently testable and the existing stack never breaks.

- **P1 — Instance the surfaces (D4).** `Instance`/`Create`/`Use`/`Free` on `Canvas2D`,
  `RasterView`, `Terminal`/`TermRender`, `GameView`, `ShaderView`; singleton procs become
  shims. *Outcome:* two instances coexist; all current demos + FastM2 still compile. (Biggest
  risk — first, proven headlessly.)
- **P2 — `Surface.Backend` CLASS + adapters, including native controls.** One polymorphic
  handle drives any custom surface; the control Backends (§6) land here too.
- **P3 — `PaneShell` substrate.** `Pane` (host HWND), `Workspace`, `PaneWindow` over
  `WinShell`, the registry, the **event router**, and the **per-pane channel drained inline by
  the UI thread** (single-threaded, but the channel seam is present). Leaf panes only.
- **P4 — `PaneLayout` reactive facade.** Solver for `Split`/`Stack` (unit-test
  `RectOf`/`Retile` headlessly), `MoveWindow` on resize, splitter drag, fixed tabs.
  *Outcome:* ex. 13a runs, draggable.
- **P5 — Multiple top-level windows.** `OpenWindow`/`CloseWindow` at runtime; one loop over
  the `WindowId` table; per-window registries.
- **P6 — `MDIContainer` facade = the `DockLayout` strategy (D7).** A container `Pane`;
  `AddDocument`/`Close`/`Activate`, tabbed strip, drag-reorder, `Float`/`Dock`/`Tile`/`Cascade`,
  then `Save`/`LoadLayout`. Ships the "reasonable docking" set (§16-resolved); mutual nesting
  (ex. 13b) works the moment this lands. The `Layout` interface (D7) is introduced here so the
  reactive strategies (`SplitLayout`/`TabLayout`/`StackLayout`, retro-fitted from P4) and
  `DockLayout` share one seam.
- **P7 — Rebuild FastM2 on PaneShell (proof of use).** Chrome → reactive; editor area → an
  `MDIContainer` of editor documents (delivers FastM2's "Not yet: **Multiple files/tabs**");
  editor/output split → a reactive `Split`.
- **P8 (deferred) — producer / per-pane render threads + single-surface compositor.** Light
  up `SetThreaded` panes (§7) and, if profiling justifies it, a shared-surface compositor —
  no app-API change (D2).
- **Reserved-hook backlog (no fixed phase) — the honest frontier (§16):** per-`Backend` UIA
  accessibility providers; the IME message path to the focused pane; a DirectWrite-shaped rich/
  complex-text `Backend`; further `Layout` strategies (BSP/grid/constraint). Each is a hook the
  design already accommodates, lit up when an app needs it.

---

## 15. FastM2 is the proof-of-use

FastM2 today is the single-window, fake-paned app this framework is for. The split is clean:
its **chrome** (menu, status, sidebar, the fixed editor/output divider) is *reactive*; its
**documents** (the "Multiple files/tabs" listed under "Not yet" — that text lives in
`projects/FastM2/DESIGN.md` and `README.md`, not in `FastM2.mod`) are an *MDI container*; and
its compile/run output is the natural first **threaded producer pane** (§7) — the compiler
runs off-thread and streams into the output pane's channel. Porting it (P7) exercises all of
it — the role `demo_multi_window.cpp` plays for multiwingui.

---

## 16. Ambition and the honest frontier

The point of this design is a thesis: **a native OS is more than capable of complex, modern,
dynamic, high-performance applications — and a good systems language can express them
cleanly.** Every heavyweight desktop app — Office, Photoshop, Visual Studio, every DAW, CAD
tool, video editor and game — is *already* native Win32 + D3D/D2D. The OS was never the limit.
Developers reach for the web stack for **ergonomics and reach, not capability**, paying a steep
performance/memory tax for declarative convenience. This framework's bet is to **keep native
performance and add the declarative ergonomics** (§5) — closing the gap that sends people to
Electron — with M2 (direct Win32/COM/D3D FFI, CLASS-as-vtable, AOT, no GC pause) as a language
well-suited to expressing *and shipping* these abstractions. The claim worth proving:
**essentially no modern application — short of a web browser itself — cannot be built on this.**

To keep that claim *honest* rather than a slogan, name the real frontier — and note that in
every case **the OS is capable; the work is to reserve and wire a hook**, the same discipline
as the layout strategies (D7):

- **Accessibility (UI Automation).** Native-control leaves are accessible for free; a custom
  surface — the app's *main feature* (§6) — is opaque to screen readers until it exposes a UIA
  provider. Reserve a per-`Backend` accessibility seam; it is required for enterprise/gov apps.
- **IME / complex text input.** CJK composition and dead-keys into a custom text surface need
  `WM_IME_*` handling and composition-window placement. Native edits get it free; a text
  `Backend` wires it; the event router reserves the IME path to the focused pane.
- **Complex-script & rich text.** The text-grid leaf is monospace/code; bidi, Arabic/Indic
  shaping, emoji and proportional rich text use a DirectWrite-shaped `Backend` (DWrite is
  already wrapped) — a `Backend` kind, not a wall.
- **Scope, not capability.** This is Windows-only by design (the web's cross-OS reach is a
  different axis), and the browser is exempted (a rendering engine is a multi-thousand-engineer
  effort in its own right).

So the frontier is a short list of *reserved hooks*, not missing capability — which is exactly
what makes "anything but a browser" a defensible engineering goal rather than a boast, and why
the hook discipline (D7) is the load-bearing design value, not the choice of any one algorithm.

---

## 17. Open questions (resolve during implementation)

1. **Instancing strategy** — current-instance + `Use` (low churn) vs. explicit
   instance-first-arg per renderer proc; the `Backend` adapter hides either. Lean `Use` for P1.
2. **Does every arrangement need a host HWND**, or flatten pure structural splits? (§4) —
   default uniform "Pane = HWND"; flatten only as a measured optimization.
3. **Docking — DECIDED: ship a "reasonable" `DockLayout` now; extend via the strategy hook
   (D7).** First cut: dock tool panes to a region's four edges + centre (tabbed); tabbed
   groups; float a pane/group into a top-level window and redock; drag-to-redock with a
   drop-zone highlight; edge-drop splits a region; resizable splitters; save/restore the dock
   tree. Deferred *behind the hook* (not the substrate): auto-hide/pin fly-outs, custom tiling
   (BSP/grid), multi-monitor dock guides. The recursion (§4) already lets a floating window
   hold its own dock tree.
4. **`SaveLayout` format** — compact M2-native blob vs. text; either way it stores
   arrangement, not content (§10.4).
5. **Control value API** — generic `Surface.SetText`/`AddRow`/`Selected` over a `Backend`
   vs. typed control subclasses the app downcasts to. Generic is simplest; revisit for rich
   controls (listview columns, tree nodes).
6. **Channel granularity** — whole-frame buffers vs. retained-state deltas per pane kind
   (text cells vs. pixel rects vs. draw lists); pick per Backend (§7).
7. **When (if ever)** to light up producer threads / the compositor (D2/§7) — gate on a
   measured need.
```

---

## Audit amendments (2026-06-18)

Findings from a codebase-grounding + design-soundness audit; each item names the section/decision it amends.

**A. DWrite shared-singleton hazard (amends §3.0 DAG; blocks S2).** DWrite is a hard module
singleton (one `gFactory`, no `Instance`/`Create`/`Use`) used by **both** `Canvas2D` and
`TermRender`, and `DWrite.Startup` unconditionally reassigns `gFactory` each call (leaking the
prior factory). DWrite must enter the instancing DAG as a **shared-state node**: before/at S2 it
is either made idempotent (guard `Startup` with a `Ready()` check) or kept singleton-by-design
with only the per-call `CreateFormat` result held **per instance**. This is a real instancing
blocker the published DAG (§3.0 of the plan) omits.

**B. Keyboard focus / accelerators / mnemonics are NOT free (amends §4/§5 "for free"; adds a §16
frontier item; in-scope at S7).** Child-HWND nesting gives clipping + mouse hit-test for free,
but **not** tab traversal, accelerator routing, or mnemonics — those are manual and get
*harder* with a deep tree. The event router must run `TranslateAccelerator` + an
`IsDialogMessage`-equivalent **before** `DispatchMessage`; the `Layout` ABSTRACT CLASS (D7/§8)
gains a `FocusOrder(host)` contract (SplitLayout L-to-R, TabLayout active-only, DockLayout
active-doc-first); the substrate owns **logical focus** (which `Pane`) distinct from Win32 focus
(which HWND), setting `WS_TABSTOP` on focusable leaves and calling `SetFocus` on traversal. §5's
"Win32 supplies the consequences" is softened to **exclude focus**. Add "keyboard focus
traversal + accelerators" as a named §16 frontier item.

**C. Concurrency memory model + threaded-pane ownership (amends §7/D2/P8).** The "lock-free
SPSC ring" has **no memory-model foundation** in M2 today (no `volatile`, no atomics, no
fence/CompilerBarrier; full LLVM optimizer): x86 TSO gives hardware ordering, but the compiler
can still reorder/elide the index/buffer stores. Ship the channel as a **CRITICAL_SECTION-bounded
SPSC** (the `Threads` lock already exists) behind the **same API** now; reserve true lock-free as
a *measured* optimization that first requires `AtomicLoad`/`StoreAcquire`/`Release` + a
`CompilerBarrier` primitive — and stop calling it "lock-free" in the substrate until then.
Retained-surface state must be **single-threaded-owned per pane**: for a THREADED pane,
`Resize`/`Paint` must be **marshaled to the producer** (the UI thread calling
`Backend.Resize`/`Paint` directly is safe only for inline panes). Separate the two D2 claims:
"the app content-submission API is identical inline vs threaded" (**true, defensible**) from
"nothing changes when threads light up" (**false**). Make the "current instance" (`Use`) model
**thread-local**, or require the explicit-instance form off the UI thread.

**D. DPI + coordinate space + Float mechanics (amends §4/D3; S7/S12).** The design has no DPI
story; D2D/DWrite targets are DPI-sensitive. Declare **Per-Monitor-V2**, handle `WM_DPICHANGED`
at the `PaneWindow` level, add a per-`Backend` `Rescale`/`SetDpi` seam. Layout coordinate
convention: store splitter **ratios** + logical-DIP sizes, **never device pixels**; record the
target-monitor identity for floaters; add a DPI/scale parameter the solver reads. Re-spec
`Float` as: create a new `WS_POPUP`/`OVERLAPPED` frame, switch the subtree root's style
(`WS_CHILD` ↔ `WS_POPUP`) + `SetWindowPos SWP_FRAMECHANGED`, reparent, `MoveWindow` — **not a
one-liner** (§4); `Dock` is the reverse. Make drag/drop a **workspace-level (cross-window)**
session, not a per-host `DropAt`, even if the first cut is same-monitor only.

**E. D7 `Layout` interface needs a Measure protocol (amends D7/§8).**
`Arrange`/`HitTest`/`Drag`/`DropAt`/`Save`/`Load` is one-shot top-down rect assignment; it fits
split/tab/stack/dock/BSP, but constraint-solver/masonry/ribbon/intrinsic-flow layouts need a
**bidirectional measure** (query a child's content-derived size; two-pass measure/arrange) —
that is a `Surface.Backend` + substrate change, contradicting "nothing in the substrate changes"
(§8). Add an **intrinsic-size query** to `Surface.Backend` now (leaves may return a fixed hint)
and a two-phase **Measure/Arrange**; replace `ARRAY OF CHAR` `Save`/`Load` with a **growable
byte-sink + explicit version field**. Demote "any of these is just a new `Layout`" accordingly.

**F. §16 capability-vs-effort reframe.** Keep "the OS is capable", but state that IME,
complex-text, and per-`Backend` UIA are each **multi-quarter subsystems**, not wiring: IME needs
a composition state machine + caret-rect reporting in the `Backend`; complex-text needs a
bidi/shaping/caret/selection layout engine over DWrite; UIA for text needs
`ITextProvider`/`ITextRangeProvider`. A fully accessible + international custom text `Backend` is,
by the doc's own words, "close to half a browser". De-risk the FastM2 editor: **ship it on the
native multiline `EDIT`/`RichEdit` control Backend first** (free IME + basic a11y, per the §6
"controls are the simplest leaf" insight), and treat the custom DWrite editor as the explicit
later milestone — or scope the first custom text `Backend` to **LTR-monospace-code** and label
that limit.

**G. HWND budget + flatten-by-default (amends Q17.2/§4).** Name the ceiling: **~10k USER
objects/process** (desktop-heap pressure earlier). **Flip the default**: flatten pure-structural
arrangement nodes (splits/stacks that only place children + draw gutters) so they do **not**
allocate a host HWND — only leaves and interaction-bearing containers (tabs/dock/MDI/float
boundaries) get HWNDs; this keeps HWND count ≈ leaf count and cuts resize-message churn/flicker.
Batch relayout via `BeginDeferWindowPos`/`EndDeferWindowPos`. Keep "one HWND per leaf" as the
invariant that buys the §7 per-pane present. Treat **flatten as a default in S8**, not a P8
deferral (reversing the §4 optimization note + Q17.2).

**H. Save/Load versioning + missing-id policy (amends §1/§10.4/Q17.4).** The Save blob is
long-lived user data: prefix a **magic + version byte** and define `LoadLayout` behaviour for an
unknown version (reject vs best-effort). Define the **missing-content-id** restore path (when a
saved id is no longer supplied by the app): **skip the leaf and let the parent rebalance**, and
**emit an event**. Specify both **before S12 freezes the format** (Q17.4).
