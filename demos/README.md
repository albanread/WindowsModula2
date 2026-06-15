# NewM2 demos

Real Modula-2 programs that exercise the compiler the way a user would — they
are also the most honest test of the toolchain: each one compiles the ISO
standard library, the M2 runtime, and a GUI/COM stack, then runs through both
back ends (the ORC JIT and the AOT `.exe`).

Every demo here is pure Modula-2. The GUI ones build on the Windows-11 stack
written in M2 (no GDI):

| Module        | Role                                                          |
|---------------|---------------------------------------------------------------|
| `WinShell`    | a real window + the M2 window-procedure callback + message loop |
| `TermRender`  | Direct2D / DirectWrite renderer (per-cell 24-bit colour)      |
| `Terminal`    | the cell-grid model — colours, menus, status bar, fields, events |
| `DWrite`      | DirectWrite bindings (proves FLOAT args through virtual COM calls) |

## Running

```
newm2 run   demos/<name>.mod      # JIT (ORC) — compiles + runs in one step
newm2 build demos/<name>.mod      # AOT — writes <name>.exe next to the source
```

(`newm2` here is the `newm2-driver` binary under `target/<profile>/`.)

## Demos

| Demo             | Kind | Status | Notes                                            |
|------------------|------|--------|--------------------------------------------------|
| `term-demo.mod`      | TUI | ✅ | A live Direct2D/DirectWrite terminal — coloured cells, drop-down menus, status bar, an editable field, event queue. **Renders entirely through the winapi-gen-generated, `@ordinal`-checked COM interfaces** (see [the case study](../docs/papers/com-vtables-before-after.md)). |
| `mandelbrot_gpu.mod` | GPU | ✅ | **Direct3D11 + HLSL pixel-shader Mandelbrot zoomer** — escape iteration on the GPU, via the generic `ShaderView` host. arrows pan, `+/-` zoom, `R` reset, `Esc` quit. |
| `julia_gpu.mod`      | GPU | ✅ | **Animated Julia set** — each pixel iterates `z = z²+c` while `c` sweeps a circle every few seconds, so the fractal morphs continuously. Same `ShaderView` host, different pixel shader. `+/-` zoom, `R` reset, `Esc` quit. |
| `plasma_gpu.mod`     | GPU | ✅ | **Animated plasma** — summed sine waves over screen space swept by time, through a cosine palette. The whole effect is ~6 lines of pixel shader + a 16-byte constant record. `+/-` speed, `R` reset, `Esc` quit. |
| `raymarch_gpu.mod`   | GPU | ✅ | **Raymarched 3-D torus** — each pixel sphere-traces a signed-distance field and shades the hit with diffuse + specular lighting; the torus spins via time-driven rotation matrices. The camera ray, march loop, normal and lighting all live in the pixel shader. `+/-` spin speed, `R` reset, `Esc` quit. |
| `mandelbrot.mod`     | TUI | ✅ | CPU escape-time set in colour over the Terminal cell canvas (each cell = one pixel); **`A` auto-dives** into a spiral on its own, or steer by hand: arrows pan, `+/-` zoom, `[ ]` iterations, `R` reset. |
| `life.mod`           | TUI | ✅ | **Conway's Game of Life** animating on the cell grid (a torus); `Space` run/pause, `S` step, `R` random soup, `C` clear, `G` glider, `+/-` speed, click to paint cells. |
| `minesweeper.mod`    | GUI | ✅ | **Mouse-driven Minesweeper** on the Terminal cell grid — left-click reveals (flood-fill of empty regions via recursion), right-click flags; first click is always safe. `R` new game, `Esc` quit. |
| `reversi.mod`        | TUI | ✅ | **Reversi / Othello** (text cell grid) — you play Black, a greedy corner-preferring AI plays White; legal moves are highlighted, the 8-direction bracket-and-flip rule runs the captures. `R` new game, `Esc` quit. |
| `reversi_gui.mod`    | GUI | ✅ | **Reversi / Othello, drawn with Direct2D** — the same game and AI as `reversi.mod`, but a green felt board with gridlines, anti-aliased circular discs, faint legal-move dots, and a text score line, via the reusable `Canvas2D` host. `R` new game, `Esc` quit. |
| `editor.mod`         | TUI | ✅ | **Notepad-like text editor** on the Terminal cell grid — the document buffer is a `TextRope` (`library/utilmod`), so each keystroke is an O(log n) rope edit, not a big-array shift. Cursor + viewport scroll, click-to-place, type/Enter/Backspace/Del, and ISO file save/load (`F2`/`F3` ↔ `notepad.txt`). |
| `simd_particles.mod` | GUI | ✅ | **SIMD particle swirl** — 640 particles pulled toward a moving attractor, integrated **four at a time in `REAL32X4` lane vectors** (element-wise `+ - * /`, scalar broadcast, `FMA`); drawn with `Canvas2D`. Drag the mouse to steer the attractor, `Space` pause, `R` reseed, `Esc` quit. |
| `calculator.mod`     | GUI | ✅ | **Scientific calculator** — a clickable Direct2D button grid + a typed-expression display, evaluated by a hand-written **recursive-descent parser** (precedence, right-assoc `^`, unary minus, parens, `sin/cos/tan/ln/log/sqrt/exp/abs`, `pi`/`e`) over `RealMath`. Click or type; `=`/Enter evaluates, `C` clears, `Esc` quits. |
| `worms.mod`          | TUI | ✅ | **Worms** (multi-worm snake) — you are the green worm; **three worker `COROUTINES`** cooperate with the main loop: a treat dispenser deposits food, and the red & blue worm AIs each steer toward the nearest treat while dodging walls and bodies. Eat to grow; hitting a wall/worm is fatal. Arrows steer, `Space` pause, `R` restart, `Esc` quit. |
| `chart_demo.mod`     | GFX | ✅ | **Business dashboard** — a bar chart, line chart, pie chart and legend drawn with the `Chart` library on the **`RasterView`** RGBA software framebuffer (every pixel in Modula-2), blitted with one GDI call. `S` exports the exact image to `dashboard.bmp`; `Esc` quits. |
| `gameview_demo.mod`  | GFX | ✅ | **Retro indexed-colour game mode (software)** — a 200×130 palette-index framebuffer presented at 4× chunky pixels on the **`GameView`** host: 16-colour sprites authored from text rows, bit-blits with transparency + horizontal flip, and a palette-cycled rainbow band (the copper-bar trick). Arrows fly the ship; `Esc` quits. |
| `lut_gpu.mod`        | GPU | ✅ | **GPU palette-LUT present** — the indexed mode on the GPU: the index buffer is an `R8_UINT` texture, palettes are LUT textures, and a pixel shader resolves index→RGBA. Full **per-line palette** (indices 0..15 from each scanline's own LUT → copper bars / smooth gradients; 16..255 global) + palette cycling, all as tiny per-frame LUT re-uploads; the GPU upscales for free. `Esc` quits. |
| `sprite_gpu.mod`     | GPU | ✅ | **GPU sprite layer** — three instances of one 16×16 indexed sprite (its own palette, index 0 transparent) alpha-blended over a gradient background: solid, alpha-pulsing, and rotating. Proves the second-pass quad compositing (dynamic VB + input layout + blend state + sprite VS/PS). `Esc` quits. |
| `retro_gpu.mod`      | GPU | ✅ | **GameView GPU showcase** — the full retro mode on **`GameViewGpu`**: an indexed background with an animated per-line palette (raster bars) + a palette-cycled rainbow strip, and a sprite layer of **frame-animated** spinning coins + a rotating star, composited on the GPU. `Esc` quits. |
| `scroll_gpu.mod`     | GPU | ✅ | **Smooth GPU scrolling** — a 640-wide *world* index buffer with a 240-wide *view*; `SetScroll` pans the viewport over the over-allocated world (pure GPU sampling, no redraw). Spinning coins sit at world positions and scroll in/out of view. `Esc` quits. |
| `parallax_gpu.mod`   | GPU | ✅ | **Parallax via blit** — far/mid/near background layers pre-rendered into off-screen indexed buffers, then `Blit`/`BlitTrans`-composited into the display each frame at different scroll rates; a frame-animated bird flies over. `Esc` quits. |
| `audio_sfx.mod`      | SFX | ✅ | **Game sound synthesis** — renders the **`Audio`** library's preset SFX (coin / jump / zap / explode / powerup / hurt / click / bang / blip / tone / pink-noise) to `.wav` files, entirely in Modula-2 (pure software synthesis, no device). A console tool — run it to drop a playable SFX pack. |
| `audio_play.mod`     | SFX | ✅ | **Live audio playback** — synthesizes SFX and plays them through WinMM **`WaveOut`** (a background mixer thread, direct from M2): one-shots, overlapping voices (software mixing), and a looped tone with a fade-out. Run it and listen. |
| `music_play.mod`     | MUS | ✅ | **ABC music playback** — parses ABC notation (**`Abc`**) to timed MIDI events and plays them live through WinMM **`MidiOut`** (a scheduler thread firing each note at its precomputed ms deadline — tight timing, no GC pauses). Plays the opening of "Ode to Joy". |

The GPU demos share a reusable host — **`ShaderView`** (`library/winrtmod`), a
generic full-screen pixel-shader renderer on Direct3D11: a demo calls
`Attach(hwnd,w,h)`, `SetShader(hlsl, SIZE(constants))`, then `RunLoop(build)` and
supplies only its own HLSL pixel shader + a constant-buffer record. All the D3D11
plumbing (device, swapchain, RTV, runtime `D3DCompile`, Present) drives the
winapi-gen-generated, `@ordinal`-checked COM interfaces — no hand-counted vtables.
A new shader demo is ~one pixel shader + one constant record.

The 2-D graphical demos share a second reusable host — **`Canvas2D`**
(`library/winrtmod`), an immediate-mode Direct2D drawing surface: a demo calls
`Attach(hwnd,w,h)`, then per frame `Begin`, `Clear`/`FillRect`/`FillCircle`/
`DrawText`, `Flush`. It drives the same winapi-gen-generated, `@ordinal`-checked
Direct2D/DirectWrite interfaces the Terminal renderer proves (`FillEllipse` is
slot `@21`) — the shape sibling of `ShaderView`.

A third host, **`RasterView`** (`library/winrtmod`), is a general-purpose RGBA
**software** framebuffer for high-resolution business graphics: draw with pure-M2
primitives (`FillRect`/`Line`/`Disc`/`Text` over a 5×7 bitmap font, …) into a pixel
array, then `Present` (one GDI `SetDIBitsToDevice` blit) or `SaveBMP` (export to a
32-bpp `.bmp`). Because the drawing is all software, output is reproducible and
**headless-testable**. The **`Chart`** library builds bar/line/pie charts on it —
`chart_demo` is a few `Chart` calls.

A fourth host, **`GameView`** (`library/winrtmod`), is the **indexed-colour** sibling
of `RasterView` — the retro game mode (think DOS/Amiga). You draw with palette
*indices* into a small framebuffer; a 256-entry palette maps each index to a colour;
`Present` resolves indices → RGBA at an integer `scale` (chunky nearest-neighbour
pixels) and blits with one `SetDIBitsToDevice`. 16-colour **sprites** are authored as
text rows (`SpriteRows(id, "....22..../...2332...")`, `.` = transparent) and bit-blit
onto the framebuffer (`Blit`/`BlitFlip`/`BlitScale`, transparent index skipped);
`CyclePalette` animates a palette range for classic raster effects. Like `RasterView`
the drawing is software, so the buffer is **headless-testable**. `gameview_demo` is a
small playable showcase.

A fifth host, **`GameViewGpu`** (`library/winrtmod`), is the **GPU** retro mode — the
indexed background and sprites the way winscheme does it, on Direct3D11 via
`ShaderView`. The index buffer + global + per-line palettes upload as textures and a
pixel shader resolves index→RGBA; on top, an animated **sprite layer** is composited
alpha-over. Sprites are two-level: a **definition** is art (a strip of equal-size
**frames** in a shared atlas + its own 16-colour palette, colour 0 transparent); an
**instance** places a definition with position / rotation / scale / alpha / flip /
z-priority and auto-animates its frames at an FPS (`Tick` advances them). The GPU does
the upscale, the alpha blending, and the per-sprite palette lookup; `Present` draws
the background then the sprite layer in one pass each. For scrolling games the index
buffer is a **world** bigger than the **view**: `SetScroll` pans the viewport over it
on the GPU (no redraw), and there are several indexed buffers so you can pre-render
backgrounds / parallax layers and `Blit`/`BlitTrans` regions between them. `retro_gpu`
(scene), `scroll_gpu` (smooth world scroll) and `parallax_gpu` (blit layers) show it off.

**Audio** (`library/winrtdef/Audio.def` + `WavFile.def`) is a separate non-graphics
subsystem — a Modula-2 port of the NewAudio synth core. `Audio` renders game sound
effects (oscillators + ADSR + seeded-LCG noise + game presets + pitch sweeps + tanh
distortion + echo) into a PCM `Sound` buffer in pure software, deterministically, so
it is **headless-testable** like `RasterView`; `WavFile` exports/imports canonical PCM
`.wav`. **`WaveOut`** plays `Sound`s live through WinMM (a background mixer thread, direct
from M2 — open `waveOut`, double-buffer a few blocks, software-mix the active voices with
per-voice gain/pan/fade). `audio_sfx` (render to .wav) and `audio_play` (live) show it off.
For music, **`Abc`** parses ABC notation (notes/octaves/accidentals-in-bar/key/durations/
broken-rhythm/ties/chords/tuplets/rests/bars/repeats/tempo/meter/inline-fields/`%%MIDI`) to a
flat array of absolute-ms MIDI events, and **`MidiOut`** plays them through WinMM `midiOut`
on a 1 ms scheduler thread — `music_play` is the showcase.

Prebuilt `.exe`s sit next to each source (`newm2 build demos/<name>.mod` rebuilds);
the `.exe`/`.obj` are git-ignored.

More shader, terminal (TUI), and GUI demos land here as they are written.

## Why these

They are deliberately varied — a floating-point pixel kernel (mandelbrot/julia),
event-and-state UIs (minesweeper/reversi) — so that between them they stress the
LONGREAL path, arrays and records, the COM/vtable call path, Win32 message
dispatch, and the standard library. If the demos build and run identically under
the JIT and AOT, the compiler is in good shape.
