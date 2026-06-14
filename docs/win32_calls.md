# Win32 Call Flow

This document describes the exact flow that allowed the `Beep` test module to lower and JIT a Win32 API call.

## Scope

The concrete probe is [Mod/tests/t-50-060-win32-beep.mod](E:/NewM2/NewM2/Mod/tests/t-50-060-win32-beep.mod):

```modula2
MODULE T50060Win32Beep;
FROM WIN32 IMPORT Beep, BOOL;

VAR ok : BOOL;

BEGIN
  ok := Beep(440, 1)
END T50060Win32Beep.
```

The important point is that this path now uses the Windows pack, not raw reference Win32 DEF files from the filesystem.

## 1. Snapshot Generation

The source Win32 definition modules live under `windows_api/def_in`. They are parsed and projected into reduced cached DEF files under `windows_api/def_out`.

The reduced files now retain:

- `IMPORT`
- `CONST`
- `TYPE`
- `PROCEDURE` headings

For Windows API snapshot generation, the driver now also consults `windows_api/windows_api.db` while projecting each source DEF. When a procedure name resolves to a unique metadata row, the reduced heading is enriched with explicit external linkage such as `FROM "KERNEL32.dll"`.

That procedure retention plus DB-backed linkage enrichment is what makes `Beep` visible to later sema and lowering with its DLL ownership preserved in the snapshot.

Relevant code:

- [src/newm2-parser/src/types_out.rs](E:/NewM2/NewM2/src/newm2-parser/src/types_out.rs)
- [src/newm2-parser/src/parser.rs](E:/NewM2/NewM2/src/newm2-parser/src/parser.rs)
- [src/newm2-parser/src/ast.rs](E:/NewM2/NewM2/src/newm2-parser/src/ast.rs)
- [src/newm2-driver/src/main.rs](E:/NewM2/NewM2/src/newm2-driver/src/main.rs)

## 2. Pack Build And Load

The reduced DEF snapshot is serialized into a monolithic binary pack at `packs/windows_api.pack`.

Modules promoted into the workspace `library/` tree are no longer treated as import-pack modules. The filesystem library search path is consulted before the pack, and pack rebuild skips any module whose `.def` now lives under `library/**`.

Build/load code:

- [src/newm2-loader/src/windows_pack.rs](E:/NewM2/NewM2/src/newm2-loader/src/windows_pack.rs)

The pack stores, for each Windows module:

- module name
- definition file hash
- relative path back into `windows_api/def_out`
- full parsed `ast::Module`

When `--windows` is enabled, the driver ensures the pack exists and loads it from `packs/windows_api.pack`.

Driver entrypoint:

- [src/newm2-driver/src/main.rs](E:/NewM2/NewM2/src/newm2-driver/src/main.rs)

The JIT test harness uses the same pack-aware path:

- [tests/newm2-tests/src/lib.rs](E:/NewM2/NewM2/tests/newm2-tests/src/lib.rs)

## 3. Module Graph Resolution

The driver/test harness calls `build_module_graph_with_env_and_pack(...)`.

Relevant code:

- [src/newm2-loader/src/loader.rs](E:/NewM2/NewM2/src/newm2-loader/src/loader.rs)

For an import like `FROM WIN32 IMPORT Beep, BOOL;`, the resolution path is:

1. `resolve_or_load()` is called for `WIN32`.
2. If the Windows pack is present, `pack.get("WIN32")` is checked before filesystem DEF lookup.
3. The packed `ast::Module` for `WIN32` is inserted into the graph as the module definition.

This is the critical step that proves the test is pack-backed.

## 4. Sema Registers Imported Procedures

Semantic analysis walks the imported module AST and registers top-level declarations into module scope.

Relevant code:

- [src/newm2-sema/src/analyze.rs](E:/NewM2/NewM2/src/newm2-sema/src/analyze.rs)

The important steps are:

1. `analyse_module_ast()` calls `bring_in_imports(...)`.
2. Pass 1 pre-registers declarations, including `Decl::Procedure`, as `SymbolKind::Proc(...)` placeholders.
3. Pass 2 resolves the actual `ProcSig` from the procedure heading.

For `WIN32.Beep`, sema therefore has a real procedure symbol with parameter and return-type information, not just an unresolved name.

## 5. IR Lowering Materializes An External Function

Lowering happens in:

- [src/newm2-ir/src/lower.rs](E:/NewM2/NewM2/src/newm2-ir/src/lower.rs)

The important path is `resolve_name_as_value()`.

When the callee resolves to a `Proc` symbol:

1. lowering asks sema for the procedure signature
2. `get_or_add_extern()` creates an `IrModule` global of kind `Global::ExternFunc`
3. lowering emits a `ConstVal::FuncRef("Beep")`
4. the call instruction is emitted against that callee

So by the time LLVM emission starts, the IR already contains an external function declaration request for `Beep`.

## 6. LLVM Emission Declares The External Symbol

LLVM codegen happens in:

- [src/newm2-llvm/src/codegen.rs](E:/NewM2/NewM2/src/newm2-llvm/src/codegen.rs)

In `declare_globals()`, every `Global::ExternFunc` is turned into an LLVM function declaration if there is no defined body for that symbol.

For the `Beep` probe, the emitted LLVM IR contains:

```llvm
declare i32 @Beep(i64, i64)
```

and the module body contains:

```llvm
%call = call i32 @Beep(i64 440, i64 1)
```

That proves the frontend and LLVM emission path already know how to materialize the external call shape.

## 7. JIT Binds The Symbol Address

JIT startup happens in:

- [src/newm2-llvm/src/lib.rs](E:/NewM2/NewM2/src/newm2-llvm/src/lib.rs)

`run_modules()` performs two distinct binding passes:

1. `bind_runtime_helpers(...)`
2. `bind_external_functions(...)`

`bind_external_functions(...)` walks all `IrModule.globals`, finds `Global::ExternFunc`, and tries to resolve each one to a real process address.

On Windows, `resolve_external_function_address_impl(...)` currently does this by:

1. trying the exact extern name
2. if the name is qualified like `WIN32.Beep`, also trying the tail segment `Beep`
3. loading a shortlist of Win32 DLLs with `LoadLibraryW`
4. calling `GetProcAddress`
5. if found, calling `LLVMAddGlobalMapping(...)` for the LLVM function symbol

That is the step that makes the JIT'd `call @Beep(...)` land on the actual `kernel32!Beep` export at runtime.

## 8. Why This Now Works Reliably

The `Beep` path only became trustworthy after two cleanup steps:

1. procedure headings were preserved in `def_out`
2. the driver/test harness stopped seeding raw reference Win32 DEF directories into the search path under the Windows-pack path

Without those fixes, it was ambiguous whether a test was exercising:

- the pack-backed reduced snapshot, or
- a fallback raw source DEF loaded directly from the filesystem

Now the `Beep` test is a real pack-backed proof of the external-call pipeline.

## 9. Current Boundary

What is proven by `Beep`:

- packed Windows module import resolution
- packed procedure signature availability in sema
- IR `ExternFunc` materialization
- LLVM external declaration emission
- JIT symbol binding to a real Win32 export

What is not yet fully generalized:

- using the snapshot's per-procedure external link and DLL metadata during binding
- stricter pack-only enforcement for all Windows modules at loader level

`Beep` works because the external symbol name is simply `Beep`, which matches the exported Win32 function name directly.