# Strings and Character Model

*2026-05-12. Design note captured from a discussion during parser/sema
bring-up.*

## Status

NewM2 currently assumes the older simple model:

- string literals collapse to a plain Rust `String`
- character literals collapse to a plain Rust `char`
- sema knows `ACHAR` and `UCHAR`
- codegen currently treats `UCHAR` as a 16-bit type

That is not enough to support both the ASCII/Unicode split and a
clean Unicode-aware source model. This note records the agreed target
design and the implementation plan.

## Goals

1. Preserve source compatibility where practical.
2. Keep Windows wide-string interop honest.
3. Add a true one-code-point scalar type.
4. Let the compiler choose sensible defaults without hiding
   representation changes from the programmer.
5. Keep coercion rules narrow, predictable, and cheap.

## Agreed built-in character types

NewM2 keeps these names stable and adds one new type:

- `ACHAR`: 8-bit narrow character unit.
- `UCHAR`: 16-bit wide character unit, intended for Win32 / UTF-16 interop.
- `CHAR32`: 32-bit Unicode scalar value, one code point per element.

`UCHAR` is **not** redefined to mean a 32-bit code point. That would
break the expectation that `ARRAY OF UCHAR` is the wide-string type
used by Windows-facing APIs.

## Default `CHAR` and plain string mode

The compiler may support a module-level default mode pragma:

```text
<%mode:ascii>
<%mode:wide>
<%mode:unicode>
```

This mode changes only the defaults for:

- `CHAR`
- plain string literals `"..."` and `'...'`

Planned meaning:

- `ascii`: `CHAR = ACHAR`, plain string literals default to `ARRAY OF ACHAR`
- `wide`: `CHAR = UCHAR`, plain string literals default to `ARRAY OF UCHAR`
- `unicode`: `CHAR = CHAR32`, plain string literals default to `ARRAY OF CHAR32`

Rules:

- Mode is module-wide.
- Mode is part of semantic/interface identity.
- Mixed-mode imports must be checked deliberately; the compiler must not
  silently pretend that `CHAR` means the same thing across modes.

## Explicit forms remain stable

Mode changes defaults only. Explicit forms always win.

### Explicit types

- `ACHAR`
- `UCHAR`
- `CHAR32`

### Explicit string literal forms

Suffix forms are retained for compatibility:

- `"..."A`
- `"..."U`
- `"..."32`

Prefix forms may also be accepted as syntax sugar:

- `A"..."`
- `U"..."`
- `C32"..."` or `CHAR32"..."`

The suffix forms are the compatibility surface. Prefix forms are
optional convenience.

### Explicit character construction

The language/runtime should expose explicit construction/conversion
operations for the three scalar types. Naming follows this convention:

- `ACHR(n)`
- `UCHR(n)`
- `CHAR32CHR(n)` or a shorter final spelling such as `C32CHR(n)`

The exact spelling can be settled later. The important point is that the
32-bit scalar family gets a first-class constructor rather than being
smuggled through `UCHAR`.

## Representation model

The three character families have different semantics:

- `ACHAR[i]` addresses one 8-bit code unit.
- `UCHAR[i]` addresses one 16-bit code unit.
- `CHAR32[i]` addresses one Unicode scalar value.

This means:

- `UCHAR` arrays are suitable for UTF-16 / Win32 interop.
- `CHAR32` arrays are suitable for code-point indexing.
- Neither `UCHAR` nor `CHAR32` implies one user-visible grapheme per
  element.

That last point is intentional. NewM2 tracks code units and code points,
not grapheme-cluster segmentation.

## Coercion rules

The agreed policy is deliberately narrow:

- widening scalar coercions are implicit
- narrowing scalar coercions are implicit only for compile-time values
  proven to fit
- non-constant narrowing requires explicit conversion
- string-family conversions are explicit encoding conversions, not
  ordinary coercions

### Scalar widening (implicit)

- `ACHAR -> UCHAR`
- `ACHAR -> CHAR32`
- `UCHAR -> CHAR32`

### Scalar narrowing (implicit only when constant-fit)

- constant `UCHAR -> ACHAR` if value fits in `ACHAR`
- constant `CHAR32 -> UCHAR` if value fits in one `UCHAR`
- constant `CHAR32 -> ACHAR` if value fits in `ACHAR`

### Scalar narrowing (explicit for non-constant values)

- variable `UCHAR -> ACHAR`
- variable `CHAR32 -> UCHAR`
- variable `CHAR32 -> ACHAR`

Those explicit conversions may lower to checked runtime conversions when
the value is not constant.

### Important distinction: `CHAR32 -> UCHAR`

This conversion is only scalar-to-scalar when the source value fits in a
single 16-bit unit. It is **not** an implicit UTF-16 encoding step for
values above `0xFFFF`.

If a `CHAR32` value requires multiple UTF-16 units, converting it to a
single `UCHAR` is an error.

### String conversions

These are not ordinary coercions:

- `ARRAY OF ACHAR <-> ARRAY OF UCHAR`
- `ARRAY OF UCHAR <-> ARRAY OF CHAR32`
- `ARRAY OF ACHAR <-> ARRAY OF CHAR32`

They are explicit encoding conversions and should be exposed via runtime
helpers or dedicated intrinsics, not silently inserted by sema.

## Literal typing rules

### Character literals

Character literals should carry an explicit literal flavor through the
lexer and parser instead of collapsing immediately to Rust `char`.

Minimum semantic model:

- raw source spelling
- decoded scalar value when representable
- explicit flavor (`default`, `A`, `U`, `32`)

### String literals

String literals should carry:

- explicit flavor (`default`, `A`, `U`, `32`)
- decoded sequence of scalar values
- raw source spelling for diagnostics and exact pretty-printing

Sema then maps the literal to the correct array-of-character family
according to:

- explicit literal flavor, if present
- otherwise module mode
- otherwise surrounding type context

## Module/interface rules

Because mode can redefine `CHAR`, the compiler must treat mode as part of
module identity for separate compilation.

At minimum, symbol/interface data for a compiled module must record:

- active character mode
- effective meaning of `CHAR`
- effective meaning of plain string literals in constants and initializers

The compiler must not silently unify:

- `CHAR` from an `ascii` module
- `CHAR` from a `wide` module
- `CHAR` from a `unicode` module

Explicit `ACHAR`, `UCHAR`, and `CHAR32` remain stable across all modes.

## Runtime and FFI policy

### Windows interop

- Win32 `...A` APIs consume `ACHAR` strings.
- Win32 `...W` APIs consume `UCHAR` strings.
- `CHAR32` values/strings require explicit conversion before crossing
  those boundaries.

### Text processing

- portable byte-oriented text helpers can operate on `ACHAR`
- wide/UTF-16 helpers can operate on `UCHAR`
- Unicode code-point operations operate on `CHAR32`

The runtime should not pretend that these are interchangeable storage
formats.

## Type-aware I/O policy

This needs to be treated as part of the string design, not as a later
runtime detail.

Today the runtime shim surface is still effectively narrow-only:

- `nm2_io_write_str(ptr: *const c_char)` assumes NUL-terminated narrow text
- `nm2_io_write_char(c: u8)` assumes an 8-bit character

That is acceptable as a temporary bootstrap surface, but it is not the
target design.

### High-level rule

I/O routines that traffic in characters or strings must be aware of the
character family they read or write.

That means:

- `READ`/`WRITE` of scalar characters is family-specific
- `ReadString`/`WriteString`-style routines are family-specific
- line ending and numeric formatting policy may be shared
- character storage and encoding conversion policy may not be shared

### Existing ISO text modules

The existing `TextIO` / `STextIO` interfaces are written in terms of
`CHAR` and `ARRAY OF CHAR`.

Under the planned mode system, these modules become mode-sensitive
facades:

- in `ascii` mode they operate on `ACHAR`
- in `wide` mode they operate on `UCHAR`
- in `unicode` mode they operate on `CHAR32`

This is one of the reasons module mode must be part of interface
identity. A `TextIO` built in `ascii` mode and a `TextIO` built in
`wide` mode do not describe the same procedure signatures.

### Low-level runtime boundary

The runtime must not expose one "string write" entry point and rely on
the caller to reinterpret buffers.

Instead, the low-level boundary should have distinct routines for at
least:

- narrow character output/input
- wide/UTF-16 character output/input
- code-point character output/input
- narrow string output/input
- wide/UTF-16 string output/input
- code-point string output/input

Exact exported names can be decided later, but the separation itself is
not optional.

### No silent transcoding in I/O

The compiler/runtime must not silently do any of the following just
because a text routine is called:

- write `CHAR32` text through a `UCHAR` sink by auto-encoding surrogate pairs
- read `UCHAR` text into `ACHAR` by replacement or truncation
- pass `ARRAY OF ACHAR` to a `WriteString` expecting `ARRAY OF UCHAR`

If encoding conversion is desired, it should happen explicitly through a
conversion helper or an explicitly typed I/O routine.

### Read-side rules

Read routines need stricter rules than write routines because storage is
supplied by the caller.

- `ReadChar(VAR ch)` writes exactly one value of the routine's character family
- `ReadString(VAR s)` fills an array of the routine's character family
- overflow/truncation behavior is reported explicitly, not hidden behind
  lossy conversion
- end-of-line/end-of-input signaling remains orthogonal to character width

### Write-side rules

Write routines can share formatting logic, but not representation.

- `WriteChar` writes exactly one value of the routine's character family
- `WriteString` writes a buffer of the routine's character family
- numeric `WriteInt` / `WriteCard` / similar routines may share one
  formatting core, but final emission must target a chosen character family
- padding characters and separators must be representable in the target family

### Stable versus mode-sensitive surfaces

NewM2 should distinguish two layers:

- mode-sensitive source-compatible facades such as `TextIO` / `STextIO`
- stable representation-specific helpers used by runtime, FFI, and explicit conversions

This lets user code keep familiar `CHAR`-based APIs where source
compatibility matters, while still giving the compiler/runtime a fixed
surface for exact-family operations.

The exact public names for the stable helpers are still open. What is
already decided is that they cannot be a single overloaded narrow-only
API pretending every text buffer is the same thing.

### Minimum runtime I/O ABI

Before more runtime code is added, NewM2 should freeze a small ABI
contract for text I/O.

This contract should be the minimum set of things codegen may rely on,
and no larger.

#### What should be fixed now

- helper families are representation-specific: `A`, `U`, later `C32`
- write helpers exist separately for scalar chars, strings, and numeric text
- read helpers exist separately for scalar chars and string/buffer reads
- terminal-backed and file/channel-backed operations are distinct concepts
- text conversion is not part of the low-level I/O ABI

#### What should stay unfixed for now

- final exported helper names
- whether stable helpers are exposed as public modules or only as runtime symbols
- whether file-backed reads/writes are direct runtime calls or layered through channel objects
- the exact `CHAR32` helper naming scheme

#### Required semantic contract

Whatever names are chosen, the runtime ABI must make the following
observable behaviors explicit:

- end-of-input
- end-of-line
- output newline emission
- truncation / out-of-range on buffer reads
- encoding failure where applicable
- no silent replacement or narrowing

#### Terminal versus file/channel boundary

The runtime must not blur these into one helper family.

- bootstrap terminal helpers may exist as host-environment operations
  against stdin/stdout for bring-up and testing
- real terminal and file/channel I/O should live in modules later, once
  the Windows binding surface is defined
- file/channel helpers operate on an explicit runtime object or handle
- `TextIO`-style source interfaces may wrap either one, but the low-level
  ABI should not pretend they are the same thing

For Windows specifically, terminal I/O and file I/O may ultimately use
different host APIs even when the source-level surface looks similar.

#### Current implementation status

At the moment, the runtime only has a provisional write-side bootstrap
surface. That is useful for bring-up, but it is not yet the ABI to
standardize around.

The intended long-term split is:

- runtime shims stay minimal and exist mainly for JIT/bootstrap support
- real terminal/file/channel behavior is implemented in modules once
  NewM2 can bind the relevant Windows APIs cleanly

So the immediate rule is:

- it is acceptable to add small bootstrap helpers
- it is not acceptable to keep expanding the runtime surface without
  first deciding the minimum ABI above

## Compiler implementation plan

### Phase 1: front-end representation

1. Extend lexer token kinds so string and character literals preserve
   explicit flavor instead of discarding suffixes.
2. Add optional prefix parsing for explicit literal forms if desired.
3. Extend AST literal nodes to carry flavor and decoded content.
4. Parse and store module-level `<%mode:...>` pragmas.

### Phase 2: semantic model

1. Add `CHAR32` to the built-in type catalog.
2. Keep `ACHAR` and `UCHAR` fixed-width and mode-independent.
3. Make `CHAR` resolve through the active module mode.
4. Implement the scalar coercion matrix described above.
5. Reject implicit string-family conversions.
6. Teach constant folding to evaluate fit-based narrowing at compile
   time.

### Phase 3: IR and codegen

1. Represent `ACHAR` as 8-bit.
2. Represent `UCHAR` as 16-bit.
3. Represent `CHAR32` as 32-bit.
4. Emit string globals with the correct element width and terminator.
5. Lower explicit narrowing casts to checked conversions when they are
   not compile-time constants.

### Phase 4: runtime

1. Add explicit conversion helpers between `ACHAR`, `UCHAR`, and
   `CHAR32` strings.
2. Provide `Length`/`ULength`/`C32Length`-style helpers only where the
   representation model makes sense.
3. Split text I/O shims by character family instead of routing all text
  through narrow C-style strings.
4. Keep encoding conversion APIs explicit.
5. Keep FFI helpers representation-specific.

### Phase 4a: text I/O surface

1. Decide which public modules remain mode-sensitive facades
  (`TextIO`, `STextIO`, related wrappers).
2. Define stable runtime/helper entry points for `ACHAR`, `UCHAR`, and
  `CHAR32` text I/O.
3. Ensure read-side APIs write into buffers of the correct family only.
4. Ensure write-side numeric formatting renders through the selected
  family instead of assuming narrow output.
5. Add capture/test infrastructure that can observe all three text families.

### Phase 5: compatibility and tests

1. Preserve existing suffix forms `"..."A` and `"..."U`.
2. Add parser, sema, and codegen tests for mode-sensitive `CHAR`.
3. Add scalar coercion tests for widening, constant-fit narrowing, and
   required explicit narrowing.
4. Add string conversion tests proving that no silent family conversion
   occurs.
5. Add Win32 interop tests that confirm `UCHAR` remains 16-bit.
6. Add text I/O tests proving that narrow, wide, and code-point paths do
  not collapse onto the same runtime buffer contract.

## Non-goals

The following are explicitly out of scope for this design note:

- grapheme-cluster indexing
- locale-sensitive collation
- automatic normalization
- automatic transcoding at call sites
- redefining `UCHAR` to 32-bit

## Summary

The agreed direction is:

- preserve `ACHAR` and `UCHAR`
- add `CHAR32` for true Unicode scalar values
- optionally use module mode to define default `CHAR` and plain string
  literal meaning
- keep explicit types and explicit literal flavors stable across modes
- keep coercion narrow and predictable: widen automatically, narrow only
  when provably safe, otherwise require explicit conversion

This gives NewM2 three honest character representations instead of one
overloaded type pretending to satisfy incompatible goals.