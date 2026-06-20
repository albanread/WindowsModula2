# FastPanesM2

The FastM2 Modula-2 IDE, rebuilt on the **PaneShell** GUI framework.

The original [`projects/FastM2`](../FastM2) — a single ~1300-line Direct2D/TermRender
monolith on `WinShell` — is kept untouched. FastPanesM2 is a clean front-end on the
*Pane-as-currency* stack (`library/uidef` + `library/uimod`):

```
Split(Horizontal, 0.22)            reactive chrome
├─ sidebar  = NewTree()            file list (native control)
└─ editor   = MDIContainer(Tabbed) document area
      └─ doc = Split(Vertical, 0.72)         a reactive split document
            ├─ source = NewEdit(TRUE)        source editor  (native multiline edit)
            └─ output = NewEdit(TRUE)        build output
```

Every leaf is a **native control**, so editing (caret, selection, clipboard,
scrollbars) and resize come for free from the OS — the HWND tree is a projection of
the Pane tree.

## Keys (while a pane has focus)

| Key | Action |
|-----|--------|
| `B` | Build the active document (compile its source pane, show output) |
| `F` | Float the active document into its own window |
| `T` | Tile the documents |
| `C` | Cascade the documents |
| window `X` | Close (clean `EvCloseRequest` → `Quit`) |

## Build

From the repo root (`e:\NewModula2`):

```
target\debug\newm2-driver.exe build projects/FastPanesM2/FastPanesM2.mod ^
  --library library --out projects/FastPanesM2/FastPanesM2.exe
projects\FastPanesM2\FastPanesM2.exe
```

## How "Build" works

Pressing `B` reads the active source pane (`Surface.GetText`), writes it to a scratch
`.mod` (`NM2File.WriteText`), runs the compiler via `RunProg.PerformCommand`
(`newm2-driver build … --library … > out.txt 2>&1`), reads the captured output back,
and shows it (success or compiler errors) in the document's output pane. This reuses
the **same shared library modules** the original FastM2 uses (`RunProg`, `NM2File`) —
imported by name, with no import of or edit to FastM2 itself.

## Status / roadmap

- **Done:** the IDE shell, native-control editors, working Build (compile + output),
  float/tile/cascade, clean close.
- **Next:** sidebar click → open file into a document (`Dialogs.OpenFile`); a syntax-
  highlighted `NewTextGrid` editor once the PaneShell paint pump lands (then extract
  the FastM2 tokeniser into a shared `library/util*/M2Lex` both IDEs import).
