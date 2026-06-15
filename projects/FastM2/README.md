# FastM2

A single-window Modula-2 IDE in the spirit of Turbo Pascal / QuickBASIC — written
in Modula-2, on the WindowsModula2 stack it edits. Syntax-highlighted editor,
output pane, status line, and one-key compile/run driving the `newm2` toolchain.
Rendered with Direct2D (via `TermRender`), so it looks like a modern GUI rather
than VGA text mode. See [DESIGN.md](DESIGN.md) for the architecture.

## Build & run

```
newm2 build projects/FastM2/FastM2.mod --library library
projects\FastM2\FastM2.exe
```

The toolchain/library/work-file paths are CONSTs at the top of `FastM2.mod`
(`Compiler`, `LibPath`, `WorkFile`, `OutFile`) — edit them for your tree. They
default to this repo's layout under `e:\NewModula2`.

## Keys

| Key | Action |
|-----|--------|
| typing, Enter, Backspace, Del, Tab | edit |
| arrows / Home / End / PgUp / PgDn  | move + scroll |
| mouse click | place the cursor |
| **F10** | open the menu bar (arrows navigate, Enter selects, Esc/Tab back out) |
| **F2** | Save (to the current file) |
| **F3** | Open — the standard Windows Open-File dialog |
| **F9** | Compile — captures `newm2` output into the pane; jumps to the first error |
| **F5** | Run — compile, then run and show the program's output |

The **menu** (F10) gives File (New / Open… / Save / Save As… / Quit), Build
(Compile / Run) and Help (About). Open… and Save As… are the real Windows common
dialogs; Quit (or the window close button) exits — there is no quit-on-Esc, so a
stray Esc can't lose your work.

## Resizing

The window is freely resizable and **does not scale the text**: the character grid
grows or shrinks to fit the new client area at native cell size, so a bigger window
means more editable rows and columns (like a terminal), capped at the Terminal
model's 220×70 grid.

## How compile/run works

F9/F5 save the buffer to the current file, then run `newm2 build`/`run … > out
2>&1` through `RunProg.PerformCommand` (cmd.exe `/C`). The captured text is read
back into the output pane; a non-zero exit scans the output for `name:<line>:` and
moves the cursor there. Program stdout shows in the pane; launch GUI programs from
the built `.exe` for an interactive window.

## Dialogs

Open…, Save As… and the "discard unsaved changes?" prompt use the classic Windows
common dialogs via a new runtime module, `Dialogs` (`library/winrtdef/Dialogs.def`),
which wraps the generated comdlg32 / user32 bindings: `OpenFile`, `SaveFile`,
`ChooseColour`, `Message`, `Confirm`. It is general-purpose — any program on the
stack can use it.

## Highlighting

A small Modula-2 tokeniser colours each visible line: reserved words (white),
`(* … *)` comments incl. multi-line (grey), `"…"`/`'…'` strings (yellow), numbers
(aqua), everything else silver, on a Turbo-Pascal navy background.

## Status

Working IDE: syntax-highlighted rope editor, F10 drop-down menus, native Open/Save
dialogs, compile/run with error jump, and a resizable (text-growing) window. No
tabs / undo / find yet — the buffer is a `TextRope`, so those are cheap to add.
