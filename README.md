# Windows Modula-2

A from-scratch **Modula-2** compiler and runtime for **Windows**, on **Rust +
LLVM** — PIM 4 + ISO 10514-1, JIT-first, native Win32/COM, classical manual
memory. The toolchain driver is `newm2`.

This is a deliberately **Windows-native** Modula-2: not a portable compiler that
happens to run on Windows, but one that targets `x86_64-pc-windows-msvc` *only* and
uses the platform to the hilt — the Win32 API, COM/Direct2D/Direct3D, GDI, WinMM
(`waveOut`/`midiOut` audio), Win64 structured exceptions, Win32 fibres, `HeapAlloc`,
PE/COFF — all reachable directly from clean Modula-2 source.

It is the Modula-2 member of a portfolio of from-scratch Rust+LLVM language
implementations (NewBF, NewCormanLisp, NewOpenDylan, NewFactor, …).

## Why Windows-native

Modula-2's systems-programming heritage maps cleanly onto Win32, and pinning the
target lets the compiler and runtime lean on Windows facilities instead of
abstracting them away:

| Modula-2 / runtime feature | Windows facility it uses |
|----------------------------|--------------------------|
| `Storage.ALLOCATE` / `NEW` · `DEALLOCATE` / `DISPOSE` | `HeapAlloc` / `HeapFree` |
| ISO `EXCEPTIONS` (`RAISE`, protected regions) | Win64 **structured exception handling** (`.pdata`/`.xdata` unwind) |
| ISO `COROUTINES` and PIM `SYSTEM` `NEWPROCESS`/`TRANSFER` | **Win32 fibres** |
| `ARRAY OF CHAR`, string literals, file paths | native **UTF-16** (wide) — the Windows string model |
| `newm2 build` | a standalone **PE/COFF** `.exe` (no external linker runtime) |
| `newm2 run` | an in-memory image via **ORC JIT** (RTDyld + Win64 SEH registration) |

## Win32, COM, and modern Windows graphics from Modula-2

The headline capability: **call the Windows API — including COM — directly from
Modula-2, safely.**

- **Generated bindings.** `newm2-winapi-gen` emits Modula-2 `DEFINITION MODULE`s
  for Win32 types, constants, flat functions, and **COM interfaces** straight from
  Windows metadata (a SQLite projection of the `.winmd` files), under
  `library/NewM2/`.

- **COM that (probably) cannot be wrong by construction.** Consuming a COM interface means
  calling through a vtable whose slot ordinals must be exact — the classic source
  of one-off `+N`-shift bugs. NewM2 makes the vtable a first-class, machine-checked
  thing: an `INTERFACE` declaration carries its IID and an `@ordinal` pragma on
  every method (`<* @5 *>`), and the compiler *computes* each slot by walking the
  `INHERIT` chain and **rejects any mismatch at compile time**. Because the
  ordinals come from the generator, which sources them from the metadata, the
  vtable is correct end-to-end. (See `docs/papers/com-vtables-before-after.md`.)

- **The whole modern graphics stack, in pure Modula-2.** Driven through those
  generated, `@ordinal`-checked interfaces — no hand-counted vtables:
  - **Direct3D 11 + HLSL** — a generic pixel-shader host (`ShaderView`): GPU
    Mandelbrot/Julia/plasma/raymarch.
  - **Direct2D / DirectWrite** — an immediate-mode 2-D drawing host (`Canvas2D`)
    and a Direct2D terminal renderer (`TermRender`): anti-aliased shapes, text,
    a coloured cell grid.
  - **GDI** — a general-purpose RGBA software framebuffer (`RasterView`,
    `SetDIBitsToDevice` blit) and a `Chart` library on top (bar/line/pie),
    exportable to `.bmp`.
  - **Retro game mode** — an indexed-colour "DOS/Amiga" host (`GameViewGpu`):
    a palette-index framebuffer resolved to RGBA on the GPU (an `R8_UINT` index
    texture + a palette-LUT pixel shader), with a per-scanline palette, palette
    cycling, a frame-animated **sprite layer** (each sprite its own 16-colour
    palette, rotation / scale / alpha, index-0 transparent), smooth scrolling over
    an over-allocated world, and parallax via blit between off-screen buffers.
    (`GameView` is the software, headless-testable sibling.)
  - **Win32 windowing** — `WinShell`: a real window + the M2 window-procedure
    callback + message loop.

See **[`demos/`](demos/)** for ~two dozen runnable programs — GPU shaders, the retro
game mode (sprites, scrolling, parallax), a TUI terminal, mouse-driven games
(minesweeper, reversi, worms), a notepad editor, a scientific calculator, a
business-graphics dashboard, and synthesized sound + ABC music — every one pure
Modula-2.

## Sound and music from Modula-2

The same direct-Win32 approach drives audio — no FFI shims; both the synthesis and the
device layer are Modula-2:

- **Software synthesis** (`Audio`) — game sound effects (coin / jump / zap / explode / …)
  from oscillators + ADSR + seeded-LCG noise + FM + filters + echo, rendered to a PCM
  buffer; deterministic and headless-testable. `WavFile` reads/writes 8/16/24/32-bit PCM `.wav`.
- **Live playback** (`WaveOut`) — a WinMM `waveOut` double-buffer fed by a background
  software mixer (per-voice gain / pan / fade / looping), so a game loop can fire
  overlapping effects.
- **Music** (`Abc` / `MidiOut` / `SmfFile`) — a full **ABC notation** parser (notes,
  octaves, accidentals, keys, durations, broken rhythm, ties, chords, tuplets, repeats,
  **multiple voices**) compiled to timed MIDI events, played live through WinMM `midiOut`
  on a 1 ms scheduler thread — tight timing with no GC pauses, melody + bass + drums on
  their own channels and instruments — and exportable to a standard `.mid` file.

The mixer and the MIDI scheduler run as M2-created OS threads (a `Threads` worker + a
critical-section lock) **alongside** Direct3D rendering, so a single Modula-2 program is a
complete little game engine: hardware-accelerated graphics, synthesized sound, and music,
at 60fps.

## Status

A **working compiler** with a substantial ISO 10514-1 standard library, a growing
Win32/COM surface, the graphics stack above, and a native audio/music subsystem.
Multi-module programs compile and run identically through the JIT and the AOT `.exe`.

### Compiler / runtime

- Lexer, parser (PIM 4 + ISO 10514-1 grammar), snapshot test harness
- SEMA — qualified imports, module-member resolution, two-phase analysis for
  circular imports, type checking, constant folding; opt-in pedantic `--strict`
- LLVM codegen — typed IR lowering, **ORC JIT** and **AOT**, Win64 SEH unwind
- `--opt <0..3>` runs the LLVM IR optimization pipeline (mem2reg, inline, GVN, …)
- `HeapAlloc`/`HeapFree` manual memory; optional self-hosted M2 `Heap`

### Language features

- Full PIM 4 control flow, procedures, nested procedures, in-module mutual recursion
- **CARDINAL** unsigned semantics; sized integer/cardinal/real builtins
- **SET** types; `INCL`/`EXCL`; set/integer compatibility
- **First-class SIMD** lane vectors (`REAL32X4`/`REAL64X2`: element-wise ops,
  broadcast, lane access, `SUM`/`DOT`/`FMA`/`ABS`)
- **Open arrays** (`HIGH` ABI), `VAR` and procedure-pointer indirect calls
- `NIL` assignment-compatible with the `ADDRESS` family
- Conditional compilation (`%IF`/`%ELSIF`/`%ELSE`/`%END`)
- ISO **EXCEPTIONS** (`RAISE` / protected regions) on Win64 SEH
- ISO **COROUTINES** and PIM `SYSTEM` coroutines (`NEWPROCESS`/`TRANSFER`,
  `PROCESS`) on Win32 fibres
- Narrow (`ACHAR`, 8-bit / ANSI) and wide (`CHAR`, UTF-16) string models

### Libraries

- **ISO 10514-1 stdlib** (`library/isodef` + `library/isomod`) — `EXCEPTIONS`,
  `Storage`, `IOChan`/`IOLink`/`StreamFile`/`SeqFile`/`TextIO`, `RealStr`/`LongStr`,
  `COMPLEX`/`ComplexMath`, `RealMath`/`LongMath`, `RandomNumbers`, `SysClock`, …
- **Windows / graphics** (`library/winrtdef` + `library/winrtmod`) — `WinShell`,
  `Terminal`, `TermRender`, `DWrite`, `ShaderView`, `Canvas2D`, `RasterView`, `Chart`,
  `GameView` / `GameViewGpu` (retro game mode), `Dialogs`, `Clipboard`, `RunProg`,
  `Threads`, `FileFunc`, `ElapsedTime`, `MemUtils`, `SecureRandom`, …
- **Audio / music** (`library/winrtdef` + `library/winrtmod`) — `Audio` (synthesis),
  `WavFile` (`.wav` r/w), `WaveOut` (live `waveOut` mixer), `Abc` (ABC notation parser),
  `MidiOut` (`midiOut` scheduler), `SmfFile` (`.mid` export)
- **Generated Win32/COM** (`library/NewM2`) — `Graphics_Direct2D`,
  `Graphics_Direct3D11`, `Graphics_Dxgi`, `Graphics_Gdi`, `System_*`, …
- **Utilities** (`library/utildef` + `library/utilmod`) — `TextRope` (an editor-grade
  rope buffer)

Built and tested entirely against the project's own definition modules — no
third-party distribution required.

### Not yet

The full Win32 binding surface, COM *server*-side (`CLASS IMPLEMENTS` +
synthesized `QueryInterface`), anti-aliased font rendering for `Chart`, and
editor / LSP integration (the standalone `FastM2` IDE aside). Cross-platform is
explicitly **out of scope** — this compiler is Windows-only by design.

## Building

Requires a **Rust** toolchain and **LLVM 22.1** (`x86_64-pc-windows-msvc` only):

```
set LLVM_SYS_221_PREFIX=C:\path\to\llvm-22.1
cargo build --workspace
cargo test  --workspace

target\debug\newm2-driver run   demos\term-demo.mod         # JIT
target\debug\newm2-driver build demos\chart_demo.mod        # AOT -> .exe
target\debug\newm2-driver run   --opt 2 my.mod              # optimized JIT
```

## Layout

| Path | What |
|------|------|
| `src/` | Rust workspace — `newm2-lexer`, `newm2-parser`, `newm2-sema`, `newm2-ir`, `newm2-llvm`, `newm2-runtime`, `newm2-driver`, `newm2-winapi-gen` |
| `library/isodef`, `library/isomod` | ISO 10514-1 standard library (clean-room) |
| `library/winrtdef`, `library/winrtmod` | Windows framework + graphics hosts |
| `library/NewM2` | generated Win32 / COM `DEFINITION MODULE`s |
| `library/utildef`, `library/utilmod` | general-purpose utility modules |
| `demos/` | runnable demo programs (GPU, retro game mode, TUI, games, graphics, audio, music) |
| `projects/FastM2` | **FastM2** — a Turbo-Pascal-style Modula-2 IDE, itself written in Modula-2 |
| `Mod/tests/` | Modula-2 conformance / regression test programs |
| `tests/` | Rust integration + conformance harness |
| `docs/` | design notes, the COM-vtables paper, the DocCrate language guide |

## License

`MIT OR Apache-2.0`.

---

*Inspired by the ADW Modula-2 distribution and the PIM 4 / ISO 10514-1
specifications. Targets Modern Windows, deliberately and exclusively.*
