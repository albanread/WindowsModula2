# The Standard Environment

Everything available to a Modula-2 program without any `IMPORT` — the pervasive
procedures and functions, the `SYSTEM` pseudo-module, and the key library modules you
reach with a single `IMPORT` line.

## Pervasive procedures and functions

The names below are *pervasive identifiers*: predeclared in an enclosing pseudo-scope,
visible in every module without import, and re-declarable (though you should not). The
lexer returns them as plain `Ident` tokens; sema resolves them. The complete registration
is at `src/newm2-sema/src/analyze.rs` line 471 — every name in the `for name in [...]`
loop is confirmed present.

### Storage

| Procedure | Signature | What it does |
|-----------|-----------|--------------|
| `NEW` | `NEW(p)` or `NEW(p, n)` | Allocates a record (or `n` elements) on the heap via `HeapAlloc` and assigns the pointer `p`. The payload is zero-initialised. Must be paired with `DISPOSE`. |
| `DISPOSE` | `DISPOSE(p)` | Frees the heap object pointed to by `p` via `HeapFree` and sets `p` to `NIL`. Required to avoid leaks. |
| `HALT` | `HALT` | Terminates the program immediately. |
| `ASSERT` | `ASSERT(b)` or `ASSERT(b, n)` | Halts with an optional error code if `b` is `FALSE`. |

`NEW` and `DISPOSE` are covered in depth in [Memory & exceptions](10-memory-and-exceptions.md).

### Ordinal

| Function | Signature | What it does |
|----------|-----------|--------------|
| `INC` | `INC(v)` or `INC(v, n)` | Increments an ordinal variable `v` by 1 or by `n`. |
| `DEC` | `DEC(v)` or `DEC(v, n)` | Decrements an ordinal variable `v` by 1 or by `n`. |
| `ODD` | `ODD(i) : BOOLEAN` | Returns `TRUE` if the integer `i` is odd. |

`INC` and `DEC` are *procedures*, not functions: they modify their first argument in
place. The optional second argument must be a constant or variable of any integer type.

### Set

| Procedure | Signature | What it does |
|-----------|-----------|--------------|
| `INCL` | `INCL(s, e)` | Includes element `e` in set `s` (equivalent to `s := s + {e}`). |
| `EXCL` | `EXCL(s, e)` | Excludes element `e` from set `s` (equivalent to `s := s - {e}`). |

```modula2
VAR flags : BITSET;
BEGIN
  flags := BITSET{};
  INCL(flags, 3);   (* flags = {3} *)
  EXCL(flags, 3);   (* flags = {} *)
END;
```

### Array

| Function | Signature | What it does |
|----------|-----------|--------------|
| `HIGH` | `HIGH(a) : CARDINAL` | Returns the upper bound of the first (or only) open-array dimension. For a formal `ARRAY OF T` parameter, `HIGH(a)` is the index of the last element. |

```modula2
PROCEDURE Sum(a : ARRAY OF INTEGER) : INTEGER;
VAR i, s : INTEGER;
BEGIN
  s := 0;
  FOR i := 0 TO HIGH(a) DO s := s + a[i] END;
  RETURN s
END Sum;
```

### Size

| Function | Signature | What it does |
|----------|-----------|--------------|
| `SIZE` | `SIZE(v) : CARDINAL` | Storage size of a variable or a type expression, in bytes. `SIZE(INTEGER)` and `SIZE(x)` both work. |
| `TSIZE` | `TSIZE(T) : CARDINAL` | Size of a type, always taking a type expression (not a variable). Identical to `SIZE` when given a type; `TSIZE` is the ISO-preferred spelling for the type-only form. |

Both `SIZE` and `TSIZE` are registered in the pervasive scope
(`src/newm2-sema/src/analyze.rs` line 471). In constant expressions `SIZE(T)` is
evaluated at compile time.

### Conversion and coercion

| Function | Signature | What it does |
|----------|-----------|--------------|
| `ORD` | `ORD(x) : CARDINAL` | Ordinal value of a `CHAR`, `BOOLEAN`, or enumeration value. |
| `CHR` | `CHR(n) : CHAR` | Character whose ordinal is `n`. |
| `VAL` | `VAL(T, x)` | Converts value `x` to type `T`. The first argument is a type name. Used for integer width changes, ordinal-to-enumeration, and scalar cross-family conversions. |
| `CAP` | `CAP(c) : CHAR` | Uppercase of `CHAR` `c`; letters become uppercase, others are unchanged. |
| `ODD` | `ODD(i) : BOOLEAN` | (See Ordinal above.) |
| `ABS` | `ABS(x) : T` | Absolute value of an integer or real. Returns the same type as its argument. |
| `FLOAT` | `FLOAT(i) : REAL` | Converts an integer to `REAL`. |
| `TRUNC` | `TRUNC(r) : INTEGER` | Truncates a `REAL` or `LONGREAL` to `INTEGER` (towards zero). |
| `INT` | `INT(x) : INTEGER` | Converts a cardinal or other ordinal to `INTEGER`. Registered in sema (`analyze.rs` line 474). |
| `LFLOAT` | `LFLOAT(x) : LONGREAL` | Converts an integer or `REAL` to `LONGREAL`. Registered in sema. |
| `ENTIER` | `ENTIER(r) : INTEGER` | Floor of a real value (largest integer not greater than `r`). ISO 10514-1. Registered in sema. |
| `MIN` | `MIN(T)` | Minimum value of an ordinal or real type. Used in constant expressions. |
| `MAX` | `MAX(T)` | Maximum value of an ordinal or real type. Used in constant expressions. |

A round-trip example from `Mod/tests/t-10-040-val-roundtrip.mod`:

```modula2
VAR src : LONGREAL;  mid : INTEGER64;
BEGIN
  src := 42.0;
  mid := VAL(INTEGER64, src);
  SWholeIO.WriteInt(VAL(INTEGER, mid), 0);
END
```

> **Not registered:** Standard PIM also lists `FLOAT` as accepting a `LONGREAL` argument
> for explicit widening; NewM2 registers it as a single pervasive name and relies on the
> type checker to handle both widths. The ISO `FLOATD` (double) alias is not separately
> registered — use `LFLOAT` or `VAL(LONGREAL, x)` instead.

---

## The SYSTEM module

`SYSTEM` is a *pseudo-module* built directly into sema — it has no `.def` file. Import it
with `IMPORT SYSTEM;` and use names qualified (`SYSTEM.ADDRESS`, `SYSTEM.CAST`, …). The
full registration is in `src/newm2-sema/src/analyze.rs` starting at line 496
(`build_intrinsic_module_scope` for `"SYSTEM"`).

### Types exported from SYSTEM

| Name | What it is |
|------|-----------|
| `ADDRESS` | Pointer-sized unsigned integer. The canonical type for raw pointer arithmetic (`SYSTEM.ADDRESS` and the pervasive `ADDRESS` name both map to `Builtin::SysAddress`). |
| `WORD` | Native machine word (pointer-width unsigned). |
| `BYTE` | Single-byte storage unit (`Builtin::SysByte`). |
| `LOC` | Smallest addressable unit (`Builtin::SysLoc`). ISO 10514-1. |
| `BITSET` | `SYSTEM.BITSET` — same width as a machine word; available qualified to avoid ambiguity with the pervasive `BITSET`. |
| `ADRINT` | Signed address-arithmetic integer. |
| `ADRCARD` | Unsigned address-arithmetic integer (`MACHINEWORD` is a registered alias). |
| `CARD8/16/32/64` | Exact-width cardinal aliases for C interop. |
| `INT8/16/32/64` | Exact-width signed aliases for C interop. |
| `PROTECTION` | Interrupt protection level (cardinal-sized). |
| `VA_LIST` | C variadic argument list pointer (address-sized). |
| `FUNC` | Generic function/procedure pointer (address-sized). |

### Procedures exported from SYSTEM

| Name | What it does |
|------|-------------|
| `ADR(v) : ADDRESS` | Address of variable `v`. The fundamental address-of intrinsic. |
| `CAST(T, x)` | Type transfer: reinterprets the bit pattern of `x` as type `T` with no conversion. `SYSTEM.CAST(INTEGER64, src)` — see `Mod/tests/t-10-050-system-cast.mod`. |
| `TSIZE(T) : CARDINAL` | Type size (also available pervasively). |
| `ADDADR` `SUBADR` `DIFADR` `MAKEADR` | Address arithmetic (add/subtract/difference/construct). |
| `SHIFT(x, n)` | Logical bit shift; positive `n` shifts left. |
| `ROTATE(x, n)` | Bit rotation. |
| `OFFS(p, n)` | Offset-from-pointer arithmetic (NewM2 extension). |
| `SWAPENDIAN` `BIGENDIAN` | Endian-swap intrinsics (NewM2 extension). |
| `PUSHREGISTERS` `POPREGISTERS` | Save/restore callee registers around low-level asm stubs. |
| `VA_START` `VA_END` `VA_ARG` | C variadic argument access. |
| `UNREFERENCED_PARAMETER` | Suppress unused-variable warnings (NewM2 extension). |

```modula2
IMPORT SYSTEM;
VAR src : INTEGER;  wide : INTEGER64;
BEGIN
  src  := 17;
  wide := SYSTEM.CAST(INTEGER64, src);
END
```

### Coroutines — SYSTEM vs COROUTINES

The classic PIM `SYSTEM` exports (`NEWPROCESS`, `TRANSFER`, `IOTRANSFER`,
`GetCurrentCoroutineId`) are registered in sema as *legacy aliases*
(`analyze.rs` line 544), but calling them produces a focused
"not yet implemented" diagnostic pointing to the ISO `COROUTINES` pseudo-module.

The ISO `COROUTINES` pseudo-module (also intrinsic) exports:
`COROUTINE` (a type), `INTERRUPTSOURCE`, `NEWCOROUTINE`, `TRANSFER`, `IOTRANSFER`,
`ATTACH`, `DETACH`, `IsATTACHED`, `HANDLER`, `CURRENT`, `LISTEN`, `PROT`,
`COROUTINEDONE`. These names are registered in sema (lines 577–629) but coroutine
execution is **deferred** — the scaffolding is in place so name resolution does not
fail, but the back-end does not yet generate working coroutine code.

---

## Key library modules

These modules are resolved at compile time as ordinary `.def`/`.mod` pairs or as JIT
runtime shims; import them with a plain `IMPORT` statement.

### Text I/O: STextIO and SWholeIO

`STextIO` is the primary character-output module. The JIT binds its procedures directly
to runtime helpers in `src/newm2-llvm/src/lib.rs` (line 242):

| Procedure | What it does |
|-----------|-------------|
| `STextIO.WriteString(s)` | Write a string to standard output. |
| `STextIO.WriteLn` | Write a newline. |
| `STextIO.WriteChar(c)` | Write a single `CHAR`. |
| `SWholeIO.WriteInt(i, w)` | Write signed integer `i` in field width `w`. |
| `SWholeIO.WriteCard(c, w)` | Write cardinal `c` in field width `w`. |

The classic hello-world (from `Mod/tests/t-30-010-write-str.mod`):

```modula2
MODULE Hello;
IMPORT STextIO;
BEGIN
  STextIO.WriteString("Hello, NewM2!");
  STextIO.WriteLn;
END Hello.
```

`InOut` is a PIM-classic alias: `InOut.WriteString`, `InOut.WriteLn`, `InOut.Write`,
`InOut.WriteInt`, and `InOut.WriteCard` are all bound to the same runtime shims.

> **SRealIO and SLongIO.** The ISO standard also defines `SRealIO` (real I/O) and
> `SLongIO` (long-integer I/O). These are not yet wired in the JIT runtime — use
> `SWholeIO.WriteInt` for integers and format reals via `VAL` conversion for now.

### Storage

`Storage` provides the ISO-standard heap allocation interface that underlies `NEW` and
`DISPOSE`:

| Procedure | What it does |
|-----------|-------------|
| `Storage.ALLOCATE(p, n)` | Allocate `n` bytes; assign the `ADDRESS` to `p`. |
| `Storage.DEALLOCATE(p, n)` | Free `n` bytes starting at `p`. |

`ALLOCATE` calls `HeapAlloc`; `DEALLOCATE` calls `HeapFree`. You rarely call `Storage`
directly — use `NEW`/`DISPOSE` instead.

### Float

`Float` is a library module providing floating-point exception management and
rounding conversions. From `library/advapidef/Float.def` (exercised in
`Mod/tests/t-50-070-float-library.mod`):

```modula2
IMPORT Float, STextIO, SWholeIO;
VAR flags : Float.FPExceptions;
BEGIN
  Float.Init;
  Float.ClearFPExceptions;
  SWholeIO.WriteInt(Float.NearestToInt32(1.75), 0);
  STextIO.WriteLn;
  flags := Float.GetFPExceptions() + Float.FPException{Float.exOverflow};
  IF Float.exOverflow IN flags THEN … END;
END
```

`Float.FPExceptions` is a `PACKEDSET OF FPException`, and set-constructor syntax
`Float.FPException{…}` is standard Modula-2.

### SYSTEM (library view)

As described above, `SYSTEM` is pseudo-module with no `.def` file — `IMPORT SYSTEM;`
is always available and never requires a library path.

### The NM2.IO Unicode extensions

For `UCHAR`/`ACHAR` text output, NewM2 provides a non-standard `NM2.IO` qualified
namespace bound at JIT time (`src/newm2-llvm/src/lib.rs` lines 252–255):
`NM2.IO.WriteUChar`, `NM2.IO.WriteUInt`, `NM2.IO.WriteUCard`, `NM2.IO.WriteUString`.
These are NewM2 extensions; they do not appear in ISO Modula-2.

---
[NewM2 Guide home](index.md) · [Declarations & types](04-declarations-and-types.md) · [Memory & exceptions](10-memory-and-exceptions.md)
