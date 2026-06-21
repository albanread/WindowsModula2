# FastPanesM2 — Project support (folder-as-project)

## Principle: the compiler already IS the project system

The Modula-2 compiler builds a whole multi-file program by **following imports**
from one entry module (`newm2-loader` BFS over IMPORT clauses; `build <main.mod>
--library library` compiles the entire reachable graph). There is no manifest,
no file list, no build config — the imports *are* the file list.

So "project support" is **not** new build machinery. It is an IDE-side *view*
over a folder plus a tiny bit of state. This is what keeps it un-clunky: you
never maintain a project file or an "add existing item" list — you open a folder
and edit; the compiler figures out what to build.

What the IDE must track (all of it):
- **project root** — a folder.
- **build target** — which `.mod` is the PROGRAM module to build/run (one path).
- **open documents** — the files you have open in tabs.
- *(optional)* a one-line `.fastpanes` file recording a non-obvious build target,
  written only if the user overrides the auto-detected one. Convention first.

## Layout (wider, three regions)

Default window **1280×800** (was 1000×720).

```
root = Split(Horizontal, 0.18, sidebar,
             Split(Vertical, 0.76, editor, output))
```

```
+----------------+-------------------------------------------+
|  PROJECT       |  file1.mod  file2.def* | x   (tab strip)   |
|  ▾ src         |-------------------------------------------|
|    Main.mod  ◀ |  1  MODULE Main;                          |
|    Util.def    |  2  ...               (editor)            |
|    Util.mod    |                                           |
|  ▸ demos       |-------------------------------------------|
|  README.md     |  build ok / errors    (output)           |
+----------------+-------------------------------------------+
```

- **Sidebar** = a GPU TextGrid (same renderer as the editor, consistent look) —
  the file/project tree.
- **Editor** = a one-row **tab strip** (open files) above the existing editor.
- **Output** = unchanged.

All three are PaneShell `Split` leaves; the sidebar/editor and editor/output
dividers are draggable (already supported). Resize reflow already works.

## File/project browser (the sidebar)

Rendered as text in the sidebar TextGrid using `DirIter` (Open/Next/Close —
already filters `.`/`..`, returns name + isDir) and `PathStr` (Join/BaseName/Ext):

- Folders show `▸`/`▾` and expand/collapse on click; files are indented.
- `.mod`/`.def` are the first-class citizens (coloured); other files dimmer;
  build artifacts (`*.exe`, scratch) hidden.
- **Lazy**: a folder's children are read on first expand, not all upfront.
- Click a file → open it (new tab, or switch if already open).
- The build-target module gets a marker (e.g. `◀` or bold).

A flat model backs it: an array of visible rows `{depth, name, path, isDir,
expanded}`; expand/collapse rebuilds the visible-row list; render walks it with
`top`-scroll like the editor.

## Multi-file editing (the document model)

The editor today is one buffer in globals (`line[]`, `nLines`, `curRow`, …, undo
stacks). Multi-file keeps **one editor engine** and swaps documents in/out of it —
far less invasive than N live editor panes, and it reuses the undo serializer.

```
Doc = RECORD
  path:   ARRAY OF CHAR
  text:   <serialized buffer blob>   (* reuses SerializeTo / ApplyBuf *)
  curRow, curCol, top, gLeft: CARDINAL
  dirty:  BOOLEAN
END
gDocs: ARRAY [0..MaxDocs-1] OF Doc;  gActiveDoc: CARDINAL
```

- The live globals = the **active** doc's working set.
- **Switch doc**: serialize the live buffer → `gDocs[old]`; deserialize
  `gDocs[new]` → the live globals; re-render. (`SerializeTo`/`ApplyBuf` already
  exist for undo, so inactive docs cost only their text size, not the full 2D
  array.)
- **Tab strip**: open docs as tabs; click or Ctrl+Tab to switch; `•` dirty
  marker; `x` to close (prompt if dirty).
- Undo/redo: per-doc (kept in the Doc) so history survives a tab switch.

(The classic look — tabs on top — is a small custom strip drawn in the editor
grid, not a separate native control, so it matches the GPU aesthetic. PaneShell's
`TabLayout` is the alternative but it wants one real pane per tab, which would
fork the editor engine; the swap-in/out model is simpler and lighter.)

## Build / Run with a project

- `gBuildTarget` defaults to the **auto-detected PROGRAM module** in the project
  (scan the root for `MODULE X;` with a body; if exactly one, use it; if several,
  the user picks; if none, fall back to the active file).
- **Save-all-then-build**: F9/F5 save every dirty doc, then build/run
  `gBuildTarget` — the compiler follows imports and compiles the whole project.
- **Cross-file errors**: a diagnostic names its module; clicking it opens that
  file's tab and jumps to the line (the daemon already reports per-module
  diagnostics).
- "Set as build target" — a tree context action / Build-menu item; writes
  `.fastpanes` only when overriding the auto-detect.

## Opening a project

- **File → Open Folder** (folder picker) sets the root + populates the tree.
- CLI: `FastPanesM2.exe <folder-or-file>`.
- Default on launch: the exe's own folder (so the release "just opens itself").
- *(later)* a recent-projects list.

## Phasing (ship value incrementally)

- **P1 — Sidebar + wider window.** 1280×800; the sidebar tree (browse + expand);
  clicking a file opens it in the existing single editor (prompt-to-save on
  replace). No doc model yet. *Immediately useful, low risk.*
- **P2 — Documents + tabs.** The Doc table + tab strip; multiple files open at
  once; per-doc undo; dirty markers; close.
- **P3 — Project-aware build.** `gBuildTarget` auto-detect + override; save-all
  build/run of the target; cross-file error jump.
- **P4 — Niceties.** New file/folder in the tree, rename/delete, `.fastpanes`
  target persistence, recent projects, filter/find-in-files.

## Non-goals (the anti-clunky guardrails)

- No mandatory project file. No project wizard. No manually-maintained file list
  (imports are the list). No build-configuration matrix. A folder is a project;
  the compiler does the rest.
