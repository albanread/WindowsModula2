# FastM2

A single-window Modula-2 IDE in the spirit of Turbo Pascal / QuickBASIC — written
in Modula-2, on the WindowsModula2 stack it edits. A syntax-highlighted editor with
mouse + keyboard text selection and the system clipboard, find/replace, goto-line,
a source re-indenter, a recent-files list, drop-down menus (keyboard, Alt-keys, or
mouse), an output pane with a draggable split, and one-key compile/run driving the
`newm2` toolchain. Rendered with Direct2D (via `TermRender`), so it looks like a
modern GUI rather than VGA text mode. See [DESIGN.md](DESIGN.md) for the architecture.

## Build & run

```
newm2 build projects/FastM2/FastM2.mod --library library
projects\FastM2\FastM2.exe
```

FastM2 declares itself a windowed program with a **`<*GUI*>` pragma** at the top of
`FastM2.mod`, so it links for the Windows GUI subsystem (**no console window**) with
no build flag — `newm2` reads the pragma. (The `--gui` flag still works and forces
the same thing for a program without the pragma.) The toolchain/library/work-file
paths are CONSTs at the top of `FastM2.mod` (`Compiler`, `LibPath`, `WorkFile`,
`OutFile`) — edit them for your tree. They default to this repo's layout under
`e:\NewModula2`.

## Keys

| Key | Action |
|-----|--------|
| typing, Enter, Backspace, Del, Tab | edit |
| arrows / Home / End / PgUp / PgDn  | move + scroll |
| **Shift**+move | extend the selection |
| mouse click / drag | place the cursor / select text |
| mouse wheel | scroll the view (the cursor stays put; any key snaps back to it) |
| **Ctrl+X / C / V / A** | Cut / Copy / Paste / Select-All (system clipboard) |
| **Ctrl+F / R / G** | Find / Replace / Goto-line (prompts on the status line) |
| **F3** | Find Next (repeat the last search) |
| **Ctrl+N / O / S** | New / Open / Save |
| **F10** or **Alt+letter** | open the menus (F=File, E=Edit, S=Search, O=Source, B=Build, H=Help) |
| **F9 / F5** | Compile / Run — output to the pane, jump to the first error |

The **menu bar** is driven three ways: F10 then arrows/Enter, an Alt accelerator
that opens a menu directly, or the mouse (click a title, click an item). Menus:
**File** (New / Open… / Save / Save As… / recent files / Quit), **Edit** (Cut /
Copy / Paste / Select All), **Search** (Find… / Replace… / Goto Line…), **Source**
(Format), **Build** (Compile / Run), **Help** (About). Open… / Save As… are the
real Windows common dialogs; Quit (or the close button) exits — there is no
quit-on-Esc, so a stray Esc can't lose your work.

## Editing

Selection is the usual model — Shift+arrows or click-and-drag — highlighted in
blue, spanning line breaks. Cut/Copy/Paste use the **Windows clipboard** (a new
`Clipboard` runtime module over CF_UNICODETEXT), so text moves to and from other
apps. Typing or pasting replaces the selection.

**Find / Replace / Goto** prompt on the status line (Enter accepts, Esc cancels).
Find is case-insensitive and wraps around; Replace does replace-all. **Source >
Format** re-indents the buffer two spaces per nesting level from the M2 block
keywords (a quick structural tidy, not a full pretty-printer).

**Recent files** — the last few files you open or save are remembered (persisted to
`fastm2_recent.txt`) and listed at the bottom of the File menu.

## Resizing & the split

The window is freely resizable and **does not scale the text**: the character grid
grows or shrinks to fit the new client area at native cell size, so a bigger window
means more editable rows and columns (like a terminal), capped at the Terminal
model's 220×70 grid. The editor/output split is **draggable** — grab the "Output"
bar with the mouse and move it up or down to give the editor or the output pane
more room.

## How compile/run works

F9/F5 save the buffer to the current file, then run `newm2 build`/`run … > out
2>&1` through `RunProg.PerformCommand` (cmd.exe `/C`). The captured text is read
back into the output pane; a non-zero exit scans the output for `name:<line>:` and
moves the cursor there. Program stdout shows in the pane; launch GUI programs from
the built `.exe` for an interactive window.

## Runtime additions used here

FastM2 drives a few general-purpose runtime modules (usable by any program on the
stack), all written in M2 over the generated Win32 bindings:

- **`Dialogs`** — the classic common dialogs: `OpenFile`, `SaveFile`,
  `ChooseColour`, `Message`, `Confirm` (comdlg32 / user32). Used for Open…, Save
  As… and the "discard unsaved changes?" prompt.
- **`Clipboard`** — the system clipboard for Unicode text: `SetText`, `GetText`,
  `HasText` (CF_UNICODETEXT). Used for Cut / Copy / Paste.
- **`Terminal`** gained `MenuBarHit` / `MenuPopupHit` (mouse hit-testing) and
  `MenuSetFocus` (so the menu-bar highlight clears when you leave the menu);
  **`TermRender`** gained `Resize` (in-place Direct2D target resize); **`WinShell`**
  now sets the window-class cursor (so the launch "busy" cursor no longer sticks
  until you click — this fixes it for every windowed app on the stack).
- The compiler driver gained **`--gui`** (`/SUBSYSTEM:WINDOWS`, no console).

The **Help > About** box is an in-window popup (Modula-2 background + version);
it closes on Esc, a click, or after 8 seconds (a `SetTimer`/`WM_TIMER` auto-close).

## Highlighting

A small Modula-2 tokeniser colours each visible line: reserved words (white),
`(* … *)` comments incl. multi-line (grey), `"…"`/`'…'` strings (yellow), numbers
(aqua), everything else silver, on a Turbo-Pascal navy background.

## Status

A real little editor: syntax-highlighted rope buffer, mouse/keyboard selection and
the system clipboard, find/replace/goto, a source re-indenter, recent files,
keyboard/Alt/mouse menus, mouse-wheel scrolling, native Open/Save dialogs, a
draggable editor/output split, compile/run with error jump, and a resizable
(text-growing) window. Rendering is decoupled from input — keystrokes update state
and invalidate; the actual render happens once per `WM_PAINT`, so held keys
(autorepeat) stay responsive instead of lagging then jumping. No tabs or undo yet —
the buffer is a `TextRope`, so undo is cheap to add next.
