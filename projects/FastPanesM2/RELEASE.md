FastPanesM2 — a Modula-2 IDE (GPU TextGrid panes, on the PaneShell framework)
============================================================================

This is a SELF-CONTAINED release. Everything the IDE needs lives in this folder
and is found relative to FastPanesM2.exe — you can move/copy this whole folder
anywhere and it will still work.

  FastPanesM2.exe    the IDE
  newm2-driver.exe   the NewModula-2 compiler (the IDE runs it as a warm
                     background "daemon" for live checks + autocomplete, and
                     shells out to it for Build/Run). Found beside the IDE.
  library\           the M2 standard + Win32 + UI libraries the compiler
                     resolves imports from (passed as --library).
  sample.mod         the file opened on startup.
  cmpl_demo.mod      a tiny demo for autocomplete (an interface variable).

At runtime the IDE creates scratch files here (fastpanes_work.mod,
fastpanes_out.txt, ...). They are safe to delete.

RUN
---
Double-click FastPanesM2.exe (or run it from a terminal). On first use it
starts its own compiler daemon from this folder, so there is never any doubt
about "can the IDE see the compiler" — it is right next to the exe.

AUTOCOMPLETE
------------
* Type ".  after an object / record / module  -> a member list pops up.
    e.g. open cmpl_demo.mod, click the blank line in the body, type:  b.
    -> the methods of the Backend interface (Attach, Close, Paint, Resize, ...).
* Press F6 (or Ctrl+Space) anywhere -> completes the identifier being typed
    from everything in scope (procedures, types, variables, ...).
* In the popup: Up/Down to move, Enter/Tab to accept, Esc to cancel; keep
    typing to narrow the list.

Note: `FROM Mod IMPORT x` brings `x` into scope (so F6/Ctrl+Space completes it)
but does NOT make `Mod.` complete — only `IMPORT Mod;` does. This is standard
Modula-2 scoping, not a bug.

KEYS
----
  F6 / Ctrl+Space  autocomplete        F9  build         F5  run
  F7  analyze (NEW/DISPOSE)            F8  run + heap guard
  F3  find next     Ctrl+F find        Ctrl+P  command line (ptcl)
  F10 menu          Ctrl+S save        Ctrl+O open        Ctrl+Z/Y undo/redo
