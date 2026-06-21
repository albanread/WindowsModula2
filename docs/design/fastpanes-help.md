# FastPanesM2 — interactive help pane + context assistant

## Principle: help that is ground truth, because the IDE owns the compiler

A generic editor *guesses* what a name means. FastPanesM2 can **resolve it** — the
exact signature, the module it comes from, a COM interface's IID and `@ordinal`,
a Win32 function's DLL. So the headline of this feature is not "a help window";
it is **always-correct, context-sensitive help** drawn from the live compiler,
rendered as markdown in a right-hand pane, with an *optional* LLM assistant
layered on top that is **grounded** in those compiler facts (so it doesn't
hallucinate the way generic code assistants do).

Three layers, weakest dependency first:
1. **Help pane + markdown viewer** — browse the existing `docs/m2-guide`.
2. **Context "describe"** — click a symbol → precise facts from the daemon. Deterministic, offline.
3. **The assistant** — opt-in "Explain", handed the compiler context. Designed now, built later.

### The real value: we see across the whole module graph; the user sees one file

This is what makes the feature worth far more in Modula-2 than in a flatter language.
Modula-2 is *deliberately modular* — a program is a deep graph of `DEFINITION` modules,
each name reaching across a `.def` boundary. A developer is looking at **one file**; the
imported name `WriteString` is just a token to them — to see its signature, which module
it lives in, or what else that module offers, they must stop and go open another file (or
several, up the import chain). **Sema has already resolved the entire graph.** So the help
pane's job is not "show docs for this word" — it is **surface what is across the module
boundary that the user cannot see from where they sit**:

- the **real signature + declaring module** of an imported name (no need to open its `.def`);
- the **import provenance chain** (this name was re-exported from X, originally declared in Y);
- the **full shape of a type declared elsewhere** — a record's fields, a class/interface's
  methods — even though its definition is in another file;
- **what else that module exports** ("you imported one thing from `STextIO`; here is the rest");
- **go to definition** — jump straight to the declaring file/line.

The deeper and more modular the library graph, the more the IDE can show that a
single-file view structurally cannot. That is the differentiator.

## Grounding facts (decide the design)

- The shared `windows_api.db` has **no prose** on types/methods/constants; `functions`
  carry a `documentation_url`. So context help is **structural truth + a docs link**,
  not scraped paragraphs. (That structural truth is the valuable, can't-be-wrong part.)
- A real guide already exists: `docs/m2-guide/` (getting-started, lexical-structure,
  declarations-and-types, expressions, statements, procedures, modules-and-compilation,
  memory-and-exceptions, standard-environment, reference, index) — the static-help corpus.
- Sema already records, by span: `resolved_names` (`ResolvedName{name,kind,provenance,…}`),
  `designator_types`, `selector_bindings`. So "the symbol under the cursor" is a lookup,
  next to the existing `complete` verb.
- `PaneShell.SetHidden(p,hidden)` / `IsHidden` + `PaneLayout.SetWeight` already do
  show/hide + width — the toggle is free.

## Layout

A **toggle-able right column**, hidden by default (1280px is tight with the sidebar):

```
root = Split(Horizontal, 0.18, sidebar,
             Split(Horizontal, 0.78, Split(Vertical, 0.74, editor, output), help))
```

- **F1** (and a View-menu item) toggles the help pane: `SetHidden(helpPane, …); Retile`.
- The pane **auto-opens** when a "describe" is triggered (so context help is never hidden).
- The help pane is a **GPU TextGrid** leaf (same renderer as everything else).

## The markdown viewer — a reusable `library/uimod` component

A small, deliberate-subset renderer (NOT full CommonMark), reusable by any PaneShell
app: `MarkView` (`library/uidef/MarkView.def` + `library/uimod/MarkView.mod`).

```
PROCEDURE Render  (b: Surface.Backend; text: ARRAY OF CHAR; top: CARDINAL);  (* draw, scrolled by `top` *)
PROCEDURE Lines   (b: Surface.Backend; text: ARRAY OF CHAR): CARDINAL;        (* wrapped line count, for scroll bounds *)
PROCEDURE LinkAt  (col, row: CARDINAL; VAR target: ARRAY OF CHAR): BOOLEAN;   (* the link under a click, if any *)
```

Block elements (line-based): `#`/`##`/`###` headings, `-`/`*` lists, ```` ``` ```` fenced
code, `>` blockquote, `---` rule, blank-line paragraph breaks; paragraphs **word-wrap**
to the pane width (reflow via `VisibleCells`, like the editor). Inline: `**bold**`,
`` `code` ``, `[text](target)` links. Render → TextGrid colour mapping (reuse the editor
palette): heading = Yellow/Aqua, bold = White, `code` = Teal, link = Aqua, rule = a row of
`─`, bullet = `• `. While rendering, record each link's `(row, colLo, colHi, target)` so
`LinkAt` can hit-test a click. A `target` is either `help:<topic>` (navigate) or
`sym:<file>#<line>` (jump to code) or an `http(s)://` URL (open in the browser).

## Static help (P1)

Help content ships as markdown beside the exe (`help/` in the release; `docs/m2-guide`
in dev — the same relocatable fallback as the compiler/library). The pane shows an
**index** (the guide TOC) on open; `[links]` navigate between topics; a small
back-stack (Backspace) returns. No new prose to write — surface what's there.

## Context help — the `describe` verb (P2)

A daemon verb `describe <file> <line> <col>` (sibling to `complete`):
1. Build graph + sema on the (repaired, mid-edit-tolerant — reuse `repair_for_completion`)
   buffer; find the entry module.
2. Resolve the symbol at the cursor: the designator/identifier whose span covers the
   offset → `resolved_names` (kind, provenance) + `designator_types`/`selector_bindings`
   (type / method slot). (Reuses the `complete` resolution machinery.)
3. Enrich from `windows_api.db` when the provenance points at a generated module:
   a Win32 function → its **DLL** + a `documentation_url` link; a COM method → its
   interface's **IID** + computed **`@slot`** (already in the class arena).
4. Return **markdown**. Shape:

```
## WriteString
`PROCEDURE (s : ARRAY OF CHAR)`

**Module** STextIO · ISO 10514-1
```

```
## CreateWindowExW
`FUNCTION (...) : HWND`

**DLL** USER32.dll · [Microsoft docs](https://learn.microsoft.com/…)
```

```
## DrawText
`PROCEDURE (... ) `

**Interface** ID2D1RenderTarget · IID {2cd90694-…} · slot @43
```

Beyond the headline facts, the verb emits the **across-the-graph** content (the point
above) when it applies — all from sema/the graph, none of it visible in the current file:
- **Type shape from elsewhere** — if the symbol's type is a record/class/interface declared
  in another module, list its fields / methods (with signatures), so you see the shape
  without opening that `.def`.
- **Provenance chain** — `imported here from STextIO` (and, if re-exported, `originally
  declared in …`), from `ResolvedName.provenance`.
- **Sibling exports** — "`STextIO` also exports: WriteChar, WriteLn, SkipLine, …" (iterate
  the declaring module's exported scope) — discovery you can't get from one file.
- **Go to definition** — a `sym:<defining-file>#<line>` link to jump straight to where it's
  declared (the declaration span is in the symbol table).

**Trigger:** clicking a symbol in the editor (a normal click already lands a cursor;
when the help pane is open, the click also fires a describe), and **F1** on the word at
the cursor (also opens the pane). Debounced; one daemon round-trip per request.

## The assistant hook (P3 — designed now, built later)

The payoff of "we know a lot": hand the LLM the **compiler's ground truth**, so its
answer is grounded. We design the *seam* now and wire a provider later.

- **`AssistContext`** — the structured bundle `describe` already computes, plus a little
  more: `{ name, kind, signature, module, provenance, iid?, slot?, dll?, docUrl?,
  enclosingProc, selectedText, surroundingLines (±N), diagnostics (any live errors here) }`.
- **Provider interface** (pluggable, so the core has no network dependency):
  `Assist(ctx: AssistContext) -> markdown`. A concrete provider (HTTP to an LLM) is a
  separate, **opt-in** module; absent it, the action is simply unavailable.
- **UX:** the `describe` markdown ends with an `[Explain ▸]` link; clicking it (only when
  a provider is configured) sends the bundle and streams a grounded explanation / usage
  snippet / "why is this erroring" into the same pane, clearly marked as AI-generated.
- **Guardrails:** OFF by default; explicit opt-in (it is a network call to an external
  service — publishing code context); the deterministic help (P1/P2) is fully functional
  offline without it. The prompt pins the model to the supplied facts ("use only the
  signature/module/IID given; do not invent APIs").

### Cost is the whole reason the assistant is a *layer*, not the product

Most developers will not — and should not have to — pay a subscription, and a local
model big enough to be useful eats a workstation's RAM/VRAM. So:

- **The deterministic help (P1/P2) is the product.** It is free, instant, offline, and
  always correct. The IDE ships nothing AI and costs nothing by default. A user who never
  touches the assistant loses nothing.
- **The assistant is bring-your-own (BYO), for those who already have it.** No bundled
  model, no subscription, no proxy we run. The provider is **endpoint-agnostic** — a
  config gives a base URL + (optional) API key for any **OpenAI-compatible** endpoint, so
  the same code points at *either*:
  - the user's own cloud key (they pay their own usage, directly), **or**
  - a **local** server they already run (Ollama / llama.cpp / LM Studio) — zero marginal
    cost, on hardware they chose to dedicate.
- It is framed exactly as that: a nice extra for those who can afford it (in money or in
  hardware), never a gate on the IDE.

This keeps P1/P2 self-contained, free, and offline, while P2's `describe` output *is* the
AssistContext — so P3 is a tiny config + provider call + a link, not a rework.

## Phasing

- **P1** — help pane (toggle, F1/View) + `MarkView` renderer + static browse of the guide
  (index, links, back-stack), relocatable help content.
- **P2** — `describe` daemon verb + click/F1 trigger + db enrichment (DLL/IID/slot/docs link).
- **P3** — the assistant: `AssistContext` + provider interface + opt-in `[Explain]`.

## Non-goals / tradeoffs

- `MarkView` is a deliberate subset (no tables/HTML/nested-list gymnastics) — enough for
  the guide + describe output.
- Screen space: the help pane is collapsible and auto-opens on describe; it is not a
  permanent third of the window.
- `describe` inherits completion's mid-edit-parse fragility — same line-repair mitigation.
- No bundled LLM, no default network calls; the assistant is an explicit, opt-in layer.
