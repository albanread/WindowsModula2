# Module graph — where it fits and why

*2026-05-12. Design note captured from a discussion during Phase 2
bring-up.*

## Where it fits in the pipeline

```
read → lex → parse → MODULE GRAPH ← here → sema → CFG → IR → LLVM IR → JIT/AOT
```

"Phase 4" understates how interleaved it is. `build_module_graph`
doesn't run *after* parsing — it **drives** parsing. The flow is:

1. Parse the entry file's AST.
2. Look at its IMPORT clauses.
3. For each imported name, find the `.def` in the search path.
4. Parse that `.def`. Look at *its* IMPORTs.
5. Recurse until the worklist is empty.
6. Topologically sort with cycle detection.

By the time the graph is complete, every module reachable from the
entry has a parsed AST and a known position in dependency order.

## Why it's placed here

Three reasons stack:

1. **Sema can't start until the graph exists.** When sema in module
   `Hello` sees `IOChan.ChanId`, it needs to look up `ChanId` in
   IOChan's already-resolved symbol table. Sema processes modules in
   topological order, dependencies first. That ordering is the
   graph's job.
2. **Cycle detection is structural, not semantic.** It's cheaper to
   fail at "you have an import cycle" by walking the edge set than
   by tripping over a recursive sema call deep inside type checking.
3. **It can't happen earlier.** We need each module's AST to read
   its IMPORT list. You don't know what IOChan imports until you've
   parsed IOChan.

## Why static — language reason, not just AOT

The obvious answer is "because we emit a `.exe`". That's only half
the story.

The deeper reason: **Modula‑2 the language was designed as a
closed-composition system.** PIM and ISO 10514 define no runtime
mechanism for loading a module that wasn't an IMPORT target at
compile time. There's no `Kernel.LoadMod`
analog in `SYSTEM`. Module identity is fixed at IMPORT resolution
and frozen for the lifetime of the program.

So the graph is static because the language is static, and that's
true regardless of execution model:

- **AOT path** (Phase 12, `newm2 build`): linker resolves the whole
  graph at link time. Obviously static.
- **JIT path** (`newm2 run`): session loads all transitively
  required modules at startup. The graph is closed for the
  lifetime of the session. New modules don't appear later — you
  have to re-run with a different entry.

If we wanted a dynamic-loading extension, it would have to be a
NewM2-only language addition (e.g. a `SYSTEM.LoadModule`
procedure), and that would break our source-compatibility target. So we don't.

## Contrast with Component Pascal (NewCP)

NewCP's loader is a different beast. Modula‑2 and Component Pascal
look similar on the surface — both Wirth-lineage, similar grammar,
similar module syntax — but they treat module loading very
differently.

| Aspect | NewM2 (Modula‑2) | NewCP (Component Pascal) |
|---|---|---|
| When does the loader run? | Once per build (or per save in the JIT session) | Continuously while the program runs |
| Can new modules appear at runtime? | No — language doesn't permit it | Yes — `Kernel.LoadMod` is part of the SDK |
| Can modules be hot-swapped? | No — re-run to pick up changes | Yes (with constraints) |
| Where does the loader live? | Compile-time pass in `newm2-loader` | Runtime-resident service inside the running image |
| What does "the graph" mean? | Static, computed once: "what's needed to compile this program" | Dynamic, evolving: "what's loaded right now" |
| Type identity across loads | Tied to compile-time module identity | Tied to module descriptors that survive across loads |

So NewCP's loader has to be a **runtime-resident service**.
NewM2's loader is a **compile-time pass**. Same name, very
different jobs.

This is partly why NewCP needs the `newcp-odc` crate (BlackBox's
object-descriptor format on disk) — descriptors are how type
identity travels with modules across load events. NewM2 has no
analog because module identity never escapes a single compilation
session.

## Where dynamism lives in NewM2

Not nowhere — just shifted from runtime to edit time:

- **Phase 9 editor (interim iGui editor):** saving a `.def`
  invalidates that node and every importer transitively; the cache
  (Phase 10) regenerates only the dirty subtree, then the JIT
  re-materialises just the affected functions. That's the closest
  analog to NewCP's hot-swap, but it's "edit → recompile
  incrementally" rather than "load a new module into a running
  address space."
- **Cache keys** `(def_hash, transitive, compiler_version,
  codegen_flags, memory_mode)` are exactly the contract that lets
  us treat unchanged subtrees as inputs that already produced
  known outputs. Static graph, dynamic incremental rebuilds over
  the static graph.

**Short version: NewCP's loader runs forever; NewM2's loader runs
once per build (or once per save-edit in the JIT session). The
graph is the same shape either way — what differs is who's
allowed to mutate it and when.**

## Implementation pointers

- `src/newm2-loader/src/loader.rs` — `build_module_graph` is the
  entry point. BFS over IMPORT clauses with Tarjan-style cycle
  detection at the end.
- `src/newm2-loader/src/graph.rs` — `ModuleNode` carries the
  parsed AST, DEF/IMPL paths, content hash, resolved imports, and
  any LOCAL MODULE names enumerated from procedure bodies.
- `src/newm2-loader/src/search_path.rs` — DEF lookup walks the
  search path in order; IMPL lookup tries same-dir first, then
  the sibling `mod` folder (`isodef`↔`isomod`, `def`↔`mod`).
- `src/newm2-loader/src/cache.rs` — scaffolding only in Phase 2;
  Phase 10 wires it into the loader fast path so unchanged DEFs
  skip re-parsing.
- `newm2 dump-module-graph FILE` — prints the graph; the
  `hello_module_graph_snapshot` compat test pins a known-good
  5-module result through `IOChan`.
