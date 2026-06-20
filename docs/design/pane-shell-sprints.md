# PaneShell — implementation sprint plan

**Status:** sprint plan (Sprint 0 ready to execute)
**Date:** 2026-06-17
**Branch:** `conformance-to-90`
**Design doc:** [`pane-shell-mdi.md`](pane-shell-mdi.md) — read it first; this document is the
execution schedule for the phases in its §14 and the invariants D1–D7 in its §9.
**Showcase / proof-of-use:** the rebuilt `FastM2` IDE (`projects/FastM2`), per §15.

---

## 0. Preamble

### 0.1 Purpose

`pane-shell-mdi.md` is the *design*: the `Pane`-as-universal-currency model (§4), the
control-plane / data-plane split (§7), the three-layer architecture (§8), the seven design
decisions D1–D7 (§9) and the eight phases P1–P8 + reserved backlog (§14). This document turns
that design into a **numbered, dependency-ordered, individually-shippable sprint schedule**,
each sprint with concrete and verifiable exit criteria, so the work can be picked up one
sprint at a time without re-reading the whole design each time.

The framework lives in a **new** library family `library/uidef` + `library/uimod` (headline
module `PaneShell`); the OS-surface wrappers stay in `library/winrtdef` + `library/winrtmod`
and are **instanced in place, not moved** (the placement decision, repeated in §1 below). The
proof app is `projects/FastM2`.

### 0.2 Sprint-numbering convention

- **Sprint N** — `S0`, `S1`, … sequential. `S0` is placement + scaffolding (no behaviour);
  `S1..S13` are implementation; the final sprint is the showcase.
- Big design phases are **split** into right-sized sprints (e.g. P1 "instance the surfaces"
  becomes five sprints S1–S5, one per surface family **derived from the real inter-surface
  import DAG** — see §3.0, because it touches six renderers across three render backends, one
  of which is layered on another). Each sprint states **which design phase (P1..P8) it maps
  to** and **which §17 open question(s) it resolves**. A Sprint→phase table is in §5 below.
- A sprint is a **vertical slice that compiles and is gated** — never a half-built module left
  red between sprints. The new family must compile after **every** sprint (D-o-D below).
- Test ids continue the **group 90** GUI/winrt sequence. The next free slot after the existing
  `t-90-252` block is **`t-90-260`**, reserved here for PaneShell; subsequent sprints take
  `t-90-261`, `t-90-262`, … in order.

### 0.3 Definition of Done — per sprint (the gate every sprint must pass)

A sprint is **Done** only when **all** of these hold:

1. **Compiles JIT, and AOT where applicable.** Every new/changed `*def`/`*mod` pair builds.
   Headless model/router logic ships a **CI** JIT test (`check()`); any module holding a large
   static surface buffer, or any genuinely-windowed deliverable, is proven with `newm2 build`
   → `.exe` (the 4 MiB-per-module JIT reservation, `jit_mm.rs` `MODULE_RESERVE`, forces AOT
   there — see §0.4 and §0.5). The **baseline in-scope conformance count is `1024/1220`**
   (the active 95% mission); every sprint records that it is **unchanged** so any regression is
   falsifiable.
2. **Back-compat preserved — *and re-verified at runtime*, not just recompiled.** Every
   existing `winrt` demo in `demos/` and `projects/FastM2` still builds **unchanged**, *and*
   the existing per-surface winrt test for any surface a sprint touches is **re-run green**
   (`t-90-244` Terminal, `t-90-246` TermRender, etc.) — because building proves the shim
   *links*, not that it preserves singleton *behaviour* (D4). The instancing sprints (S1–S5)
   keep the singleton procs working as shims over a default instance (D4); each pins the
   specific demo(s) that exercise *that* surface's shim path (§3, per-sprint exit criteria), so
   no shim regression hides behind another surface's close-out sweep.
3. **A CI-enforced headless JIT test gates the model layer; AOT demos are MANUAL.** See the
   gate-tier rule in §0.5. *Every* sprint — including the windowed ones — carries at least one
   genuinely-headless `t-90-NNN` JIT assertion of its model/solver/router/serialization layer
   that runs in `cargo test -p newm2-tests`. The runnable AOT `.exe` demos are driven **by
   hand**, are **excluded from `cargo test`** (the harness is JIT-only — §0.5), and are **not**
   regression-protected between sprints; the sprint marks them `(MANUAL)`.
4. **No regression to the `gm2` conformance gate.** `cargo test -p newm2-tests` stays green;
   the in-scope conformance count (baseline `1024/1220`) does not drop. The new family is
   additive — it must not perturb the conformance corpus.

### 0.4 Grounded harness facts the sprints rely on (authoritative)

Line numbers below are **approximate, at time of writing**; the **function / const name** is
authoritative (the files drift across thirteen sprints).

- **Zero-config discovery.** The driver's `push_library_def_dirs`
  (`src/newm2-driver/src/main.rs`, ~L430) adds every `library/*def` subdir (name ends in
  `def`) plus `NewM2` to the `SearchPath`; `uidef` matches automatically. The loader's
  `SearchPath::find_impl_for_def` (`src/newm2-loader/src/search_path.rs`, ~L52) rewrites
  `uidef/Foo.def` → `uimod/Foo.mod` generically. **No driver/loader/test registration for the
  new family.** The test harness mirrors this (`tests/newm2-tests/src/lib.rs`,
  `push_library_def_dirs` ~L267; `locate_library_root` ~L250).
- **Cross-family IMPORT by name.** `uimod/PaneShell.mod` may `IMPORT WinShell` /
  `Terminal` / `TermRender` / `DWrite` / Win32 defs from `winrtmod` / `NewM2` with zero
  wiring, exactly as `winrtmod/TermRender.mod` already imports `Graphics_Direct2D`, `WIN32`,
  `Guid`, `Terminal`, `DWrite`. Resolution is **two-pronged**, not a single flat path: the
  **Win32 defs** (`WIN32`, `Graphics_Direct2D`) resolve via the embedded `win32_finder`,
  consulted **before** the filesystem (`src/newm2-loader/src/loader.rs:293-305`), while the
  **sibling-family** modules (`Terminal`, `DWrite`, `Guid`) resolve via `SearchPath.find_def`.
  The finder is gated on `library/NewM2` existing, with a `*_types.def` `SearchPath` fallback.
  Net result is still zero-config — the mechanism is **finder-first-then-SearchPath**.
- **`<*GUI*>` pragma → `/SUBSYSTEM:WINDOWS`** on the **entry** module only
  (`entry_has_gui_pragma`, `main.rs` ~L1355); a library carrying it does **not** flip the
  program. So `uimod` modules do **not** carry the pragma; only the entry app does.
- **The 4 MiB reservation is per-module across ALL sections, not per-buffer.**
  `src/newm2-llvm/src/jit_mm.rs` `MODULE_RESERVE = 4 MiB` is the **total** per-module JIT
  reservation covering `.text` + `.xdata` + `.pdata` + data + `.bss`. **Precision note:** the
  `IMAGE_REL_AMD64_ADDR32NB` relocations in `.pdata` reference `.text`/`.xdata` as 32-bit
  (`u32` RVA) offsets, so the *relocation* constraint is only that **all sections sit within a
  single 4 GiB RVA window** — the 4 MiB figure is a **pragmatic per-module budget** (the code
  comment marks it explicitly revisitable), **not** a relocation-mandated number. The
  heap-off-globals mandate below stands regardless of where that budget lands. A module with a
  large
  code body plus a *moderate* static buffer can exhaust the reservation before any single
  buffer reaches 4 MiB. **Mandate:** keep **all** large static state (cell grids, RGBA
  framebuffers, sprite layers) **off module globals** — heap-allocate it per instance
  (`Storage`/`Heap`) — so the framework/surface modules stay JIT-loadable regardless of code
  size. (Verified scale check: `Terminal`'s current grid is `gChar`/`gFg`/`gBg` =
  `ARRAY[0..69],[0..219]` ≈ 15 400 cells — already well *under* 4 MiB even as a global; the
  real budget pressure is the **RGBA/indexed framebuffers** of S2/S3/S4 and the per-instance
  *multiplication*, so the heap mandate is about *correctness/coexistence and total-section
  headroom*, not a current text-grid overflow.)
- **House gotchas that bite this work:** `SHORTREAL` (= `REAL32`) for every D2D/DWrite
  `FLOAT`/`COLOR_F`/`RECT_F` field — `REAL` is 64-bit; Win32 `BOOL` is 32-bit, convert at the
  FFI seam, keep the framework API `BOOLEAN`; a virtual COM method returns the HRESULT in EAX
  (test with `SUCCEEDED`/`FAILED`, not a 64-bit sign check); pass `NIL` not `0` to pointer FFI
  args; `SET`/`BITSET` is always 256-bit (do not overlay a Win32 flags `DWORD` — use
  `CARDINAL` + `BAND`/`BOR`); `CAST(<record>, 0/NIL)` panics in codegen (assign the handle
  field directly).
- **The `ABSTRACT CLASS` / CLASS-in-DEF shape (verified by compilation — do not get this
  wrong).** A class is a **standalone top-level declaration**, never `TYPE Name = ABSTRACT
  CLASS`; the abstract qualifier is a **prefix** on each method (`ABSTRACT PROCEDURE Foo…`),
  not a suffix; the class closes with the **named** `END <ClassName>;`; and a class exported
  from a `.def` must be **re-declared verbatim** in the matching `.mod` or sema fails with
  `definition exports 'X' but implementation does not declare it`. Precedent (verified):
  the only real `ABSTRACT CLASS` (IDispatch, 7 methods) lives in
  `library/winrtmod/Dispatch.mod` — a **`.mod`**, i.e. *internal*, never exported in any `.def`
  (no `.def` in the repo declares an `ABSTRACT CLASS` as real code), so it proves the
  abstract-class *shape* but **not** the DEF-export contract. The DEF-export contract (a class
  re-declared verbatim in **both** `.def` and `.mod`) is proven by the **non-abstract**
  `CLASS C;` in `library/comlibdef/ClassFactory.def:25` + `library/comlibmod/ClassFactory.mod:24`
  — note `ClassFactory` is legacy StonyBrook-style, so copy its *contract*, not its style. The
  shape guidance above was independently compiled + run; the exact correct skeleton is in §2.1.
- Every module ends with `END <Name>.` (trailing period); the `.def` basename == module name;
  every `.def`/`.mod` carries `FROM SYSTEM IMPORT ADDRESS;` (and any cross-family `IMPORT`)
  that its signatures reference, or you get `unknown type 'ADDRESS'`.

### 0.5 Gate-tier legend (read once; applied per sprint)

The test harness (`tests/newm2-tests/src/lib.rs`) runs **everything under JIT** (`aot: false`)
and has **no build-exe helper** — so every AOT `.exe` is manual and invisible to `cargo test`.
Two tiers, never conflated:

- **(CI)** — a `t-90-NNN` JIT test registered with `check(...)`/`check_run_error(...)` in
  `tests/newm2-tests/tests/m2_tests.rs`. Runs in `cargo test -p newm2-tests`, regression-
  protected between sprints. **Every sprint must have at least one.**
- **(MANUAL)** — a windowed AOT demo `.exe` (`newm2 build …`) driven by hand. **Excluded from
  `cargo test`; not regression-protected.** Used only where the deliverable physically needs a
  real on-screen window/swapchain (see §0.6).

**Surface JIT/AOT boundary (grounded in the code, not assumed):**

| What | Tier | Why (verified) |
|---|---|---|
| factory / format / device-less object creation; CPU cell/pixel **model** read-back; `Free` | **(CI) headless JIT** | `t-90-245` proves the **DWrite** factory + monospace text format headlessly (DWrite-only); `t-90-246` (TermRender) proves the **D2D** factory; CPU buffers have no window |
| message-only `HWND_MESSAGE` window + synthesized `SendMessage` → WNDPROC | **(CI) headless JIT** | `t-90-243` proves a message-only window drives a WNDPROC synchronously |
| `Canvas2D.Attach` (`ID2D1HwndRenderTarget`), `ShaderView`/`GameViewGpu` `Attach` (`D3D11CreateDeviceAndSwapChain` with `scd.outputWindow := hwnd`), any real `Paint` | **(MANUAL) AOT only** | D2D `HwndRenderTarget` and DXGI swapchains **reject** `HWND_MESSAGE`; `t-90-246`'s own header pushes real-window painting to the interactive demo — there is **no** headless-safe swapchain path |

So **no sprint may claim a headless JIT gate for `Attach`/`Paint` on a Canvas/Shader/IndexedGpu
surface.** Those are split (§0.6).

### 0.6 The two-tier exit gate every instancing/windowed sprint uses

Each surface-instancing sprint (S1–S5) and each windowed sprint (S7–S13) splits its exit gate:

- **(CI) headless JIT** — exercises only what the code supports without a real window:
  *construct* the instance down to factory/format/CPU-buffer level, **read back the per-instance
  model** through an explicit accessor (see the per-instance read-accessor deliverable in each
  instancing sprint), and `Free`. **No `Attach`/`Paint` on D2D/D3D surfaces.**
- **(MANUAL) AOT demo** — does the real `Attach` + *two instances coexist on real targets* +
  `Paint`, marked `(MANUAL, not in cargo test)`.

For the **CPU** surfaces (`RasterView`, `GameView`) the framebuffer/index read-back genuinely
*is* headless, so their coexistence read-back is **(CI)**. For the **D2D/D3D** surfaces
(`Canvas2D`, `ShaderView`, `GameViewGpu`) only *construction + `KindOf` + `Close`* is **(CI)**;
"two instances coexist on real targets" is **(MANUAL)**.

---

## 1. Placement decision (restated — Sprint 0 must execute exactly this)

- **NEW family:** `library/uidef` + `library/uimod`. Headline `PaneShell`. Framework modules
  `Surface`, `PaneShell`, `PaneLayout`, `MDIContainer` (+ built-in `Layout` strategies
  `SplitLayout` / `TabLayout` / `StackLayout` / `DockLayout`).
- **OS-surface wrappers stay put** in `library/winrtdef` + `library/winrtmod`
  (`WinShell`, `Terminal`/`TermRender`, `Canvas2D`, `RasterView`, `GameView`/`GameViewGpu`,
  `ShaderView`, `DWrite`, `Dialogs`, `Clipboard`, `Com`, `Dispatch`) and are **instanced in
  place** (D4) — **not moved**.
- **Zero driver config:** loader auto-discovers `library/*def`; cross-family IMPORT resolves
  by module **name**.
- **Showcase app** lives in `projects/` (the rebuilt `FastM2`); the framework lib lives in
  `library/`.

---

## 2. SPRINT 0 — Placement & scaffolding (no behaviour)

> **Goal.** Prove the new family **exists, compiles, is auto-discovered, and links
> cross-family to `winrt`** — with zero driver/loader/test registration. No behaviour: every
> module is a minimal compiling stub carrying its house doc-comment block and the type/handle
> vocabulary from `pane-shell-mdi.md` §10. This is the load-bearing scaffolding sprint; get
> the paths, the `END <Name>.` periods, and the **class-decl shape** exactly right and every
> later sprint just fills bodies in.

### 2.1 Scope & deliverables — exact paths

Create the two sibling directories (names **must** end in `def`/`mod` for discovery):

```
E:\NewModula2\library\uidef\        (DEFINITION modules)
E:\NewModula2\library\uimod\        (matching IMPLEMENTATION modules)
```

Author four DEF/MOD pairs as **minimal compiling stubs** (basename == module name; body ends
`END <Module>.` with the period). Two stub shapes apply — distinguish them:

- **Class-bearing def** (`Surface` only): the `.def` declares the `ABSTRACT CLASS Backend`
  **at top level**, and the matching `.mod` must **re-declare the class verbatim** before the
  procedure bodies (the CLASS-in-DEF contract — §0.4; proven by compilation, see §2.6).
- **Procedure/RECORD-only def** (`PaneShell`, `PaneLayout`, `MDIContainer`): no class to
  re-declare; the `.mod` is just the stub procedure bodies.

| File | Stub content (Sprint 0) |
|---|---|
| `library/uidef/Surface.def` | doc-comment + `FROM SYSTEM IMPORT ADDRESS;` + `Kind` enum + **top-level** `ABSTRACT CLASS Backend; … END Backend;` with the five abstract methods (§10.1) + the `New*` / value-access proc **signatures** (no bodies in the def) |
| `library/uimod/Surface.mod` | **re-declares `ABSTRACT CLASS Backend; … END Backend;` verbatim**, then each constructor returns `NIL` (`(* TODO S5 *)`); value-access procs empty |
| `library/uidef/PaneShell.def` | doc-comment + `FROM SYSTEM IMPORT ADDRESS;` + `IMPORT Surface;` + `Workspace`/`PaneWindow`/`Pane`/`WindowId` = `ADDRESS`/`CARDINAL`, the `EventKind` enum, `Event` RECORD, `Handler` PROCEDURE type, and the proc signatures from §10.2 |
| `library/uimod/PaneShell.mod` | every proc a trivial stub (return `NIL`/`0`/`FALSE`; `Run`/`Quit`/`Retile` empty) |
| `library/uidef/PaneLayout.def` | doc-comment + `IMPORT PaneShell;` (for the `Pane` types in signatures) + `Orientation` enum + `Split`/`NewTabs`/`AddTab`/`NewStack`/`AddChild`/`SetWeight`/`Replace`/`SetHidden` signatures (§10.3) |
| `library/uimod/PaneLayout.mod` | trivial stubs (builders return `NIL`) |
| `library/uidef/MDIContainer.def` | doc-comment + `IMPORT PaneShell;` + `Style`/`Side` enums + the §10.4 signatures |
| `library/uimod/MDIContainer.mod` | trivial stubs |

House style for every file (§ `defModStyle`): open with a `(* … *)` block stating purpose; then
`DEFINITION MODULE <Name>;` / `IMPLEMENTATION MODULE <Name>;`; opaque handles are `ADDRESS`
with `NIL` = none; results `BOOLEAN`/`NIL`-sentinel; callbacks are named PROCEDURE types; every
file imports `FROM SYSTEM IMPORT ADDRESS;` (and the cross-family modules it references); end
`END <Name>.` (period). **No `<*GUI*>` pragma** in any library module.

**The verified skeleton (this exact form was compiled successfully — copy it, do not
improvise):**

```modula2
(* Surface — instanced leaves for PaneShell: custom render surfaces and native
   controls, behind one CLASS-as-vtable Backend (the house COM idiom). The pixels
   of a leaf. Part of the library/uidef+uimod (UI) family. See
   docs/design/pane-shell-mdi.md §10.1. *)
DEFINITION MODULE Surface;
FROM SYSTEM IMPORT ADDRESS;
TYPE
  Kind = (TextGrid, Raster, Canvas, Indexed, Shader, NativeControl, Custom);
ABSTRACT CLASS Backend;                            (* top level — NOT inside the TYPE block *)
  ABSTRACT PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  ABSTRACT PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  ABSTRACT PROCEDURE Paint;
  ABSTRACT PROCEDURE KindOf (): Kind;
  ABSTRACT PROCEDURE Close;
END Backend;
PROCEDURE NewCanvas (): Backend;                   (* … the rest of §10.1 … *)
END Surface.
```

```modula2
IMPLEMENTATION MODULE Surface;
FROM SYSTEM IMPORT ADDRESS;
ABSTRACT CLASS Backend;                            (* RE-DECLARED verbatim — mandatory *)
  ABSTRACT PROCEDURE Attach (hwnd: ADDRESS; pxW, pxH: CARDINAL): BOOLEAN;
  ABSTRACT PROCEDURE Resize (pxW, pxH: CARDINAL): BOOLEAN;
  ABSTRACT PROCEDURE Paint;
  ABSTRACT PROCEDURE KindOf (): Kind;
  ABSTRACT PROCEDURE Close;
END Backend;
PROCEDURE NewCanvas (): Backend;
BEGIN
  RETURN NIL;                                      (* TODO S5: wrap a Canvas2D instance *)
END NewCanvas;
END Surface.
```

> Why both the wrong and right shapes are spelled out: the obvious-looking
> `TYPE Backend = ABSTRACT CLASS PROCEDURE Attach(…); ABSTRACT; … END;` is a **hard parse
> error** (`expected type expression, found Keyword(Abstract)`) and a proc-only `Surface.mod`
> is a **hard sema error** (`definition exports 'Backend' but implementation does not declare
> it`). Both were reproduced, then the form above compiled and the smoke printed
> `paneshell-scaffolding-ok`.

### 2.2 Smoke target + reserved test slot

- Add the **smoke test** `E:\NewModula2\Mod\tests\t-90-260-paneshell-smoke.mod` — a
  console `MODULE` that `IMPORT`s **all four** new modules **and** at least one `winrt` module
  by name (`IMPORT WinShell`), and makes a **live reference** to each so no import is dead-code
  eliminated (state the minimum live references explicitly): declare a `VAR b: Surface.Backend;`
  and mention the enum value `Surface.Canvas`; take `ADR` of a `PaneShell.Pane` variable;
  reference a `PaneLayout.Orientation` value and an `MDIContainer.Style` value; reference a
  `WinShell` type. Then print a single line `paneshell-scaffolding-ok`. This forces the abstract
  `Backend` (with all five `ABSTRACT` methods) through **codegen** — the vtable layout is
  exercised, not merely name-resolved — and proves: family exists, compiles, is
  **auto-discovered**, and **links cross-family** to `winrt`.
- Register the Rust `#[test]` in `tests/newm2-tests/tests/m2_tests.rs`:
  `fn t90_260_paneshell_smoke() { check("t-90-260-paneshell-smoke.mod", "paneshell-scaffolding-ok\n"); }`.
  No per-family registration in `src/lib.rs` (its `push_library_def_dirs` already discovers
  `uidef`).
- **Negative-path proof** (the zero-config story hinges on the `def`/`mod` suffix and
  basename==module-name rules, so prove the failure mode too): add a tiny negative test that a
  reference to a **non-existent** `uidef` module fails to resolve —
  `fn t90_260b_paneshell_badref() { check_run_error("t-90-260b-paneshell-badref.mod", &["…"]); }`
  with a needle from the loader's not-found diagnostic. "Auto-discovery works" is then proven by
  a happy path **and** a deliberate mis-step.

### 2.3 Doc cross-link

- Add a short **"Library placement"** note + back-link to this sprint plan into
  `docs/design/pane-shell-mdi.md` (a new subsection under §8 or an appendix): "Framework lives
  in `library/uidef`+`library/uimod`; surfaces instanced in place in
  `library/winrtdef`+`library/winrtmod`; sprint schedule in `pane-shell-sprints.md`."

### 2.4 Dependencies

None (first sprint).

### 2.5 Exit criteria (concrete + verifiable)

- All eight files exist at the exact paths above; each ends with `END <Name>.` (period);
  each `.def` basename equals its module name; `Surface.mod` **re-declares** the exported
  `ABSTRACT CLASS Backend`.
- **(CI)** the smoke is verified **through the test harness**, not only the driver:
  `cargo test -p newm2-tests` runs `t90_260` (`check()` reads `tests_dir()` = `Mod/tests`,
  builds its own `SearchPath` via `push_library_def_dirs`, and discovers `uidef`) and it
  prints `paneshell-scaffolding-ok`; the negative `t90_260b` resolves-fails as expected.
- **(MANUAL, sanity)** `newm2 run Mod/tests/t-90-260-paneshell-smoke.mod` prints the same line
  with **no** `--library` flag inside the repo and **no** driver/loader edits (the driver walks
  cwd ancestors to `library/`).
- `cargo test -p newm2-tests` green overall; conformance count unchanged (baseline `1024/1220`).
- Existing `winrt` demos + `FastM2` still build (nothing was moved or touched).

### 2.6 Risks & mitigations

| Risk | Mitigation |
|---|---|
| A missing trailing `.` or a basename≠module-name silently breaks discovery | Sprint exit runs the smoke import **through `check()`**; the test fails loud if either is wrong |
| The class skeleton is written in the invalid `TYPE Name = ABSTRACT CLASS … ABSTRACT;` form | §2.1 mandates the **verified** standalone `ABSTRACT CLASS Backend; ABSTRACT PROCEDURE …; END Backend;` shape; the wrong form is a documented hard parse error |
| `Surface.mod` omits the mandatory class **re-declaration** | §2.1 task lists it explicitly; the smoke `check()` fails with `definition exports 'Backend' but implementation does not declare it` if missing |
| A `.def` omits `FROM SYSTEM IMPORT ADDRESS;` / cross-family `IMPORT` its signatures use | Every stub row lists its imports; omission yields `unknown type 'ADDRESS'`, caught by the smoke |
| Accidentally importing a `winrt` module that pulls a large `.bss` under JIT | Smoke imports `WinShell` (message-only, headless-safe), not a buffer-heavy surface |

> Note on the abstract-class-without-subclass concern: sema only runs the "all slots concrete"
> check for **non-abstract** classes, so an all-abstract `Backend` with no `INHERIT` compiles
> cleanly standalone — the genuine standalone-compile risk is the **re-declaration** rule
> above, which is why it, not the abstract-method case, is the load-bearing S0 mitigation.

### 2.7 Open questions resolved

None (scaffolding only). It **sets up** the resolution of all of Q17.1–Q17.7 in later sprints.

---

## 3. Implementation sprints

Ordering rule (from the design): **instancing the surfaces (P1) is the load-bearing
prerequisite and comes first**; the **`Layout`-strategy interface (D7) is declared in the
substrate (`PaneShell`) at S7** (where §8 says it "lives in `PaneShell`") so S8–S9 implement
their reactive layouts **as strategies from the start** — there is no later substrate-router
rewire; S11 only *adds the `DockLayout` strategy*. Every sprint preserves back-compat via the
D4 singleton-shim contract, re-verified by re-running the touched surface's existing winrt test
(§0.3 item 2).

### 3.0 P1 instancing-order audit (do this first, inside S1's lead-in)

Before instancing any surface, **enumerate the real inter-surface import DAG of the six
renderers and lock the order from it** — the order below is *derived* from this audit, not
assumed:

- **Verified edge:** `winrtmod/GameViewGpu.mod` `IMPORT ShaderView;` and drives ShaderView's
  device directly — `ShaderView.Startup/Attach/SetShader/BindTexture/InitSprites` (~L570,
  581–586) and `ShaderView.UploadTexture/BeginFrame/DrawSprites/EndFrame` (~L483–493).
  `GameViewGpu` owns **no device of its own**; its per-instance device/swapchain state **is**
  `ShaderView`'s state. **Therefore `ShaderView` must be instanced *before* `GameViewGpu`.**
- **Verified edge:** `winrtmod/TermRender.mod` `IMPORT Terminal;` — the text-grid renderer
  sits on the cell model, so `Terminal` + `TermRender` are instanced together (S1).
- **Audit exit:** a confirmed edge list + an instancing order that respects it (no other hidden
  edge — e.g. confirm no surface secretly drives `DWrite` singleton state cross-instance). The
  order this yields: **S1** text-grid (`Terminal`+`TermRender`) → **S2** raster/canvas (CPU
  `RasterView` + D2D `Canvas2D`) → **S3** `GameView` (CPU) + `ShaderView` (standalone D3D leaf)
  → **S4** `GameViewGpu` (layers on the now-instanced `ShaderView`) → **S5** `Surface.Backend`.

---

### S1 — Instance the text-grid surface: `Terminal` + `TermRender` (P1, part 1/5)

**Goal.** Make the text-grid renderer instanceable — chosen **first within P1** because it is
the most-used surface (FastM2, every terminal demo) and the highest back-compat risk, so the
shim contract is proven on the hardest case first; `TermRender` sits directly on `Terminal`
(verified import), so they instance together. Add an instance handle holding the per-instance
cell grid + HWND + D2D/DWrite targets; rewrite the module-singleton procs as shims over a
default instance (D4, lean `Use` per Q17.1).

**Scope & deliverables**
- `library/winrtmod/Terminal.mod` + `library/winrtmod/TermRender.mod` (instanced **in place**;
  defs `library/winrtdef/Terminal.def` / `TermRender.def` gain `Instance`/`Create`/`Use`/`Free`).
- `TYPE Instance = ADDRESS;` (`NIL` = none). `Create(cols,rows,font,pt): Instance`,
  `Use(i: Instance)` (sets the current instance), `Free(VAR i: Instance)`.
- **Per-instance read accessor** (required by the exit test): `CellChar(i: Instance; r, c:
  CARDINAL): CHAR` (and, as convenient, `CellFg`/`CellBg`) — the existing singleton getters at
  `Terminal.mod` ~L213/219/225 give the pattern; the test cannot be written without an
  instance-keyed read-back.
- Per-instance state **heap-allocated** (`Storage`/`Heap`) — the cell grid must **not** be a
  module global (keeps total module sections < 4 MiB so JIT tests still load; §0.4). The reason
  here is **correctness/coexistence** (two grids at once) and total-section headroom — *not* a
  current single-grid 4 MiB overflow (Terminal's 70×220 grid is well under).
- Existing singleton procs (`Terminal.Put`, menus, status, fields; `TermRender` paint) become
  thin shims over a lazily-created default instance.

**Dependencies:** S0. (Plus the §3.0 audit, performed as S1's lead-in.)

**Exit criteria**
- **(CI)** headless JIT test `t-90-261-terminal-instance.mod`: create **two** `Terminal`
  instances, write distinct content to each, read back each instance's cell at (0,0) via
  `CellChar` and assert they differ — the §3.1 "two of the same surface can't coexist" obstacle
  is removed for text-grid. Also asserts the framework/surface module still **loads under
  JIT** (proves total sections < reserve).
- **(CI, back-compat)** the existing `t-90-244` Terminal and `t-90-246` TermRender tests
  **re-run green** (shim preserves runtime behaviour, not just links).
- `demos/term-demo.mod` and `projects/FastM2/FastM2.mod` build **unchanged** (shim contract).
- `cargo test -p newm2-tests` green; conformance unchanged.

**Back-out note (applies to S1–S4):** the back-compat gate is "demo builds unchanged **and**
the surface's winrt test re-runs green." If a demo cannot build unchanged because it reaches a
now-removed module global, the contingency is: (a) keep the global as a `Use(default)`-backed
accessor so the shim stays transparent; or, only if that is impossible, (b) make the *minimal*
demo edit and record it in the sprint's notes — the shim transparency goal is a strong default,
not an absolute, and the sprint must state which path it took.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| Refactoring one-HWND-one-buffer module globals into per-instance state breaks the shim | Default-instance shim is added in the *same* sprint and gated by rebuilding FastM2 + term-demo *and* re-running `t-90-244`/`t-90-246` |
| Per-instance cell grids multiply total `.bss` and risk the per-module reserve | Heap-allocate every per-instance buffer from day one (§0.4) |
| `SHORTREAL`/COM-vtable regressions in TermRender | Reuse the proven DWrite/TermRender FLOAT-through-vtable path; assert via `SUCCEEDED` |

**Open questions resolved:** Q17.1 (instancing strategy) — **decided: current-instance +
`Use`**, low-churn, the `Backend` adapter (S5) hides it. **This decision binds S2–S4 and is
validated against the S13 threading requirement** (see the "current-instance thread-safety"
task below): the implicit global "current instance" of the `Use` model is acceptable only
because every legacy-shim caller and every framework adapter runs on the **UI thread**; the one
S13 producer thread builds CPU buffers and never calls `Use`/the singleton procs — S13's exit
re-confirms this.

---

### S2 — Instance the raster + canvas surfaces: `RasterView` + `Canvas2D` (P1, part 2/5)

**Goal.** Instance the two RGBA leaves (CPU `RasterView`, D2D vector+text `Canvas2D`) the same
way, following the Q17.1 decision from S1.

**Scope & deliverables**
- `library/winrtmod/RasterView.mod`, `library/winrtmod/Canvas2D.mod` (+ their defs):
  `Instance`/`Create`/`Use`/`Free`; per-instance HWND + framebuffer / D2D target **heap-held**
  (an RGBA framebuffer is exactly the large static state the §0.4 mandate targets).
- **Per-instance read accessor**: `RasterView.PixelAt(i: Instance; x, y: CARDINAL): CARDINAL`
  (RGBA read-back) — required by the exit test.
- Singleton procs → shims over a default instance.

**Dependencies:** S1 (reuses the proven instancing pattern + the Q17.1 decision).

**Exit criteria**
- **(CI) headless JIT** `t-90-262-raster-instance.mod`: two `RasterView` instances with
  different pixel content read back distinctly via `PixelAt` (CPU framebuffer → genuinely
  headless); module still loads under JIT.
- **(CI) headless JIT** `t-90-262b-canvas-construct.mod`: construct two `Canvas2D` instances to
  factory/format level, assert `KindOf` and `Close` succeed **without `Attach`/`Paint`** (D2D
  `HwndRenderTarget` rejects a message-only window — §0.5).
- **(MANUAL, AOT)** `demos/paneshell-canvas-coexist.mod`: a `Canvas2D` instance and a
  `RasterView` instance painting in one real window, no shared-singleton clash.
- **(CI, back-compat)** re-run the existing RasterView and Canvas2D winrt tests green; pin the
  specific demos that exercise each shim: a **RasterView CPU** demo (e.g. `demos/reversi_gui.mod`
  if it drives `RasterView` — confirm at sprint start) **and** a non-GPU `Canvas2D` demo
  distinct from the GPU `mandelbrot_gpu.mod`, so each surface's shim is independently gated, not
  swept up by another.
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| Large RGBA framebuffer multiplied per instance pressures the per-module reserve | Heap-allocate the framebuffer per instance (§0.4) |
| Claiming a headless `Attach` for `Canvas2D` | `Canvas2D` `Attach`/`Paint` is **(MANUAL) AOT only**; CI tests construction + `KindOf` + `Close` only (§0.5/§0.6) |

**Open questions resolved:** consumes Q17.1 (no new resolution).

---

### S3 — Instance `GameView` (CPU) + `ShaderView` (standalone D3D leaf) (P1, part 3/5)

**Goal.** Instance the CPU indexed leaf (`GameView`) **and** the standalone D3D11 `ShaderView`
leaf. `ShaderView` is instanced **here, before `GameViewGpu`**, because `GameViewGpu` is built
on top of it (verified §3.0 edge) and cannot be given per-instance device state until
`ShaderView` owns per-instance device state.

**Scope & deliverables**
- `library/winrtmod/GameView.mod`, `library/winrtmod/ShaderView.mod` (+ defs):
  `Instance`/`Create`/`Use`/`Free`; per-instance bg buffer + sprite layer (GameView) /
  device + swapchain + render target (ShaderView), all heap-held.
- **Per-instance read accessor**: `GameView.IndexAt(i: Instance; x, y: CARDINAL): CARDINAL`
  (indexed read-back) — required by the exit test.
- Singleton procs → shims.

**Dependencies:** S1.

**Exit criteria**
- **(CI) headless JIT** `t-90-263-gameview-instance.mod`: two `GameView` instances, distinct
  indexed content read back via `IndexAt`; module still loads under JIT.
- **(CI) headless JIT** `t-90-263b-shader-construct.mod`: construct two `ShaderView` instances
  to device-factory level where possible, assert `KindOf`/`Close` **without `Attach`** (a DXGI
  swapchain with `outputWindow := hwnd` rejects `HWND_MESSAGE` — §0.5).
- **(MANUAL, AOT)** `demos/paneshell-shader-coexist.mod`: two `ShaderView` instances each
  presenting to its own real HWND, coexisting.
- **(CI, back-compat)** re-run the GameView and ShaderView winrt tests green; `demos/galaga.mod`
  and a ShaderView demo build unchanged.
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| GPU device/swapchain affinity per instance | Each `ShaderView` instance owns its own device + swapchain; producers never touch it (sets up §7) |
| Sprite-layer / framebuffer globals pressure the per-module reserve | Heap-allocate per instance |
| Claiming a headless `Attach` for `ShaderView` | `Attach` is **(MANUAL) AOT only**; CI tests construction + `KindOf`/`Close` (§0.5/§0.6) |

**Open questions resolved:** consumes Q17.1.

---

### S4 — Instance the GPU indexed surface: `GameViewGpu` (P1, part 4/5 — closes P1)

**Goal.** Instance `GameViewGpu`, completing P1's "instance the surfaces" across all six
renderers. `GameViewGpu` **layers on the already-instanced `ShaderView`** (S3): its per-instance
device state *is* its wrapped `ShaderView` instance, driven through
`ShaderView.Attach/SetShader/Startup/BeginFrame/…`. This is no longer a pure leaf of the
surface DAG — it has an explicit dependency edge to `ShaderView`.

**Scope & deliverables**
- `library/winrtmod/GameViewGpu.mod` (+ def): `Instance`/`Create`/`Use`/`Free` that **own a
  `ShaderView` instance** and route the device calls to it (no second device); per-instance bg
  buffer + sprite/atlas/palette state heap-held; singleton procs → shims.

**Dependencies:** **S3 (`ShaderView` must be instanced first)** — the load-bearing intra-P1
edge. (Transitively S1.)

**Exit criteria**
- **(CI) headless JIT** `t-90-264-gameviewgpu-construct.mod`: construct two `GameViewGpu`
  instances, assert each owns a **distinct** `ShaderView` instance (its per-instance device),
  `KindOf`/`Close` succeed **without `Attach`** (swapchain → message-only rejected, §0.5);
  module still loads under JIT.
- **(MANUAL, AOT)** a `GameViewGpu` demo presents in a real window without disturbing the
  singleton path.
- **(CI, back-compat)** re-run the GameViewGpu winrt test green; its demo builds unchanged. If
  the demo reaches `ShaderView`'s former singleton globals it cannot keep building transparently
  — apply the §S1 back-out note and record the path taken.
- **P1 close-out gate:** the full demo set still builds — `term-demo`, `galaga`,
  `mandelbrot_gpu`, `reversi_gui`, plus `FastM2` — and the per-surface instance tests
  `t-90-261..264` (+ the `…b` construct tests) all pass under JIT.
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| `GameViewGpu` reaches deeply into `ShaderView`'s former singleton state; the shim may not be perfectly transparent | `GameViewGpu` now holds a `ShaderView` *instance*; if a demo still touched `ShaderView` singletons, apply the §S1 back-out note (instance-backed accessor, else minimal recorded demo edit) |
| Last surface, but the whole P1 contract ("instances coexist; all demos compile; FastM2 compiles") is asserted here | The close-out gate re-builds the entire demo set + FastM2 and re-runs every per-surface winrt test |

**Open questions resolved:** Q17.1 fully discharged (P1 complete).

---

### S5 — `Surface.Backend` CLASS + custom-surface adapters (P2, part 1/2)

**Goal.** Land the one polymorphic handle — the `Surface.Backend` ABSTRACT CLASS (CLASS-as-
vtable, the house idiom) — and the **custom-surface** adapters, each wrapping an *instance*
of a P1 renderer. This is the first sprint that fills the S0 `Surface` stub with real bodies.

**Scope & deliverables**
- `library/uimod/Surface.mod`: concrete subclasses of `Backend`, one per surface family —
  `NewTextGrid` (wraps a `Terminal` instance), `NewRaster` (`RasterView`), `NewCanvas`
  (`Canvas2D`), `NewIndexed` (`GameView` CPU). Each implements
  `Attach`/`Resize`/`Paint`/`KindOf`/`Close` by driving its wrapped instance (S1–S4 `Use`).
- `NewShader` (wraps a `ShaderView` instance) — its **construction + `KindOf`** ship here;
  `Attach`/`Paint` are AOT-only by nature (§0.5).
- **`GameViewGpu` as a Surface leaf** (close the §3 design's GPU-indexed leaf): give `NewIndexed`
  a backing selector — `NewIndexed(w, h, scale; gpu: BOOLEAN)` (or a sibling `NewIndexedGpu`) —
  so the GPU indexed surface instanced in S4 is reachable through the facade and reports
  `KindOf = Indexed`. (Without this, S4's cost is paid but the surface is unreachable as a leaf.)
- `IMPORT Terminal, TermRender, RasterView, Canvas2D, GameView, GameViewGpu, ShaderView` from
  `winrtmod` by name (cross-family, zero config).
- `KindOf` returns the matching `Kind` (`TextGrid`/`Raster`/`Canvas`/`Indexed`/`Shader`).

**Dependencies:** S1, **S2** (the adapters this sprint *ships first* — `NewTextGrid`,
`NewCanvas` construction, `NewRaster` — need only S1+S2). The `NewIndexed`/`NewShader` adapters
need S3, and the GPU-indexed selector needs S4; those are added as S3/S4 land. *In the standard
order S1–S4 all precede S5, so this is a scheduling note (S5 need not block on the GPU-heaviest
surface to land the polymorphic-handle proof), not a reordering.*

**Exit criteria**
- **(CI) headless JIT** `t-90-265-surface-backend.mod`: build a `NewTextGrid` and a
  *constructed* `NewCanvas` `Backend`, hold both as the **same** `Surface.Backend` variable
  type, call `KindOf` on each and assert the two kinds differ — **one polymorphic handle drives
  any custom surface** through the COM vtable. (`KindOf`/`Close` only for D2D/D3D adapters; no
  `Attach`/`Paint` headlessly.)
- **(CI) headless JIT**: assert the GPU-indexed `Backend` (S4-backed) reports `KindOf = Indexed`
  — the §3 GPU leaf is reachable through the facade.
- **(CI) headless JIT** for the message-window-safe adapters only: `NewTextGrid`'s `Attach`
  against a message-only HWND succeeds (TermRender's proven message-window path). The
  Canvas/Shader/IndexedGpu adapters assert construction + `KindOf` + `Close` headlessly and push
  `Attach`/`Paint` to the **S7 leaf AOT demo** (§0.5).
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| One `Backend` interface must fit retained custom surfaces (real `Paint`) and, later, no-op controls | `Paint` is abstract; S6 controls implement it as a no-op — asymmetry designed in from §6 table |
| Virtual `Attach` returning `BOOLEAN` across the vtable | Framework API stays `BOOLEAN`; convert any Win32 `BOOL` at the FFI seam inside the adapter |
| Asserting `Attach` headlessly for a D2D/D3D adapter | Only message-window-safe adapters assert headless `Attach`; the rest are construction-only (CI) + AOT demo (MANUAL) |

**Open questions resolved:** sets up Q17.5 (control value API), resolved in S6.

---

### S6 — Native-control adapters + the control value API (P2, part 2/2 — closes P2)

**Goal.** Land native controls as the **simplest possible leaf** (§6): a control `Backend`
whose `Attach` creates the control HWND as a child and whose `Paint` is a **no-op** (the OS
draws it). Add the generic value-access API over a `Backend`.

**Scope & deliverables**
- `library/uimod/Surface.mod` (extended): `NewButton`, `NewEdit`, `NewList`, `NewTree`,
  `NewCombo` — each a `Backend` subclass that on `Attach` creates the Win32 common control
  (button/edit/listview/treeview/combo) as a child HWND, `Resize` → `MoveWindow`, `Paint` →
  no-op, `KindOf` → `NativeControl`.
- Generic value API: `SetText`/`GetText`/`AddRow`/`Selected` over a `Backend` (Q17.5: generic,
  the simplest option).
- **`Kind.Custom` is the app-extension seam** (close the orphaned enum value): no framework
  constructor returns it — an *app* subclasses `Surface.Backend` directly and returns
  `KindOf = Custom`. Document this in the S6 deliverables; an S6 exit assertion shows an
  app-defined `Backend` slots into the same handle and reports `Custom`.
- `EvControl` wiring stub (the `WM_COMMAND`/`WM_NOTIFY` → semantic event path is *declared*
  here, *routed* in S7).

**Dependencies:** S5.

**Exit criteria**
- **(CI) headless JIT** `t-90-266-control-backend.mod`: create a `NewButton` and a `NewEdit`
  `Backend`, `Attach` each to a message-only host (a control HWND is message-window-safe),
  `SetText`/`GetText` round-trips on the edit; assert `KindOf = NativeControl` and that `Paint`
  is a no-op (no exception, nothing drawn). Plus: define a trivial app-side `Backend` subclass
  in the test and assert it reports `KindOf = Custom` and shares the same variable type.
- A control `Backend` and a custom-surface `Backend` are held by the **same** variable type
  with zero special-casing — the §6 leaf-spectrum claim verified.
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| Generic value API too thin for rich controls (listview columns, tree nodes) | Q17.5 ships generic now; rich-control typed accessors reserved to the Reserved-hook backlog / revisited in S13 |
| Win32 `BOOL`/flags width mismatch creating controls | Use `CARDINAL`/`DWORD` + `BAND`/`BOR` for style flags (not `SET`); convert `BOOL` at the seam |

**Open questions resolved:** **Q17.5** (control value API) — **decided: generic
`SetText`/`AddRow`/`Selected` over a `Backend`**; rich-control typed accessors deferred.

---

### S7 — `PaneShell` substrate: `Pane`, host HWND, registry, event router, channel + the `Layout` interface (P3)

**Goal.** Build the **complete** shared substrate both facades stand on (§8): the universal
`Pane` (a host HWND), the named registry, the **event router** (control plane), the **per-pane
channel** present but **drained inline** by the single UI thread (the D2 on-ramp; the seam
exists from day one), **and the `Layout` ABSTRACT CLASS itself** — which §8 says *lives in
`PaneShell`*. Declaring `Layout` here (even with no strategy yet consuming it) means S8–S9
implement their reactive layouts **as `Layout` strategies immediately**, and the router learns
to **delegate gutter/handle/drag/drop to a host Pane's `Layout`** *now* — so there is **no later
substrate-router rewire**; S11 merely adds a new `DockLayout` strategy. Windows and the message
loop land in this same sprint, hosting the S5/S6 leaf `Backend`s. **Leaf panes only** for live
content this sprint. (Introducing `Layout` early is free of circular-import risk: `PaneLayout`/
`MDIContainer` already `IMPORT PaneShell`, never the reverse.)

**Scope & deliverables**
- `library/uimod/PaneShell.mod`: `Pane` host window `WS_CHILD | WS_CLIPCHILDREN`, no
  background erase (D3); the HWND tree mirrors the Pane tree (§4).
- `LeafPane(id, back: Surface.Backend)` — recursion bottoms out at a leaf (§10.2); on host
  creation it `Attach`es the `Backend` to the host HWND.
- Named-pane bridge: `PaneByName(root,id)`, `BackendOf(p)`, `RectOf(p,…)`.
- `Workspace`/`PaneWindow` lifecycle over `WinShell`: `Init`, `OpenWindow`, `CloseWindow`,
  `SetRoot`, `Retile`, `Run`, `Quit` — `PaneWindow` makes its top window through `WinShell`.
- **`Layout` ABSTRACT CLASS declared in `PaneShell`** (§8 verbatim): `Arrange`/`HitTest`/
  `Drag`/`DropAt`/`Save`/`Load` + the `DropZone` enum. The event router **delegates** all
  gutter/handle/drag/drop interaction to the host Pane's `Layout` (no-op for a pane that carries
  none); the substrate never knows the algorithm.
- Event router: raw Win32 message → semantic `Event` keyed to a `Pane` (`Event` RECORD +
  `Handler` PROCEDURE type + `EventKind` incl. `EvControl` for `WM_COMMAND`/`NOTIFY`, wiring
  the S6 control events).
- Per-pane lock-free SPSC channel, **drained inline** by the UI thread (seam present, no
  threads lit — D2).
- Polled input snapshot lane: `KeyDown(vk)`, `MouseAt(…)` for game-loop panes.
- `SetThreaded(p,on)` **declared** as the data-plane opt-in seam (no threads yet, D2).
- **Introspection / probe seam:** `DumpTree(win)` — a structured dump of the live Pane tree
  (each node's id, kind, rect, channel depth, focus) over the existing
  `PaneByName`/`BackendOf`/`RectOf` read-backs. Reserved **here, in the substrate**, because the
  reified declarative tree (§4) makes it nearly free, and it is dual-use: the **headless test
  probe** every later sprint asserts against, *and* the foundation of a future devtools-style
  **live layout inspector** (a tool built on `DumpTree`, deferred to the reserved backlog).
  Probing the tree must never require a window.

**Dependencies:** S6 (a leaf hosts a `Surface.Backend`, which now spans custom + control).

**Exit criteria**
- **(CI) headless JIT** `t-90-267-paneshell-substrate.mod`: build a small tree
  (`LeafPane`s under a structural parent), assert `PaneByName` finds each leaf, `BackendOf`
  returns the right `Backend`, and the host HWND nesting mirrors the Pane tree (parent/child
  HWND relationship checked via Win32). Synthesize a `WM_COMMAND` into the router and assert it
  emerges as an `EvControl` `Event` keyed to the right `Pane` (the `t-90-243`-proven
  message-window→WNDPROC path).
- **(CI) channel seam:** push a frame onto a pane's channel and assert the inline drain delivers
  it (single-threaded), vindicating D2's on-ramp.
- **(CI) `Layout`-delegation regression guard:** assert the router still behaves correctly for a
  **leaf / non-`Layout`** pane after learning to delegate to `Layout` — i.e. a pane carrying no
  `Layout` is untouched by the new delegation path. (This is the substrate-router guard that
  must hold across S8/S9/S11 strategy additions.)
- **(CI) polled-input lane:** synthesize a key/mouse message and assert `KeyDown(vk)` /
  `MouseAt(…)` return the updated snapshot — the "fast sensor lane" is gated where it is built,
  not left ungated until S13.
- **(CI) dark-seam check:** assert `SetThreaded(p, TRUE)` is **callable** and does **not** change
  the inline-drain behaviour (the D2 "API present, threads dark" contract), so the P8 attachment
  point is gated at the sprint that introduces it.
- **(CI) introspection probe:** `DumpTree(win)` of the built tree reflects the live structure
  (ids, kinds, rects, nesting) — the same hook later sprints use to assert layout headlessly and
  a live app would use to inspect itself. Probing requires no window.
- **(MANUAL, AOT)** `demos/paneshell-leaf.mod`: a leaf pane hosts a `Surface.Backend` (incl. the
  Canvas/Shader adapters whose real `Attach`/`Paint` could not be tested headlessly in S5)
  inside a real window; builds and launches; one leaf shown.
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| Getting one event router right as the single serialization point (§7) | Router is the only WNDPROC; everything fans out from it; covered by the synthesized-message test |
| The `Layout`-delegation path subtly changes leaf-pane behaviour | The non-`Layout` regression guard (above) asserts a leaf pane is unaffected — held across all later strategy additions |
| Seam flicker from per-pane HWNDs | `WS_CLIPCHILDREN` + no background erase (D3) |
| Q17.2: does every arrangement need a host HWND? | **Default uniform "Pane = HWND" here**; flattening deferred as a measured optimization (revisit P8) |
| Q17.6: channel granularity per pane kind | Channel carries an opaque buffer; granularity (frame vs delta) **chosen per Backend**, finalized when threads light up (P8) |

**Open questions resolved:** **Q17.2** (host-HWND-per-arrangement) — **decided: uniform
"Pane = HWND" default; flatten only as a measured optimization** (deferred). Opens **Q17.6**
(channel granularity) — seam defined here, finalized per-Backend through P8.

---

### S8 — `PaneLayout` reactive facade: `SplitLayout`/`StackLayout` + the rectangle solver (P4, part 1/2)

**Goal.** Add the reactive facade's core as **`Layout` strategies** (`SplitLayout`,
`StackLayout`) over the interface S7 declared — *no free procedures to re-home later*. A
**rectangle solver** (tree → rects) drives `Split`/`Stack`, with `MoveWindow` on resize. Layout
= `f(structure)`, **retained not diffed** (D1) — the change path is *mutate the held tree +
`Retile`*. This fills the S0 `PaneLayout` stub. (Splitter **drag** + fixed **tabs** land in S9.)

**Scope & deliverables**
- `library/uimod/PaneLayout.mod`: `Split(dir, weight, minFirst, minSecond, first, second)`
  (no drag yet — static divider) and `NewStack(dir, gap)` / `AddChild` — both **builders that
  attach a `SplitLayout` / `StackLayout` strategy** (subclasses of `PaneShell.Layout`) to an
  arrangement Pane.
- The **rectangle solver** lives in `SplitLayout.Arrange` / `StackLayout.Arrange`: tree →
  rects, surfaced via `PaneShell.RectOf` / `Retile` (headless-unit-testable, the explicit P4
  deliverable).
- Reactive mutators on the held tree: `SetWeight`, `Replace`, `SetHidden` (the D1 change path),
  each followed by `Retile` → `MoveWindow`.

**Dependencies:** S7.

**Exit criteria**
- **(CI) headless JIT** `t-90-268-rect-solver.mod`: build a
  `Split(Horizontal, 0.70, 240, 160, …)` in a known client rect; assert `RectOf` of each child
  matches the 70/30 split **with the min-size clamps applied**; call `SetWeight` + `Retile` and
  assert the rects move; nest a `Stack` and assert gap/orientation. **No window needed — pure
  solver math through `SplitLayout.Arrange`.**
- **(MANUAL, AOT)** `demos/paneshell-split.mod`: a static 70/30 canvas+console split that
  re-tiles on window resize.
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| Solver correctness with `minFirst`/`minSecond` clamps under resize | Clamp logic is the headless test's main assertion target |
| Confusing retained mutate-then-Retile with a diff | D1 is explicit: there is no diff; tests mutate the live tree directly |

**Open questions resolved:** none new (the channel-granularity Q17.6 stays open per-Backend).

---

### S9 — Splitter drag + fixed tabs (`TabLayout`); worked example 13a (P4, part 2/2 — closes P4)

**Goal.** Make the `SplitLayout` divider **draggable** and add **fixed, author-declared tabs**
(`TabLayout`; not user-draggable — distinct from MDI tabs). Outcome: worked example **13a** runs
and is draggable. Because S8–S9 are already written **as strategy classes** (S7's `Layout`
interface), **S11 has nothing to re-home** — it only adds the `DockLayout` sibling.

**Scope & deliverables**
- Splitter drag in `SplitLayout`: `HitTest` finds the gutter → `Drag` → `SetWeight` + `Retile`
  → `MoveWindow` (§11); raises `EvSplitterMoved`. The drag/hit-test math lives **in the
  `SplitLayout` strategy** (delegated by the S7 router), not as free procedures.
- `NewTabs` / `AddTab` — a `TabLayout` strategy: fixed author-declared tabs; raises
  `EvTabChanged` on tab switch.

**Dependencies:** S8.

**Exit criteria**
- **(CI) headless JIT** `t-90-269-splitter-tabs.mod`: synthesize a drag delta into
  `SplitLayout.HitTest`/`Drag`, assert the resulting `SetWeight` value and re-solved rects
  (the **splitter/tab math** the strategy owns — fully covered here so the manual 13a re-run is
  a formality, not the safety net); assert `AddTab` + tab-switch produces the right active child
  and an `EvTabChanged` event.
- **(MANUAL, AOT) worked example 13a** (`demos/paneshell-13a.mod`): canvas + console split 70/30
  runs, the divider drags, panes resize live; min-size clamps hold during drag.
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| Reactive (fixed) tabs confused with MDI (draggable) tabs when S11 lands | Keep ownership explicit: reactive tabs are author-declared and never user-reorderable; S11's MDI tabs are a separate `DockLayout` concern (§4 "same pixels, different ownership") |
| Drag math off-by-one vs clamps | Headless drag test asserts exact post-drag rects |

**Open questions resolved:** none new; P4 complete.

---

### S10 — Multiple top-level windows (P5)

**Goal.** Support several top-level OS windows at runtime: `OpenWindow`/`CloseWindow` during
execution, **one** message loop over a `WindowId` table, per-window registries, events keyed
by `WindowId`. P5 depends on the substrate (S7); it is scheduled after the reactive facade so
each window can be populated with a real split, **and it must complete before S11** (it is a
co-requisite of S9 at the S11 join — `Float` pops a subtree into a new top-level window).

**Scope & deliverables**
- `library/uimod/PaneShell.mod` (extended): a `WindowId` table; `OpenWindow`/`CloseWindow`
  usable at runtime; one message loop iterating the table; per-window pane registries; events
  carry `Event.window: WindowId`.

**Dependencies:** **S7 (substrate) AND S8** — the demo/exit populates each window with a
reactive split, so the dependency is honestly S8, not S7-only. (Independent of S9; runs in
parallel with S9 after S8.)

**Exit criteria**
- **(CI) headless JIT** `t-90-270-multiwindow.mod`: register two windows in the table, route a
  synthesized event into each, assert each event is keyed to the correct `WindowId` and reaches
  the correct per-window registry (**no cross-window leakage**).
- **(MANUAL, AOT)** `demos/paneshell-multiwin.mod`: open **two** top-level windows at runtime,
  each with its own reactive split; close one; the other keeps running; the single loop drives
  both.
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| Per-window registry lifecycle as windows open/close | `CloseWindow` tears down exactly its registry; tested by open-two/close-one |
| One router across many windows leaking events | Events keyed by `WindowId` from the router; cross-window-leakage assertion in the test |

**Open questions resolved:** none new.

---

### S11 — `MDIContainer` = `DockLayout` strategy (the second strategy) (P6, part 1/2)

**Goal.** Land the MDI/dock facade as a container `Pane` whose arrangement is the **`DockLayout`
strategy** — the *second* family over the `Layout` interface S7 already declared and S8–S9
already implement against. Because the interface and the router delegation exist since S7, this
sprint **adds** `DockLayout`; it does **not** reopen or rewire the substrate, and **does not
re-home** S8/S9 (they were strategies from birth). This is the ordering hinge in spirit (the
second strategy lands here) without a retro-fit.

**Scope & deliverables**
- `library/uimod/MDIContainer.mod`: `Create(style)`; `AddDocument` → doc id, `CloseDocument`,
  `Activate`, `ActiveDocument`; the container Pane carries a `DockLayout` strategy.
- The `DockLayout` strategy **class skeleton** (stateful, a `PaneShell.Layout` subclass):
  `Arrange`/`HitTest` for a tabbed document strip; the heavy drag/float/dock interactions land
  in S12.
- The substrate's event router (unchanged since S7) drives `DockLayout` exactly as it drives
  `SplitLayout`/`TabLayout` — it never knows the algorithm (D7).

**Dependencies:** S9 (the reactive strategies sharing the interface) **and** S10 (float pops a
subtree into a new top-level window — needs multi-window). The diamond join S9 ∧ S10 ⇒ S11.

**Exit criteria**
- **(CI) headless JIT** `t-90-271-layout-strategy.mod`: drive the **same** substrate delegation
  path with a `SplitLayout` host and a `DockLayout` host; assert the router calls
  `Arrange`/`HitTest` on whichever strategy the host carries, with **no substrate code knowing
  the algorithm** (D7 seam proven by both sharing it).
- **(CI) regression** that S8/S9 are unaffected: `t-90-268` and `t-90-269` pass **byte-identical**
  — there is no retro-fit, but this proves adding `DockLayout` did not perturb the shared
  interface or router.
- **(CI) headless JIT model test**: `MDIContainer.Create` + `AddDocument`/`Activate` manage a
  live document set (add two docs, activate each, assert `ActiveDocument`).
- **(MANUAL, AOT)** the 13a demo still drags (the router/strategy delegation is unchanged for
  reactive hosts).
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| Adding a second strategy perturbs the shared interface/router | `t-90-271` proves both strategies share the path; `t-90-268/269` byte-identical re-pass proves reactive hosts unchanged; S7's non-`Layout` leaf guard still holds |
| The `Layout` interface too narrow for the real dock frontier | Interface mirrors §8 exactly (`Arrange`/`HitTest`/`Drag`/`DropAt`/`Save`/`Load`); frontier algorithms are new strategies, not interface changes (D7) |

**Open questions resolved:** **Q17.3** consumed (decided in design: ship a "reasonable"
`DockLayout`, extend via the hook). Sets up **Q17.4** (Save format), resolved in S12.

---

### S12 — `DockLayout` interactions + Save/Load; worked example 13b (P6, part 2/2 — closes P6)

**Goal.** Complete the **"reasonable docking"** set (§17.3-resolved) on the `DockLayout`
strategy: tabbed strip with drag-reorder; `Tile`/`Cascade`/`Float`/`Dock`/`TabTogether`;
drag-to-redock with drop-zone highlight; edge-drop splits a region; resizable splitters; and
`SaveLayout`/`LoadLayout` (arrangement only). Outcome: **mutual nesting (13b)** works.

**Scope & deliverables**
- `library/uimod/MDIContainer.mod` (completed): `Tile`, `Cascade`, `Float` (pop a doc subtree
  into a floater via `SetParent` + a new top-level window — uses S10), `Dock(side)`,
  `TabTogether`; tabbed strip drag-reorder; the four-edges-+-centre drop zones with highlight;
  edge-drop region split; resizable dock splitters — all implemented inside `DockLayout`'s
  `HitTest`/`Drag`/`DropAt`.
- `DockLayout.Save`/`Load` (the stateful strategy serializes its dock tree); `MDIContainer
  .SaveLayout`/`LoadLayout` — **arrangement only, never content**; the app re-supplies content
  by id (`supply` param, §10.4, §1).

**Dependencies:** S11.

**Exit criteria**
- **(CI) headless JIT** `t-90-272-savelayout.mod`: build a dock arrangement, `SaveLayout` to a
  blob, build a fresh container, `LoadLayout` with a content-`supply` Pane, assert the
  **arrangement** round-trips (doc ids, sides, splitter ratios) and content is re-supplied by
  id (not stored).
- **(CI) headless JIT** `t-90-273-dock-drop.mod`: synthesize a drag to each drop zone, assert
  `DropAt` returns the right `DropZone` and target rect (edge-drop splits; centre tabs).
- **(MANUAL, AOT) worked example 13b** (`demos/paneshell-13b.mod`): reactive chrome ⊃ MDI
  documents ⊃ a reactive document — file-tree sidebar (native-control leaf) beside an
  `MDIContainer` whose one document is itself a reactive `Split`; drag a document out to float
  it (`Float` → `SetParent` into a new window), redock it; the whole set works by hand.
- Conformance unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| Drag-to-redock + drop-zone highlight + `Float`/`SetParent` is the most interaction-heavy work (the part multiwingui lacks) | Split off from S11 as its own sprint; `DropAt`/drag is **(CI)** headless-tested by synthesized deltas before the hand-driven 13b demo |
| Deferred dock items (auto-hide/pin, BSP/grid tiling, multi-monitor guides) creeping into the substrate | They stay **behind the D7 hook** as future strategies, explicitly out of scope (Reserved backlog) |

**Open questions resolved:** **Q17.4** (Save format) — **decide here** (compact M2-native blob
vs text; either way arrangement-only). Closes the docking frontier to the Reserved-hook
backlog.

---

## 4. Showcase / proof sprint

### S13 — Rebuild `FastM2` on PaneShell (P7 — the existence proof, §16)

**Goal.** Port `FastM2` onto PaneShell as the proof-of-use (§15) — the role
`demo_multi_window.cpp` plays for multiwingui. Chrome becomes **reactive**; the editor area
becomes an **`MDIContainer`** of editor documents (delivering FastM2's "Not yet: Multiple
files/tabs"); the editor/output split becomes a **reactive `Split`**; and the compile/run
**output pane is the first threaded producer pane** (the compiler runs off-thread and streams
into the output pane's channel — the D2 seam, lit for one pane). Lives in `projects/`.

**Scope & deliverables**
- `projects/FastM2/FastM2.mod` (rebuilt; keeps its `<*GUI*>` pragma → `/SUBSYSTEM:WINDOWS`):
  - chrome (menu, status, sidebar, fixed editor/output divider) → a reactive `PaneLayout`
    (replaces FastM2's 11-line hand-computed `Layout` — three row-offset globals, hard-coded
    3:1 split, §3.2);
  - editor area → an `MDIContainer` of editor documents (delivers "Multiple files/tabs");
  - editor/output split → a reactive `PaneLayout.Split`;
  - output pane → `PaneShell.SetThreaded(out, TRUE)` (the **one** lit producer thread; the rest
    of the data plane stays inline — proves the seam without P8's full thread fan-out);
  - sidebar file list → a native-control leaf (`Surface.NewTree`).
- Consumes `Surface`, `PaneShell`, `PaneLayout`, `MDIContainer` + the in-place winrt surfaces.

**Dependencies:** S12 (needs all three facades + dock).

**Exit criteria**
- **(CI) headless JIT model test** `t-90-274-fastm2-docset.mod`: drive the FastM2 document-set
  *model* headlessly — `MDIContainer.AddDocument` two docs, `Activate` each, assert
  `ActiveDocument`, `CloseDocument` one and assert the set updates. So S13 has **at least one
  CI-enforced gate**, not only the manual app.
- **(MANUAL, AOT)** `newm2 build projects/FastM2/FastM2.mod` (the in-repo `library/` root is
  auto-discovered; the `--library library` flag is **redundant** here) produces `FastM2.exe`; it
  runs with reactive chrome around an MDI document area, **each document a reactive split**.
- **(MANUAL)** "Multiple files/tabs" (FastM2's listed "Not yet") delivered: open two `.mod`
  files as two MDI documents, switch/close tabs.
- **(MANUAL)** Compile a file: output **streams** into the threaded `out` pane without stalling
  the editor (the §7 no-head-of-line-blocking property, for the one lit pane). This is the
  **validation of the Q17.1 `Use`-model against threading**: the producer builds CPU cell
  buffers and submits to the channel; it never calls `Use`/the singleton procs (those stay
  UI-thread-only); present stays on the UI-thread consumer (§7).
- **(MANUAL)** Behavioural parity with the old FastM2 (compile/run via
  `RunProg.PerformCommand`, toolchain CONSTs unchanged) — verified by hand against the previous
  build.
- All `t-90-26x`/`27x` PaneShell tests + the full winrt demo set still green; conformance
  unchanged.

**Risks & mitigations**
| Risk | Mitigation |
|---|---|
| First real consumer exercising all three facades + native-control chrome + a threaded producer end-to-end (integration risk) | Each facade was already gated headlessly (S5–S12); S13 is integration, not new mechanism; the doc-set model is itself CI-gated (`t-90-274`) |
| The single threaded pane interacts badly with the `Use`-based current-instance model | Validated explicitly: the producer never calls `Use`/singleton procs — it submits CPU buffers to the channel; `Use` and present stay UI-thread-only (Q17.1 decision is gated against this here) |
| Behavioural parity while swapping the hand-rolled single-window layout | Port incrementally; keep the old layout in git history; diff behaviour against the prior `.exe` |

**Open questions resolved:** exercises Q17.5 in anger (may motivate richer control accessors —
flagged to the Reserved backlog). Confirms D2 (API unchanged when the one thread lights up) and
validates the Q17.1 single-thread `Use` model against the one threaded pane.

---

## 5. Sprint → design-phase mapping

| Sprint | Title | Design phase | Resolves (§17) | CI headless gate | Manual AOT gate |
|---|---|---|---|---|---|
| **S0** | Placement & scaffolding | — (placement decision) | sets up Q17.1–Q17.7 | `t-90-260` (+ `260b` neg.) | — |
| **S1** | Instance `Terminal`/`TermRender` | P1 (1/5) | **Q17.1** decided | `t-90-261` | — |
| **S2** | Instance `RasterView`/`Canvas2D` | P1 (2/5) | consumes Q17.1 | `t-90-262`, `262b` | canvas-coexist |
| **S3** | Instance `GameView`/`ShaderView` | P1 (3/5) | consumes Q17.1 | `t-90-263`, `263b` | shader-coexist |
| **S4** | Instance `GameViewGpu` (closes P1) | P1 (4/5) | Q17.1 discharged | `t-90-264` | gpu demo |
| **S5** | `Surface.Backend` + custom adapters | P2 (1/2) | sets up Q17.5 | `t-90-265` | (via S7 leaf demo) |
| **S6** | Native-control adapters + value API (closes P2) | P2 (2/2) | **Q17.5** decided | `t-90-266` | — |
| **S7** | `PaneShell` substrate + router + channel + **`Layout` iface** | P3 | **Q17.2** decided; opens Q17.6 | `t-90-267` | `paneshell-leaf` |
| **S8** | `PaneLayout` solver + `SplitLayout`/`StackLayout` | P4 (1/2) | — | `t-90-268` | `paneshell-split` |
| **S9** | Splitter drag + `TabLayout`; ex. 13a (closes P4) | P4 (2/2) | — | `t-90-269` | 13a |
| **S10** | Multiple top-level windows | P5 | — | `t-90-270` | multiwin |
| **S11** | `MDIContainer` = `DockLayout` (2nd strategy) | P6 (1/2) | Q17.3 consumed; sets up Q17.4 | `t-90-271` | 13a re-drag |
| **S12** | `DockLayout` interactions + Save/Load; ex. 13b (closes P6) | P6 (2/2) | **Q17.4** decided | `t-90-272/273` | 13b |
| **S13** | Rebuild `FastM2` on PaneShell | P7 | exercises Q17.5; confirms D2; validates Q17.1 vs threads | `t-90-274` (doc-set model) | FastM2 app |

*(Note: P1 splits into S1–S4 because the six renderers form a dependency chain — `GameViewGpu`
is layered on `ShaderView` — so the order is derived from the import DAG, §3.0, not the renderer
count; the `Layout` interface, which §8 places in the substrate, is delivered in S7, so P4/P6
need no substrate rewire.)*

---

## 6. Dependency graph (text)

```
S0  (placement & scaffolding)
│
├─ §3.0 P1 import-DAG audit  (locks the intra-P1 order from the real edges)
│
├─ S1  Terminal/TermRender ───┐         (TermRender ← Terminal, verified)
│                             ├─ (P1 instancing; S2 reuses S1's pattern & Q17.1)
├─ S2  Raster/Canvas   (←S1) ─┤
├─ S3  GameView + ShaderView (←S1) ─┐   (ShaderView is a standalone D3D leaf)
│                                   │
└─ S4  GameViewGpu  (←S3 ShaderView)┘   (closes P1; GameViewGpu LAYERS ON ShaderView — verified)
        │
        └─ S5  Surface.Backend + custom adapters
        │       (text-grid/canvas/raster need S1+S2; indexed/shader add as S3/S4 land;
        │        GPU-indexed selector needs S4)
                │
                └─ S6  control adapters + value API + Kind.Custom seam   (closes P2)
                        │
                        └─ S7  PaneShell substrate + router + channel + Layout INTERFACE (D7 declared)
                                │
                                ├─ S8  PaneLayout SplitLayout/StackLayout + solver   (←S7)
                                │       │
                                │       ├─ S9  splitter drag + TabLayout; ex.13a (closes P4)
                                │       │
                                │       └─ S10 multiple top-level windows  (←S7 AND S8)
                                │
                                └────────── S9 ∧ S10 ─────► S11  MDIContainer = DockLayout (2nd strategy)
                                                                  │
                                                                  └─ S12  DockLayout drag/float/dock + Save/Load;
                                                                          ex.13b  (closes P6)
                                                                          │
                                                                          └─ S13  rebuild FastM2 (P7, proof)
```

**Critical path:** `S0 → S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8 → S9, S10 ⇒ S11 → S12 → S13`.
Notes: within P1, S4 is **not** a free leaf — it depends on S3's `ShaderView`; S5's first
adapters need only S1+S2 (so the polymorphic-handle proof need not block on the GPU surfaces);
**S10 is parallelizable with S9 after S8 but must complete before S11** (S9 ∧ S10 are
co-requisites of the S11 join — `Float` needs multi-window).

---

## 7. Explicitly deferred — and the hook each attaches to

These are **out of scope for S0–S13** by design. Each is a *reserved hook* the substrate
already accommodates (the D7 "reserve the hook, ship a sensible default" discipline, §16), lit
up only when an app needs it — **not** a missing capability.

| Deferred item | Design phase | Attaches to (the hook) |
|---|---|---|
| Producer / per-pane render threads (light up `SetThreaded` panes beyond FastM2's one output pane; per-pane swapchain) | **P8** | the per-pane SPSC **channel** + `SetThreaded` seam declared **and CI dark-seam-tested** in **S7** (D2/§7); unchanged app API |
| Single-surface compositor (only if profiling justifies) | **P8** | same per-pane channel consumer; conditional on a measured need (Q17.7) |
| Flatten pure-structural splits (drop the intermediate host HWND) | P8-era optimization | the uniform "Pane = HWND" default (S7, Q17.2) — a *measured* optimization only |
| Per-`Backend` UIA accessibility provider | Reserved backlog (§16) | the `Surface.Backend` CLASS (S5/S6) — a new provider seam per Backend kind |
| IME / complex-text input (`WM_IME_*` to the focused pane) | Reserved backlog (§16) | the **event router** (S7) — reserves the IME path to the focused pane |
| DirectWrite-shaped rich/complex-text Backend (bidi, shaping, emoji, proportional rich text) | Reserved backlog (§16) | a new `Surface.Backend` **kind** (DWrite already wrapped) — a Backend, not a wall |
| Further `Layout` strategies (BSP / i3-sway tiling, grid, constraint solver, masonry, ribbon) | Reserved backlog (§16) | the `Layout` ABSTRACT CLASS (D7) **declared in S7** — a new strategy, substrate untouched |
| Rich-control typed accessors (listview columns, tree nodes) | Reserved backlog | the generic control value API (S6); typed subclasses the app downcasts to (Q17.5 revisit) |
| App-defined `Kind.Custom` Backend (the §6 leaf-spectrum extension point) | App extension | an app subclasses `Surface.Backend` directly and returns `KindOf = Custom` — proven slottable in S6; no framework constructor |
| Live layout inspector (devtools-style tree/rect/channel viewer + hover-highlight) | Reserved backlog (tooling) | the `DumpTree` **probe seam reserved in S7** — the inspector is a *tool* built on the reified tree, not a substrate change |

**Resolved-here open question still gated on a measured need:** **Q17.7** (when, if ever, to
light up producer threads / the compositor) — gated on profiling; only FastM2's single output
pane (S13) is lit during the planned sprints; the rest is P8.

---

## 8. Final deliverable note

This document (`docs/design/pane-shell-sprints.md`) is the final deliverable of the planning
effort. Execution begins at **S0**, whose own exit gate (`t-90-260-paneshell-smoke.mod`
printing `paneshell-scaffolding-ok` through `check()`, plus the `260b` negative-resolution
proof, with zero driver/loader edits) is the first concrete proof that the agreed placement is
correct. Every subsequent sprint is independently shippable behind the §0.3 Definition of Done
and the §0.5 gate-tier rule — at least one **CI-enforced** headless JIT test per sprint, with
windowed behaviour proven by **manual** AOT demos — and the family compiles after each one.

---

## Audit amendments (2026-06-18)

Findings from a codebase-grounding + design-soundness audit; each item names the section/decision it amends.

**I. Re-sequence — thin vertical slice after S1 (amends §3/§6 ordering; inverted-risk fix).**
The plan front-loads six sprints (S1–S6) of mechanical surface-instancing before the central
conjecture (Pane tree = HWND tree giving clip/hit-test/focus/relocation; one-router
serialization; the channel seam) is exercised **even once** — that is deferred to S7. Insert a
**thin vertical-slice sprint right after S1**: one instanced `Terminal` → a minimal text-grid
`Surface.Backend` → one `LeafPane` → one `PaneWindow` + the event router, proving HWND nesting
mirrors the Pane tree and a synthesized `WM_*` message routes to the right pane — at sprint **~3,
not ~8**. The remaining surfaces (S2–S4) + controls (S6) then fan **in** to an already-proven
substrate.

**J. Automated windowed smoke tier (amends §0.5/§0.6).** Nearly all differentiating value
(every `Paint`, every drag, all MDI float/dock, the concurrency payoff) currently sits on the
**MANUAL, not-regression-protected** side. Add a CI tier using **off-screen real HWNDs** (a real
top-level window positioned off-screen — which, unlike `HWND_MESSAGE`, D2D/DXGI accept), painting
a known pattern and reading back via `GetWindowRect`/`GetParent`/`ChildWindowFromPoint`/`GetDC`
pixel-sample or a back-buffer copy, exiting with a pass/fail code `cargo test` shells out to.
Make the load-bearing claims **falsifiable in CI**: (a) two backends coexist painting distinct
content in one window; (b) a synthesized click hit-tests to the **deepest** child Pane;
(c) `SetParent` relocates a subtree and descendants follow.

**K. Strengthen the D4 back-compat gate (amends §0.3 item 2 / S1–S5).** "Demo builds unchanged
**and** the winrt test re-runs green" cannot falsify the **new** behaviour the shim introduces
(lazy implicit default instance + shared current-instance `Use` state). Add a
**shim-equivalence test** (drive a surface through **both** the singleton-shim path and an
explicit `Create`/`Use` instance; assert identical observable state) plus an **interleave test**
(`Use(A)`; legacy-shim-op; assert it landed per the shim contract). Label the old-test re-run as
a **no-regression-of-known-behaviour** check, **not** proof of preservation.

**L. Lift a real concurrency gate to after S7 (amends S7/S13).** The SPSC channel is CPU-side
and headless — add a **CI test after S7** running an actual producer thread submitting buffers
to a pane channel, asserting ordering/non-loss/drain correctness **and** that a slow producer on
pane A does not delay drain of pane B (a measurable counter assertion). Give S13's "output
streams without stalling" criterion a **numeric** definition (e.g. the out pane advances N lines
while editor input round-trips under T ms). So **S13 becomes integration of a proven mechanism**,
not its first test.

**M. Name the D2D+D3D+CPU-coexist deliverable + falsifiable demo checklists (amends S7;
S9/S10/S12).** Make "a `Canvas2D` (D2D) leaf + a `ShaderView` (D3D) leaf + a `RasterView` (CPU)
leaf coexist and paint in one window without target/device clash" **one explicit** (ideally
automated-windowed, per item J) deliverable **pinned to S7** — stop letting `Attach`/`Paint`
forward-reference a demo defined only as "one leaf shown". Give **every MANUAL demo** a written
checklist of discrete observable assertions with expected results (e.g. 13a: "drag divider 100px
right → left pane width +~100px, never below `minFirst=240`; release → `EvSplitterMoved` fired
once").

**N. DWrite idempotency task explicitly into S2 (mirrors design item A).** Before instancing
`Canvas2D` + the text surfaces, make `DWrite.Startup` **idempotent** (`Ready()`-guarded) or keep
DWrite singleton-by-design; add a CI assertion that **two text/canvas instances do not clobber
the shared factory**.
