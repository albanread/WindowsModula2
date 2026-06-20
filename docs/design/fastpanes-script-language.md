# FastPanesM2 Script Language — design & vocabulary

**Working name:** `ptcl` (PaneShell Tcl) — a small Tcl dialect embedded in FastPanesM2.
**Status:** design draft (no implementation yet). Decisions marked **[OPEN]**.
**Author/date:** 2026-06-20.

---

## 1. Why Tcl (the conclusion)

A script language for this IDE has to serve two jobs that pulled in opposite
directions during design:

- **Actions** — "open this, find that, build, jump." Inherently *sequential*.
- **Wiring** — "on save → build", "F9 → rebuild", "when build fails → jump."
  Inherently *reactive/declarative*, and it mirrors the substrate (events → model
  → view) we already have.

Tcl dissolves the tension instead of picking a side:

- **It is an embeddable command language by design.** Tk was just its first host;
  FastPanesM2 is the same shape — an app with a verb vocabulary that wants glue.
  We are *adopting* the language built for this, not inventing one.
- **There is almost no syntax to commit to.** One rule: `command arg arg …`. Even
  `if`/`while`/`proc` are ordinary commands. (This is the answer to "I don't know
  what syntax I feel like" — there is barely any.)
- **One language is both a live REPL and a file format.** You type `build` at a
  command line *and* check in an `init.ptcl`. No split between "interactive" and
  "config".
- **`{ }` (a deferred script) gives declarative wiring for free.** `bind F9 {build}`
  and `on save {build; if {[errors]} {goto [first-error]}}` *are* the
  declarative-wiring-over-imperative-bodies hybrid — the reactive handler is just a
  string of the same language. This is exactly Tk's `bind` model.
- It is none of the rejected options: not BASIC, not PowerShell, not bash, not
  Forth stack-juggling, not Lisp parens.

### The convergence payoff

**The primary surface is automation, not the human REPL.** ptcl is mainly a way to
send commands to a *running* application over a channel (stdio / pipe / COM — §5);
the interactive command line is just one client of that same protocol.

The verb vocabulary below is **one surface with three consumers**:

1. the **user**, live, at the command-line pane (REPL);
2. **config/automation** files (`init.ptcl`, project scripts);
3. the **agent harness** — the same verbs the screenshot/sendkeys loop drives,
   now over a channel rather than synthetic events.

"Introspectable", "scriptable", and "agent-drivable" stop being three properties
and become *the same vocabulary*. That is the real prize. See §5 for the channels.

---

## 2. Language core (the interpreter)

A faithful-enough Tcl. Everything is a string; everything is a command.

### 2.1 Lexical structure

- A **script** is a sequence of **commands** separated by newlines or `;`.
- A **command** is a list of **words** separated by whitespace; word 0 is the
  command name, the rest are arguments.
- `#` begins a comment **only where a command would start** (Tcl rule).
- `\` escapes the next char (`\n \t \\ \$ \[ \{ \;` …).

### 2.2 The four substitutions (the whole syntax, really)

| Form        | Meaning                                                        |
|-------------|---------------------------------------------------------------|
| `$name`     | variable substitution — splice the variable's string value    |
| `[script]`  | command substitution — run `script`, splice its **result**    |
| `"…"`       | grouping **with** `$`/`[]`/`\` substitution; spaces stay       |
| `{…}`       | grouping **without** substitution — a literal/deferred block   |

`{…}` is the keystone: it defers a script unevaluated, which is how bodies
(`proc`/`if`/`while`) and event handlers (`bind`/`on`) are passed around.

### 2.3 Values

- Everything is a **string**. A "list" is a string of brace/whitespace-delimited
  words; a "number" is a string `expr` happens to read as numeric.
- **[OPEN]** dict support (`dict get/set`) — phase 4, only if needed.

### 2.4 Built-in commands (the control + data core)

Phased so we ship something runnable early.

**Phase 1 (minimum viable interpreter):**
`set` · `proc` · `return` · `if`/`elseif`/`else` · `while` · `incr` · `expr` ·
`puts` · `eval` · (comments).

**Phase 2:**
`for` · `foreach` · `break` · `continue` · `unset` · `catch` · `string` (length,
index, range, match, first, equal) · `list`/`lappend`/`lindex`/`llength`.

**Phase 4 (as needed):**
`global`/`upvar` · `dict` · `switch` · `source` · `after`.

### 2.5 `expr` (the one fiddly part)

`expr {…}` evaluates a small infix expression language (NOT command syntax):
`+ - * / %`, comparisons `< <= > >= == !=`, logical `&& || !`, parens, integer
and string literals, `$var`. Start with integers + comparisons (enough for
`if {[errors] > 0}`); grow later. Stubbing this minimally first is the pragmatic
path. **[OPEN]** float support, string ops in expr.

### 2.6 Scoping & errors

- Global scope + a fresh local frame per `proc` call. `global`/`upvar` deferred.
- `catch {script} ?var?` returns 0/1 and captures the result/error — the basis of
  robust automation. Uncaught errors abort the current command and print to the
  output pane in red (reusing the error-line rendering).

### 2.7 Data structures the interpreter needs (M2 implementation notes)

- A **value** = a growable string (heap-backed; do *not* use one giant fixed
  array — see the compiler caveat below).
- A **command table**: name → (builtin fn | proc body). Hash or sorted array.
- A **variable store** per frame: name → value. Hash.
- A **call stack** of frames for `proc`.
- Reuse `library/` collections / `Heap` / dynamic-string facilities from the
  stdlib roadmap. **CAVEAT:** the compiler currently segfaults on fixed array
  *element* types larger than ~32–64 KB (see `compiler-required-fixes` #4), so the
  value/string store must be heap-allocated growable, not a big fixed buffer.

---

## 3. The verb vocabulary (the "Tk" layer)

These are the IDE commands `ptcl` registers. Each is a thin wrapper over an
existing FastPanesM2 reactive op, so implementation is mostly "register name →
call proc". Tcl convention: lowercase, return a **string** result (empty if
none); predicates return `0`/`1`. No `?`-suffixed names (not Tcl).

### 3.1 File / buffer

| Command            | Returns      | Effect / notes                              | Backed by |
|--------------------|--------------|---------------------------------------------|-----------|
| `new`              | —            | clear to an empty buffer                    | `NewFile` |
| `open ?path?`      | path         | load `path`; no arg → Open dialog           | `LoadFile`/`OpenDialog` |
| `save`             | path         | save current file                           | `Save`/`SaveTo` |
| `saveas ?path?`    | path         | save under a new name; no arg → dialog      | `SaveAs` |
| `file`             | path         | current file name (`""` if untitled)        | `gFile` |
| `dirty`            | `0`/`1`      | unsaved changes? **[OPEN]** need a dirty flag | new |

### 3.2 Navigation & search

| Command            | Returns        | Effect                                    | Backed by |
|--------------------|----------------|-------------------------------------------|-----------|
| `goto line ?col?`  | —              | move cursor (1-based)                      | set `curRow/curCol` |
| `cursor`           | `"line col"`   | current position (1-based, 2-elt list)     | `curRow/curCol` |
| `home` / `lineend` | —              | column 0 / end of line                     | Home/End |
| `find pat`         | `0`/`1`        | search forward from cursor, wrap; selects  | `DoFind` |
| `findnext`         | `0`/`1`        | repeat last `find`                          | `FindNext` |

### 3.3 Editing

| Command            | Returns | Effect                                       | Backed by |
|--------------------|---------|----------------------------------------------|-----------|
| `insert text`      | —       | insert `text` at the cursor (may contain \n) | `InsertCh`/`NewLine` |
| `type text`        | —       | alias of `insert` (intent: simulate typing)  | — |
| `backspace ?n?`    | —       | delete `n` chars left (default 1)            | `Backspace` |
| `delete`           | —       | delete the selection (no-op if none)         | `DeleteSel` |
| `undo` / `redo`    | —       | one step                                     | `DoUndo`/`DoRedo` |

### 3.4 Selection & clipboard

| Command                  | Returns | Effect                                   | Backed by |
|--------------------------|---------|------------------------------------------|-----------|
| `select r1 c1 r2 c2`     | —       | set anchor (r1,c1) + cursor (r2,c2)      | `gAnch*`/`cur*` |
| `selectall`              | —       | whole buffer                             | `SelectAll` |
| `selection`              | text    | the selected text (`""` if none)         | `CopySel` core |
| `copy` / `cut` / `paste` | —       | clipboard ops                            | `CopySel`/`CutSel`/`PasteClip` |

### 3.5 Build / run / inspect

| Command            | Returns         | Effect                                          | Backed by |
|--------------------|-----------------|-------------------------------------------------|-----------|
| `build`            | `0`/`1` (ok)    | compile the buffer; sets error markers          | `Build`/`Compile` |
| `run`              | `0`/`1`         | compile + run; program output → output pane     | `DoRun` |
| `errors`           | count           | number of error lines from the last build       | `gNErr` |
| `error n`          | `"line col msg"`| the n-th diagnostic                             | parse `gOut` |
| `first-error`      | line            | line of the first error (0 if none)             | `JumpToError` core |
| `dump sub`         | text            | `tokens ast sema cfg ir llvm asm` → output pane | `Dump` |

### 3.6 Introspection (the agent/scriptability convergence)

| Command       | Returns                          | Notes                                  |
|---------------|----------------------------------|----------------------------------------|
| `text`        | whole buffer as a string         | `SerializeTo`                          |
| `line n`      | the text of line `n`             |                                        |
| `linecount`   | number of lines                  | `nLines`                               |
| `state`       | `cursor=… sel=… file=… mode=…`   | dict-ish; for scripts/agents to assert |
| `panetree`    | `id:kind(rect)[children]`        | `PaneShell.DumpTree` — structure probe |

### 3.7 UI / meta / wiring

| Command                | Returns | Effect                                            |
|------------------------|---------|---------------------------------------------------|
| `status msg`           | —       | set the status-line message                       |
| `bind key {script}`    | —       | run `script` when `key` is pressed (see §4)       |
| `on event {script}`    | —       | run `script` when `event` fires (see §4)          |
| `menu path {script}`   | —       | **[OPEN]** add a user menu item bound to a script |
| `source path`          | —       | read & eval a script file                         |
| `quit`                 | —       | close the IDE (`EvCloseRequest`)                  |

---

## 4. Events & reactive wiring

`bind`/`on` store a deferred `{ }` script keyed to an event; when the substrate
fires that event, the IDE evals the stored script. The script *is* the reactive
handler — same model as the hardcoded `OnEvent`, just data-driven.

### 4.1 Bindable keys (`bind`)

`bind F9 {build}`, `bind Ctrl-S {save}`, `bind F5 {run}`. Key names map to the
VK/char the substrate already delivers (`F1`..`F12`, `Ctrl-X`, `Enter`, `Esc`,
arrows). A `bind` overrides/extends the built-in keymap.

### 4.2 Semantic events (`on`)

| Event            | Fires when…                         | Substrate source         |
|------------------|-------------------------------------|--------------------------|
| `open`           | a file was loaded                   | after `LoadFile`         |
| `save`           | a file was saved                    | after `Save`             |
| `change`         | the buffer was edited               | the edit mutators        |
| `cursor`         | the cursor moved                    | nav handlers             |
| `build.ok`       | a build succeeded                   | `Compile` st=0           |
| `build.failed`   | a build produced errors             | `Compile` st≠0           |
| `close`          | the window is closing               | `EvCloseRequest`         |
| `resize`         | a pane resized                      | `EvResize`               |

### 4.3 Examples

```tcl
# keymap
bind F9 {build}
bind F5 {run}
bind Ctrl-B {dump ast}

# reactions
on build.failed {goto [first-error]}
on save         {build}                  ;# build-on-save

# a macro = a proc = a new command
proc check {} {
    save
    if {[build]} {
        status "built OK"
    } else {
        goto [first-error]
        status "[errors] error(s)"
    }
}
bind F7 {check}

# batch edit: append a trailing comment to every line that has "TODO"
foreach n [range 1 [linecount]] {
    if {[string match *TODO* [line $n]]} {
        goto $n [string length [line $n]]
        insert "  (* seen *)"
    }
}
```

---

## 5. Automation channels (the PRIMARY surface)

ptcl is, first and foremost, a **wire protocol**: commands in, results out, both
strings. A human at a REPL is just one client. The whole external interface
collapses to a single operation:

```
Exec(command: string) -> result: string
```

Everything else — every verb, every reaction — lives in the *vocabulary*, not the
interface. That one fact keeps every transport trivial and keeps complex objects
(`Pane`, `Event`) OFF the wire: they never need marshalling; you ask for `cursor`
or `state` and get strings back.

### 5.1 Transports (one vocabulary, several pipes)

| Transport                       | Use                                                         | Status |
|---------------------------------|-------------------------------------------------------------|--------|
| **stdio**                       | spawn-and-drive a child app (the agent harness today)       | trivial |
| **named pipe / TCP loopback**   | attach to a running app from another process; the IDE↔compiler channel | `Socket`/`SocketServer`/`RecvAll` already exist |
| **COM (out-of-proc + ROT)**     | Windows-native "attach to the running GUI"; COM-tool interop | ~90% of the M2 machinery present (see §5.3) |

All three carry the **same** `Exec` string protocol. Framing: a 4-byte length
prefix for multi-line results (dumps); JSON only if/when we multiplex.

### 5.2 Clients (one vocabulary, three consumers)

- the **user**, live, at the command-line pane (a `wish`-style REPL);
- **config/automation** — `init.ptcl` `source`d at launch (the `.vimrc`/`init.el`
  analogue), plus `source path` for project scripts/refactors/tests;
- the **agent harness** — drives the SAME verbs it already screenshots, now over a
  channel instead of synthetic events.

### 5.3 GUI as a COM automation server  *(the exciting one)*

Goal: an external tool (agent, script, COM-aware app) attaches to the
ALREADY-RUNNING IDE and drives it. COM earns its complexity here — and *only* here:

- **Attach-to-running is native.** The GUI calls `RegisterActiveObject` at startup;
  clients `GetActiveObject(CLSID)` to grab the live instance via the Running Object
  Table. No hand-rolled discovery.
- **STA auto-marshals onto the UI thread.** The GUI is a single-threaded apartment
  with a message pump, so an inbound COM call is delivered *on the UI thread* — the
  handler touches panes/the buffer directly, no cross-thread queue.

Design: **ONE narrow dual interface with a single `Exec` method** into the ptcl
interpreter — NOT a per-verb COM surface (needs a recompile per verb) and NOT
IDispatch property synthesis (chatty, and would force marshalling `Pane`/`Event` as
VARIANTs). Single-`Exec` gets ROT discovery + marshalling for free.

Exists vs net-new (investigation, 2026-06-20):
- **Exists:** M2 classes are already COM-ABI vtable-compatible — proven by
  `t-90-110-com-server` (an external driver calls M2 class methods through the COM
  calling convention; QI/AddRef/Release/custom all work). COM *client* is complete
  (`Com.mod`/`Guid.mod`/`Dispatch.mod`).
- **Net-new (well-scoped: M2 + a small runtime seam):** a hand-written
  `IClassFactory`; a `CoRegisterClassObject` binding (no runtime seam yet); a
  hand-written `IUnknown` impl (QI/AddRef/Release) on one coclass exposing `Exec`;
  a `RegisterActiveObject`/ROT binding. We can **skip** the unbuilt `CLASS IMPLEMENTS`
  / IDispatch-synthesis compiler features entirely — one coclass, one method,
  hand-written, is enough.
- **Guards:** a per-call `RPC_E_CALL_REJECTED` busy reply for STA re-entrancy (the
  substrate has already hit re-entrancy UAFs); NEVER run a long build on the UI
  thread (hand it to the compiler service); producer side is AOT-only for now.

### 5.4 Compiler as a resident service  *(the fast channel)*

Goal: the IDE talks to a warm, resident compiler instead of spawning
`newm2-driver.exe` (+ LLVM init + temp-file redirect) per build/dump.

Verdict from the investigation: make it a **resident text service, NOT COM.** No UI
thread, no message pump, no attach-to-running need → COM there is pure ceremony.
The win is the *warm process* (no respawn, no LLVM re-init, warm sema cache);
transport latency is noise next to compile time.

Crucially, the compiler is **already re-entrant**: each invocation is
self-contained (parse → sema → codegen → link), the LLVM `Context` is created fresh
per operation, and the only process-global is an idempotent `LLVM_INITIALIZED`
`Once`. So a daemon is low-risk.

Design:
- Extract `run_build` / `run_dump_*` into `pub fn compile(CompileRequest) ->
  CompileResponse` in a driver lib crate; `main()` calls it (prove re-entrance with
  a test that calls it N times).
- `newm2-driver --daemon` over a named pipe (or TCP loopback first, since
  `Socket`/`SocketServer`/`RecvAll` already exist): read a request, `compile()`,
  write the response (4-byte length frame).
- FastPanesM2 gains `CompileViaService` (open channel, send, read, parse
  diagnostics) — falls back to spawn if the daemon is absent/slow.
- **Guards:** `catch_unwind` around `compile()` so one bad compile can't kill the
  daemon; IDE timeout + auto-restart + spawn fallback; a handshake token (or
  per-user-DACL named pipe) since loopback TCP is open to any local process; watch
  for any future LLVM `Context` caching or non-deterministic codegen.

### 5.5 The symmetry

We already CONSUME COM (client). These two moves make M2 a full COM *peer* (GUI
server) and make the toolchain itself a service (compiler daemon) — "COM-friendly
Windows-native language", earned in both directions, but applied with a scalpel:
COM where attach-to-running + STA marshalling pay for it (the GUI), a plain text
pipe where they don't (the compiler). Both ends speak the same string vocabulary.

### 5.6 Build order for the channels
1. **Compiler resident service** — DECIDED FIRST (user, 2026-06-20): it's the one
   thing that makes the fast IDE actually *feel* fast. Independent Rust track,
   lowest risk (the compiler is already re-entrant).
2. ptcl interpreter core + REPL pane (prerequisite for any GUI `Exec`).
3. GUI `Exec` over a pipe (cheap; immediately upgrades the agent harness).
4. GUI `Exec` over COM + ROT (the Windows-native attach-to-running layer).

**Transport: named pipe** (user preference, 2026-06-20) — `\\.\pipe\newm2`, per-user
DACL, no port, no loopback-exposure. TCP loopback stays a fallback; the 4-byte-length
framing is identical either way.

### 5.7 Symmetry: ptcl is the whole toolchain's language

Decision (user, 2026-06-20): **the compiler daemon speaks ptcl too** — not a bespoke
build protocol, the *same* language as the GUI with a compiler-flavoured verb table.
One language drives the editor AND the toolchain; an agent (or you) learns one
vocabulary for everything.

How symmetry stays honest without coupling two runtimes:
- **Shared spec, two small implementations.** The ptcl *core* (tokenizer + the four
  substitutions + `set/proc/if/while/expr`) is deliberately tiny — that is the whole
  reason we picked Tcl. M2 implements it for the GUI; Rust implements the same core
  for the daemon. A **shared conformance corpus** (`.ptcl` scripts + expected
  results, run against both) keeps the dialects from drifting.
- **Same syntax from day one, full evaluator later.** The daemon's MVP needs only the
  ptcl *reader* (tokenise a command line, dispatch to a verb) — a strict subset of
  the same language, ~a couple hundred lines of Rust. The full evaluator (so you can
  send the compiler a *script*: `foreach f $deps {dump ir $f}`) is a later, optional
  deepening — same language, more of it.
- **The GUI's `build` becomes a proxy.** `build` in the editor is literally "forward
  `build $file` to the compiler daemon over the pipe and show the result." No build
  logic is reimplemented in the GUI; it's one ptcl service calling another.

So ptcl becomes the M2 toolchain's automation bus: any future tool (debugger,
profiler, package manager) joins by embedding the core, registering its verbs, and
exposing `Exec` over a pipe/COM.

### 5.8 Compiler daemon vocabulary

The daemon registers compiler verbs (the analogue of §3's GUI verbs). Results are
strings; structured results are **ptcl lists** — still strings, still "everything is
a string", but parseable (`{line col sev msg}` tuples), so the IDE gets exact,
multi-error diagnostics instead of scraping text.

| Command              | Returns                          | Notes |
|----------------------|----------------------------------|-------|
| `check path`         | list of `{line col sev msg}`     | parse + sema ONLY, no codegen — the fast path for as-you-type checking |
| `build path ?opts?`  | `{ok diags outfile}`             | full compile to obj/exe |
| `run path`           | `{ok output diags}`              | build + execute, capture stdout |
| `dump sub path`      | text                             | tokens/ast/sema/cfg/ir/llvm/asm (feeds the inspector pane) |
| `symbols path`       | list of `{name kind line}`       | outline / go-to-symbol (future pane) |
| `deps path`          | list of module names             | dependency graph |
| `version` / `ping`   | string                           | handshake / liveness |
| `shutdown`           | —                                | stop the daemon |

`check` is the single biggest "feels fast" lever: sema-only, no codegen/link, so the
IDE can validate on a keystroke pause and paint markers live — far faster than the
current spawn-a-full-build-per-F9, and it feeds the §3.5 error-marker machinery with
*structured* diagnostics instead of text-scraped `line N, column M`.

---

## 6. Implementation plan (phased, each harness-verified)

1. **Interpreter core** — tokenizer + the 4 substitutions + command dispatch +
   `set`/`proc`/`if`/`while`/`incr`/`expr`(int)/`puts`/`eval`, plus a
   command-line pane REPL. Deliver: type `set x 2; puts [expr {$x*21}]` → `42`.
2. **Verb vocabulary** — register §3 commands over the existing reactive ops.
   Deliver: `open …; find X; build` works from the REPL; snapshots verify.
3. **Wiring** — `bind`/`on` with deferred scripts + `source` + `init.ptcl` at
   launch. Deliver: an `init.ptcl` that rebinds F9 and adds build-on-save.
4. **stdlib growth** — `foreach`/`list*`/`string`/`catch`/`dict`/`switch` and a
   fuller `expr`, as real scripts demand them.

Each slice builds on the GPU TextGrid + reactive substrate already proven, and is
verified the same way everything else has been: drive it, snapshot it, read it.

---

## 7. Open decisions

- **[OPEN] Name & extension** — `ptcl`? `panescript`? `fpt`? (working: `ptcl`).
- **[OPEN] REPL pane** — dedicated third pane vs a mode toggle on the output pane.
- **[OPEN] `expr` depth** — integers-only first; when do floats/strings matter?
- **[OPEN] Result display** — does every REPL command echo its result (Tcl does)?
- **[OPEN] Safety** — `source`/`eval` run arbitrary commands; fine for a local
  dev IDE, but note it if scripts ever come from untrusted projects.
- **[OPEN] `bind` vs built-ins** — do user binds override or augment the hardcoded
  keymap? (Lean: override, with the built-ins registered as default binds so the
  whole keymap is introspectable/rebindable.)
- **[OPEN] dirty flag** — needed for `dirty` and a save-prompt on close.
- **[DECIDED] transport = named pipe** (user, 2026-06-20) — `\\.\pipe\newm2`,
  per-user DACL, no port/loopback exposure. TCP loopback (existing `Socket`/
  `SocketServer`/`RecvAll`) is the fallback; framing identical.
- **[DECIDED] compiler daemon first** (user) — it's what makes the IDE feel fast.
- **[DECIDED] ptcl is the shared toolchain language** (user) — GUI and compiler both
  speak it (§5.7). Open sub-question below.
- **[OPEN] daemon ptcl depth** — does the daemon ship the full evaluator
  (`proc/if/while/expr`, so you can send it scripts) or start as a command-reader
  subset and grow? Lean: reader subset first (request/response is single commands),
  full evaluator when scripting-the-compiler earns it.
- **[OPEN] COM registration scope** — ROT-only (`RegisterActiveObject`, attach-only,
  zero registry) vs `LocalServer32` under HKCU (lets a client *launch* the app). Lean:
  ROT-only first.
- **[OPEN] channel security** — loopback TCP is open to any local process; need a
  handshake token now, or a per-user-DACL named pipe later. COM inherits the user's
  session security.
- **[OPEN] compiler service shape** — daemon (separate process, pipe) vs a future
  `cdylib` (`newm2-compiler.dll`) called in-process via M2 FFI. Lean: daemon first
  (crash-isolated, incremental), DLL later if we want zero IPC.
