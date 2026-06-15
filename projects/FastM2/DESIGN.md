# FastM2 — a single-window Modula-2 IDE

A small, fast, single-window IDE for Modula-2 in the spirit of Turbo Pascal /
QuickBASIC — a menu bar, a full-screen code editor, an output pane, and a status
line — but rendered as a modern GUI (Direct2D, anti-aliased, mouse-aware) rather
than VGA text mode. **FastM2 is itself written in Modula-2**, on the same
WindowsModula2 stack it edits, and it drives the `newm2` toolchain to compile and
run what you type.

## Why this stack

Everything the IDE needs already exists in the library, so FastM2 is mostly glue:

| Need | Provided by |
|------|-------------|
| Window + message loop + window-proc callback | `WinShell` |
| Character cell grid, menus, status bar, drop-downs, event queue | `Terminal` |
| Direct2D/DirectWrite rendering of the grid (crisp, no GDI) | `TermRender` |
| Document buffer — O(log n) insert/delete | `TextRope` |
| Compile/run the edited program, capture its output | `RunProg.PerformCommand` (cmd.exe `/C`, output redirected to a temp file) |

The Terminal cell grid is the right model for a code editor (monospace, per-cell
colour = trivial syntax highlighting) and already carries the menu/status furniture;
TermRender makes it look modern. So FastM2 is "more of a GUI" via Direct2D rendering
+ mouse + drop-down menus, while keeping the text-mode IDE's speed and clarity.

## Layout (single window)

```
 File  Edit  Compile  Run  Help                                   <- menu bar (row 0)
+------------------------------------------------------------------+
| 1  MODULE Hello;                                                 |
| 2  FROM STextIO IMPORT WriteString, WriteLn;                     |  <- editor pane
| 3  BEGIN                                                         |     (gutter + code,
| 4    WriteString("hello"); WriteLn                               |      syntax-coloured)
| 5  END Hello._                                                   |
+--------------------------------------- Output ------------------+
| newm2: wrote Hello.exe                                          |  <- output pane
| hello                                                           |     (compiler msgs /
|                                                                |      program output)
+------------------------------------------------------------------+
 hello.mod *   Ln 5 Col 11    F2 Save  F9 Compile  F5 Run  Esc Menu   <- status bar
```

## Colour scheme (Turbo-Pascal-ish)

- Editor: bright text on **navy**; keywords **white/bold**, comments **grey**,
  strings **yellow**, numbers **aqua**, the rest **silver**.
- Menu bar / status bar: black on **grey**, highlighted item black on **cyan**.
- Output pane: light grey on near-black; error lines in **red**.
- Cursor: reverse video.

## Features (v1)

- **Editor** — type / Enter / Backspace / Del, arrows / Home / End / PgUp / PgDn,
  vertical + horizontal scroll, a line-number gutter. Buffer is a `TextRope`.
- **Selection + clipboard** — Shift+move or mouse click/drag selects (highlighted,
  spans line breaks); Cut / Copy / Paste / Select-All over the Windows clipboard
  (a `Clipboard` runtime module, CF_UNICODETEXT); typing/paste replaces the selection.
- **Search** — Find (case-insensitive, wraps), Replace (replace-all), and Goto-line,
  all via a status-line prompt; Ctrl+F / Ctrl+R / Ctrl+G.
- **Source > Format** — a structural re-indenter (two spaces per nesting level from
  the M2 block keywords; not a full pretty-printer).
- **Recent files** — an MRU list persisted to `fastm2_recent.txt`, shown in File.
- **Syntax highlighting** — a small Modula-2 tokeniser colours each visible line
  (keywords, `(* *)` comments incl. multi-line, `"…"`/`'…'` strings, numbers).
- **File** — New, Open…, Save, Save As… via the classic Windows common dialogs
  (a `Dialogs` runtime module over comdlg32); a "discard unsaved changes?" confirm;
  modified-flag and current file name in the status bar.
- **Compile (F9)** — save, run `newm2 build <file> --library <lib> > out 2>&1`,
  show the captured output; on a `file:line: error`, move the cursor to that line.
- **Run (F5)** — compile, and if clean run the program and show its output (GUI
  programs are launched detached).
- **Menus** — File / Edit / Search / Source / Build / Help drop-downs via `Terminal`'s
  `HandleKey`/`NextEvent` state machine, opened with **F10**, an **Alt** accelerator,
  or the **mouse** (new `Terminal.MenuBarHit`/`MenuPopupHit` hit-testing), plus the
  F-key + Ctrl-key shortcuts.
- **Resizing + split** — the window resizes without scaling: on `WM_SIZE` the grid
  is re-`Init`-ed to fit the client area at native cell size (via `TermRender.Resize`,
  which resizes the Direct2D target in place), so the text area grows/shrinks; layout
  is recomputed from the live grid. The editor/output split is draggable (grab the
  Output bar).
- **Status bar** — file name + modified flag, `Ln/Col`, key hints; doubles as the
  Find/Replace/Goto input line.

## Module structure

- `FastM2.mod` — the application: window + handler + main loop, editor state
  (TextRope + cursor + scroll), the syntax tokeniser, the output pane, and the
  compile/run glue. Built on `WinShell`/`Terminal`/`TermRender`/`TextRope`/`RunProg`.
- (Later) split the tokeniser and the editor core into their own modules if it grows.

## Compile/run mechanism

1. Write the buffer to `fastm2_work.mod`.
2. `RunProg.PerformCommand("<newm2> build fastm2_work.mod --library <lib> > fastm2_out.txt 2>&1", SyncExec, status)`.
3. Read `fastm2_out.txt` into the output pane; if `status # 0`, scan it for the
   first `…:<line>: error` and jump the editor there.
4. Run = the same with `run`, or launch the built `.exe` detached for GUI programs.

The compiler path + library path are CONSTs at the top (default `target\debug\
newm2-driver.exe` and the repo `library`), so FastM2 is run from the repo root for now.

## Not yet (kept simple, well-trodden ground)

Multiple files/tabs, undo/redo, project files, a debugger, and a strings/comments-
aware formatter. The editor buffer is a rope, so undo is cheap to add next.
