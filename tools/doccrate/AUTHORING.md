# NewM2 Guide Authoring Contract

Every page under `docs/m2-guide/` is rendered by **DocCrate**
(`tools/doccrate/doc-crate.exe`), a native Direct2D Markdown browser that renders a
**subset** of Mermaid via the Selkie engine. Follow this contract so every page renders.
Verify with `pwsh tools/doccrate/Test-Render.ps1 -File docs/m2-guide/<page>.md`.

## What this guide is

A **multi-page, diagram-rich user guide for Modula-2 as NewM2 implements it**, browsable
in DocCrate. **NewM2** is a from-scratch Modula-2 compiler, targeting **PIM 4 +
ISO 10514-1**, JIT-first with an AOT `.exe` mode. There is **no existing single-file guide**
to transform, so write from these sources:

- **The compiler front-end is the scope authority**: `src/newm2-lexer/src/{token.rs,lib.rs}`
  (the reserved words + literals — note: type names and standard procedures like `INTEGER`,
  `NEW`, `INC` are *pervasive identifiers*, NOT keywords) and
  `src/newm2-parser/src/{ast.rs,parser.rs}` (the constructs actually parsed). Cite as inline code.
- **The language is standard Modula-2** (PIM 4 / ISO 10514-1) — you may rely on the
  well-known semantics, but **scope each page to what NewM2's lexer/parser accept**, and be
  honest where a construct parses but isn't yet executed (NewM2's back-end is young).
- **Ground examples in the real corpus**: 400+ `.mod`/`.def` files under
  `E:\NewM2\NewM2\mod-tests\` and `Mod/` and `library/`. Keep examples small and complete;
  every snippet should be valid Modula-2 NewM2 accepts. Don't invent syntax.
- NewM2 specifics to surface where relevant: classical manual memory (`HeapAlloc`/`HeapFree`,
  every `NEW` paired with `DISPOSE`); the ISO exception set (`EXCEPT`/`FINALLY`/`RETRY`);
  NewM2 bitwise extensions (`BAND`/`BOR`/`BXOR`/`BNOT`/`SHL`/`SHR`); `ASM` inline assembly;
  `<* … *>` pragmas; the `SYSTEM` module.

## Markdown rules

- **Supported:** headings, **bold**/*italic*/`code`, fenced code blocks (use ```` ```modula2 ````
  — no syntax highlighting, fine), blockquotes, lists, GFM tables, rules, links.
- **FORBIDDEN: images** (`![](x.png)` renders as raw text). Express visuals as diagrams.
- **Links:** only `.md` links navigate. Source refs like `src/newm2-parser/src/ast.rs:42`
  are **inline code**, not links.

## Supported Mermaid subset (USE ONLY THESE) — verified

`flowchart`, `classDiagram`, `sequenceDiagram`, `stateDiagram-v2`. **TWO HARD PROHIBITIONS
(verified broken):**
- **No `subgraph … end`** — it doesn't draw a box; the label becomes a column of single
  characters. Split into two diagrams or mark a boundary with a `{{hexagon}}` node.
- **No `<br/>`** in labels — it prints literally. One short line per node label.

Other rules: classDiagram generics use **tildes**; sequenceDiagram has **no
`loop`/`alt`/`opt`/`par`**. **Never put `[` `]` `(` `)` inside a flowchart node label**
(reword). Keep diagrams 4–12 nodes; split wide ones. Good Modula-2 diagram candidates: the
compile pipeline, the `DEFINITION`/`IMPLEMENTATION` module split, the type taxonomy, the
control-flow shapes, the manual memory model. Don't force a diagram per page.

## Page template

```markdown
# <Title>

One or two sentences: what this is, in a breath.

## <sections>   ← prose + `​```modula2` examples; a diagram only where it helps

---
[NewM2 Guide home](index.md) · [next/related page](other.md)
```

## Modula-2 vocabulary (use it precisely)

Modula-2 is **case-sensitive**; reserved words and standard identifiers are UPPER CASE.
Comments are `(* … *)` and nest. A program is a `MODULE`; libraries are a `DEFINITION
MODULE` (interface) + `IMPLEMENTATION MODULE` (body) pair, compiled separately. Imports:
`IMPORT M;` (qualified, used as `M.X`) or `FROM M IMPORT X;` (unqualified). Declarations:
`CONST`, `TYPE`, `VAR`; procedures `PROCEDURE`. Types: ordinals (`INTEGER`, `CARDINAL`,
`CHAR`, `BOOLEAN`, enumerations, subranges `[0..9]`), `REAL`/`LONGREAL`, `ARRAY … OF`,
`RECORD … END` (with `CASE` variants), `SET OF`, `POINTER TO`, procedure types, opaque
types. Statements end with `;` (a separator); assignment is `:=`; `=` is equality, `#`/`<>`
is not-equal. Control flow: `IF/ELSIF/ELSE/END`, `CASE/OF/|/ELSE/END`, `WHILE/DO/END`,
`REPEAT/UNTIL`, `FOR/TO/BY/DO/END`, `LOOP/EXIT/END`, `WITH/DO/END`, `RETURN`. Operators
`+ - * /`, `DIV`, `MOD`, `REM`; relational `= # < <= > >=`; `AND`/`&`, `OR`, `NOT`/`~`,
`IN`; sets `+ - * /`. Pervasive procedures (identifiers, not keywords): `NEW`, `DISPOSE`,
`INC`, `DEC`, `INCL`, `EXCL`, `HIGH`, `SIZE`, `ORD`, `CHR`, `VAL`, `MIN`, `MAX`, `ABS`,
`CAP`, `ODD`, `TRUNC`, `FLOAT`; values `TRUE`, `FALSE`, `NIL`. `SYSTEM` module: `ADDRESS`,
`WORD`, `BYTE`, `ADR`, `CAST`, coroutines (`NEWPROCESS`/`TRANSFER`).

## Verify before done

```
pwsh tools/doccrate/Test-Render.ps1 -File docs/m2-guide/<page>.md
```
Read the PNG — never an italic `mermaid error:` line or raw ```` ```mermaid ```` source.
Fix and re-render if you see either.
