# 128-bit laned SIMD scalar types — design

Status: design only (no source changed)
Author: type-system enhancement for first-class SIMD vectors
Date: 2026-06-13

---

## Summary

Add a family of **laned scalar types** — fixed-width, register-resident vectors
of floating-point lanes — as first-class members of the NewM2 type system, so
that ordinary Modula-2 code can express SIMD computation directly:

| M2 type     | LLVM type        | lanes | element | width |
|-------------|------------------|-------|---------|-------|
| `REAL64X2`  | `<2 x double>`   | 2     | f64     | 128b  |
| `REAL32X4`  | `<4 x float>`    | 4     | f32     | 128b  |
| `REAL16X8`  | `<8 x half>`     | 8     | f16     | 128b  |

A laned value is a **single 128-bit scalar** that lives in a stack slot / XMM
register, *not* an array in memory. The arithmetic operators (`+ - * /`) act
**element-wise across all lanes at once**; a scalar broadcasts to every lane;
`v[i]` reads/writes one lane. An `ARRAY [0..n] OF REAL32X4` on the heap is a
contiguous, 16-byte-aligned block that maps directly onto an aligned SIMD load
loop — the central idiom this design enables.

The feature is deliberately built to need **no new syntax**: it reuses the
existing aggregate-constructor (`T{…}`), indexing (`v[i]`), arithmetic
operators, and pervasive-name machinery (the same path `REAL32`/`REAL16` took).
The novelty is entirely in the type system, IR, and codegen.

A general `TypeKind::Vector { lanes, base }` underlies the three named types, so
the design extends cleanly to 256-bit (AVX: `REAL64X4`, `REAL32X8`) and integer
lanes (`INT32X4`, …) later without re-litigating the model.

---

## Motivation

NewM2 is Windows-first with a Win32/COM/Rust FFI surface; its workloads
increasingly want matrix/vector math (graphics transforms, signal processing,
ML inference). Today the only SIMD access is through the `new-asm` inline-ASM
facility — you write raw `<4 x f32>` assembly. That is expert-only and not
composable.

The goal is **easy SIMD programming in plain Modula-2**: declare a `REAL32X4`,
add two of them with `+`, index a lane, store an array of them — and get aligned
vector instructions, with the type system enforcing lane-count/element-type
correctness.

> Note (from the requirement): Intel CPUs do not implement *scalar* fp16
> arithmetic outside of SIMD lanes; f16 is a vector/storage format. This design
> embraces that — `REAL16X8` is where f16 math actually belongs. See
> [§ f16 lanes](#f16-lanes-the-intel-reality).

---

## What exists today

- **`new-asm` register classes** (`new-asm/src/types.rs`): `AsmType` /
  `AsmRetType` already model `FQuad` (`<4 x f32>`, XMM) and `FOct`
  (`<8 x f32>`, YMM) for typed inline-ASM procedure params/returns. So the
  *ABI* layer already passes/returns 128- and 256-bit float vectors by value in
  vector registers (`codegen.rs:139-154`). This design promotes that capability
  from "ASM-only register class" to "first-class M2 value type", and the two
  should converge (an `FQuad` ASM proc param should accept a `REAL32X4`).
- **Scalar float builtins**: `Real` (f64), `Real32` (f32, true), `Real16` (f16,
  true) — `src/newm2-sema/src/types.rs`. `Complex` already proves the type
  system can carry a *composite* scalar (`struct{f64,f64}` in `builtin_type`),
  so a "scalar that is several lanes" is not a foreign concept.
- **`nm2_alloc` is 16-byte aligned** (`src/newm2-runtime/src/heap.rs:61`):
  *"Returns a 16-byte-aligned pointer."* Every heap block — and therefore every
  element of a heap `ARRAY OF REAL32X4` — is already correctly aligned for
  aligned SIMD loads/stores. **No allocator change is needed for 128-bit.**
- **codegen → LLVM**: `builtin_type` (`src/newm2-llvm/src/codegen.rs:243`) is
  the single Builtin→LLVM-type map; `ctx.f32_type().vec_type(4)` is how a
  `<4 x float>` is already produced. Adding vector lowering is local to a few
  match arms there plus the IR.

What is **missing**: a value type in the M2 type system, element-wise operator
lowering, lane access, construction/broadcast, and the reduction/FMA surface.

---

## The type

### Representation

Add one `TypeKind`:

```rust
// src/newm2-sema/src/types.rs, enum TypeKind
/// A SIMD lane vector: `lanes` copies of a scalar `base`, held as a single
/// register-width value (`<lanes x base>` in LLVM). `lanes * SIZE(base)` is a
/// hardware vector width — 16 bytes (SSE/XMM) now; 32 (AVX) / 64 (AVX-512)
/// later. `base` is a float builtin (Real/Real32/Real16) initially; integer
/// lanes are a forward extension.
Vector { lanes: u32, base: TypeId },
```

Three pervasive **named aliases** are registered exactly like `REAL32`/`REAL16`
were (`build_pervasive` in `analyze.rs`), so no parser or keyword change is
required:

```text
REAL64X2  ≙  Vector { lanes: 2, base: Real   }   <2 x double>
REAL32X4  ≙  Vector { lanes: 4, base: Real32 }   <4 x float>
REAL16X8  ≙  Vector { lanes: 8, base: Real16 }   <8 x half>
```

`is_same_family` keeps each vector type **distinct** (identity only), matching
the `Real32`/`Real16` precedent — a `REAL32X4` is not silently a `REAL64X2`.

### Why a distinct type and not `ARRAY [0..3] OF REAL32`

An `ARRAY` is memory-resident, has no arithmetic operators, and carries no
alignment/register-residency guarantee. A `Vector`:

1. lives in a register / 16-aligned slot and is passed by value;
2. defines element-wise `+ - * /` and scalar broadcast;
3. guarantees a hardware lane layout (so it round-trips through Win32/`new-asm`
   and aligned loads).

Keeping it nominally separate is what lets the operators mean "SIMD" without
overloading array semantics.

### Sizing & alignment

`type_size_bytes(REAL32X4) = 16`, `alignment = 16`. (For the general type,
`size = lanes * SIZE(base)`, `align = size` rounded to the hardware vector
width.) Stack `alloca`s for vectors are emitted with `align 16`; record fields
of vector type force the record's alignment to ≥16; `ARRAY OF REAL32X4` has
stride 16 and, on a 16-aligned base (guaranteed on the heap, and arranged on the
stack), every element is aligned.

---

## Surface: zero new syntax

Everything below reuses constructs NewM2 already parses.

### Declaration

```modula2
VAR a, b, c : REAL32X4;
    grid    : ARRAY [0..1023] OF REAL32X4;   (* 16 KiB, 16-aligned *)
    p       : POINTER TO ARRAY [0..0] OF REAL32X4;  (* heap, flex *)
```

### Construction & broadcast

Reuse the aggregate constructor `T{…}` and add a one-element **broadcast** form:

```modula2
a := REAL32X4{1.0, 2.0, 3.0, 4.0};   (* lane list *)
b := REAL32X4{0.0};                  (* broadcast: all four lanes 0.0 *)
c := SPLAT(REAL32X4, x);             (* broadcast a runtime scalar x *)
```

`REAL32X4{e}` with a single element is the broadcast/splat; with `lanes`
elements it is the full lane list. `SPLAT(T, x)` is the runtime broadcast
pseudo-function (a pervasive builtin, like `CMPLX`).

### Element-wise arithmetic & scalar broadcast

```modula2
c := a + b;        (* lane-wise add  : 4 fadds in one fadd <4 x float> *)
c := a * b;        (* lane-wise mul *)
c := a * 2.0;      (* scalar 2.0 broadcast to all lanes, then mul *)
c := a + 1.0;      (* scalar broadcast add *)
```

The binary-operator type rules gain: `Vector op Vector → Vector` (same type,
element-wise) and `Vector op scalar` / `scalar op Vector` → broadcast the scalar
(a width-polymorphic real literal, or an explicit `SPLAT`, adapts to the lane
element type). Mixing two *different* vector types is a type error (use an
explicit conversion).

### Lane access

Reuse indexing; a lane index is `0..lanes-1`, a compile-time-checked range when
constant:

```modula2
x := a[0];          (* extractelement — read lane 0 (a REAL32) *)
a[3] := y;          (* insertelement — write lane 3 *)
```

### Reductions, FMA, and element-wise math (pervasive pseudo-functions)

Provided as builtins (resolved like `MAX`/`CMPLX`/`ABS`):

| builtin              | meaning                                   | LLVM |
|----------------------|-------------------------------------------|------|
| `SUM(v)`             | horizontal add of all lanes → scalar      | `llvm.vector.reduce.fadd` |
| `DOT(a, b)`          | `SUM(a*b)`                                 | mul + reduce |
| `FMA(a, b, c)`       | fused `a*b + c`, lane-wise                 | `llvm.fma.<N x T>` |
| `SQRT(v)`            | lane-wise square root                      | `llvm.sqrt.<N x T>` |
| `MIN(a,b)`/`MAX(a,b)`| lane-wise min/max (already overloaded)     | `llvm.minnum/maxnum` |
| `ABS(v)`             | lane-wise absolute value                   | `llvm.fabs` |
| `SPLAT(T, x)`        | broadcast scalar `x` to a `T`              | insert+shuffle splat |
| `VCVT(T, v)`         | convert lanes between vector types         | `fptrunc`/`fpext`/`sitofp` |

`VCVT(REAL32X4, r64x2pair)` etc. handle cross-width lane conversion; the f16↔f32
case is the load/compute path of [§ f16 lanes](#f16-lanes-the-intel-reality).

This surface is deliberately small and operator-first; richer permute/shuffle
and masked operations are a later phase ([§ Phasing](#phasing)).

---

## Type-system integration (sema)

`src/newm2-sema/src/types.rs` / `analyze.rs`:

- **`TypeKind::Vector`** added; `intern`/`Display` as `REALxxxXn`.
- **`build_pervasive`**: register `REAL64X2`/`REAL32X4`/`REAL16X8`.
- **`type_size_bytes`**: `lanes * size(base)` (16 for the three).
- **`is_same_family`**: identity only (distinct types).
- **`is_numeric_type`**: a `Vector` is numeric (so it accepts `+ - * /`), but
  **not** ordinal and **not** a valid array index / CASE / FOR control type.
- **arithmetic typing** (the `Add/Sub/Mul/Div` arm): `Vector⊕Vector` → same
  `Vector` (require identical type); `Vector⊕scalar` → `Vector` if the scalar is
  a real literal or the same lane element type (broadcast); else error.
- **assignment/param compatibility**: a `Vector` is assignment-compatible only
  with the identical `Vector` type (plus the constructor / `SPLAT` r-values).
- **constructor checking**: `REAL32X4{…}` requires either 1 element (broadcast)
  or exactly `lanes` elements, each compatible with `base`.
- **lane indexing**: `v[i]` types as `base`; a constant `i` is range-checked
  `0..lanes-1`; the array-index machinery is reused but the result type comes
  from `base`, not an array element.
- **forbid silently**: `VAR x: VECTOR` with `lanes*size ∉ {16,32,64}`; a vector
  as a SET element, array index, or FOR variable.

`Complex` is the closest existing analogue and a good template for "a builtin
scalar that is structurally several floats."

---

## IR & lowering

`src/newm2-ir/src/lower.rs`:

- **`expr_is_float` / `transfer_class`**: a `Vector` of float lanes is a float
  for instruction selection (so `+` lowers to `FAdd`, not integer add).
- **arithmetic**: `Vector + Vector` lowers to the existing `FAdd`/`FMul`/… on
  vector-typed SSA values — codegen does the rest. A `Vector ⊕ scalar` inserts a
  **splat** (broadcast) of the scalar to the vector type first, then the
  vector op.
- **construction**: `REAL32X4{a,b,c,d}` lowers to a chain of `insertelement`
  (or, for constant lanes, a `ConstVal::Vector`); the 1-element form lowers to a
  splat.
- **lane access**: new IR ops `VecExtract { vec, lane }` / `VecInsert { vec,
  lane, val }` → `extractelement`/`insertelement`.
- **reductions / intrinsics**: `SUM`/`FMA`/`SQRT`/… lower to calls of the
  corresponding LLVM vector intrinsics (declared in the module like the other
  `llvm.*` intrinsics already are).
- **`scalar_bit_width` / cast machinery**: extend with a `vector_bit_width`
  (16-byte = 128) so `SYSTEM.CAST` between same-width types (e.g. a `REAL32X4`
  and a `REAL64X2` bit-reinterpretation) is a single `bitcast`.

The `new-asm` `AsmType::FQuad/FOct` path already lowers a 4-/8-lane f32 vector to
an XMM/YMM register value; `asm_type_from_type_id` should map `REAL32X4 →
FQuad`, `REAL32X8 → FOct`, unifying the two SIMD entry points.

---

## Codegen (LLVM)

`src/newm2-llvm/src/codegen.rs`:

- **`builtin_type` / type map**: `Vector { lanes, base } → base_llvm.vec_type(lanes)`.
  (`f64_type().vec_type(2)`, `f32_type().vec_type(4)`, `f16_type().vec_type(8)`.)
- **arithmetic**: `FAdd/FSub/FMul/FDiv` on vector operands are already valid
  LLVM — `build_float_add` etc. accept `FloatVectorValue` once operands are
  vector-typed. The existing `coerce_float` gains a vector-splat sibling for the
  scalar-broadcast case.
- **lane access**: `build_extract_element` / `build_insert_element`.
- **construction**: constant lanes → `VectorType::const_vector`; runtime →
  insertelement chain; broadcast → `shufflevector` with a zero mask (splat).
- **alignment**: vector `alloca`s and loads/stores carry `align 16`
  (`build_load`/`build_store` + `set_alignment`), enabling `movaps`/`vmovaps`.
- **reductions/FMA**: emit `llvm.vector.reduce.fadd.*`, `llvm.fma.*`,
  `llvm.sqrt.*`, `llvm.fabs.*`, `llvm.minnum/maxnum.*`.

### CPU features

128-bit float SIMD (SSE2) is **baseline** on x86-64 — no feature gate. 256-bit
(`REAL32X8`) needs AVX; the design defers those behind a target-feature check.
The existing `new-asm` `FOct` already assumes AVX/YMM, so the project's baseline
already includes AVX in practice; the JIT target machine should advertise the
host CPU (see f16 note below).

---

## f16 lanes — the Intel reality

`REAL16X8` (`<8 x half>`) is the *right* home for f16: scalar f16 math is absent
on Intel outside SIMD, but **packed** f16 is well supported via F16C. The lane
model:

- **Storage**: 8×f16 = 16 bytes, the compact interchange/storage format
  (textures, weights, activations).
- **Arithmetic**: lane-wise `<8 x half>` ops lower (without AVX-512-FP16) to a
  **vectorized widen → compute in f32 → narrow** sequence: `vcvtph2ps` on each
  `<4 x half>` half → `<8 x float>`, `fadd/fmul <8 x float>`, `vcvtps2ph` back.
  This is a handful of F16C instructions, not the per-lane soft-float libcall
  that *scalar* f16 needs. So `REAL16X8` arithmetic is fast and accurate on any
  F16C CPU (Ivy Bridge, 2012+).
- **Implementation requirement**: the F16C conversions must actually select
  `vcvtph2ps`/`vcvtps2ph`. The scalar-f16 work in `3b7577f` found that the MCJIT
  target was *not* advertising F16C, so scalar conversions fell back to the
  `__extendhfsf2`/`__truncsfhf2` libcalls (worked around by binding those in
  `src/newm2-llvm/src/lib.rs`). For vectors the **correct** fix is to give the
  JIT/AOT target machine the host CPU + features (`getHostCPUName` /
  `getHostCPUFeatures`, or an explicit `+f16c,+avx`) so packed conversions use
  hardware. The libcall-binding fallback still covers any stragglers. This
  belongs in this design because vector f16 makes the feature-detection issue
  load-bearing rather than incidental.
- **Recommended compute idiom**: keep `REAL16X8` as a *storage* vector and
  expose `VCVT(REAL32X8, h)` / `VCVT(REAL16X8, f)` so programs widen once, run
  the math in `REAL32X8` lanes, and narrow on store — explicit and predictable,
  matching how SIMD f16 is used in practice.

---

## ABI / calling convention

- **M2 ↔ M2** (the common case): pass and return vectors **by value** as LLVM
  `<N x T>`. The JIT and AOT lower both sides consistently, and `new-asm`
  already returns `FQuad`/`FOct` in `xmm0`/`ymm0`, so the convention exists.
- **M2 ↔ C / Win32**: the default Win64 C ABI passes `__m128` **by reference**
  (a hidden pointer); only `__vectorcall` passes vectors in `XMM0–XMM5`. So a
  vector crossing into a C/Win32 callee must either go through a `[…]
  vectorcall` external annotation or be passed by `POINTER TO REAL32X4`. The
  design records this as a constraint on FFI signatures; internal M2 code is
  unaffected.
- **Records/arrays of vectors**: laid out with 16-byte alignment and 16-byte
  stride; passed by reference like other aggregates.

---

## Heap arrays, alignment, and the GC

The headline idiom:

```modula2
TYPE  Buf = POINTER TO ARRAY [0..0] OF REAL32X4;   (* flex-array view *)
VAR   xs, ys, zs : Buf;  i, n : CARDINAL;
...
FOR i := 0 TO n-1 DO
   zs^[i] := xs^[i] * ys^[i] + REAL32X4{bias}   (* one aligned SIMD step *)
END
```

- `nm2_alloc` already returns 16-byte-aligned blocks, so `xs^[i]` is an aligned
  `<4 x float>` load (`movaps`). **No allocator work for 128-bit.** (256-bit
  AVX wants 32-byte alignment — a later allocator note, not needed now.)
- **GC**: a `Vector` contains only floats → no embedded pointers. An
  `ARRAY OF REAL32X4` heap object is a leaf to the collector: its root/layout
  descriptor marks "no pointers", so the GC never scans lane bytes. This must be
  wired in the layout-descriptor emission (the same place arrays of `CARDINAL`
  are marked pointer-free).

---

## Examples

SAXPY (`z = a*x + y`) over `n` vectors of 4 floats — `n` scalar SAXPYs per step:

```modula2
PROCEDURE Saxpy(a: REAL32; VAR x, y, z: ARRAY OF REAL32X4; n: CARDINAL);
VAR i: CARDINAL; av: REAL32X4;
BEGIN
   av := SPLAT(REAL32X4, a);
   FOR i := 0 TO n-1 DO z[i] := FMA(av, x[i], y[i]) END
END Saxpy;
```

Dot product of two length-`4k` vectors:

```modula2
PROCEDURE Dot(VAR a, b: ARRAY OF REAL32X4; n: CARDINAL): REAL32;
VAR i: CARDINAL; acc: REAL32X4;
BEGIN
   acc := REAL32X4{0.0};
   FOR i := 0 TO n-1 DO acc := FMA(a[i], b[i], acc) END;
   RETURN SUM(acc)
END Dot;
```

3×3-ish transform of a packed point (lanes = x,y,z,w):

```modula2
VAR p, row0, row1, row2 : REAL32X4; out : REAL32X4;
...
out := REAL32X4{ DOT(p,row0), DOT(p,row1), DOT(p,row2), p[3] };
```

---

## Phasing

1. **Core type + arithmetic** (`REAL64X2`, `REAL32X4`): `TypeKind::Vector`,
   pervasive names, sizing/alignment, `+ - * /`, scalar broadcast, the `T{…}`
   constructor, `v[i]` lane access, aligned load/store, by-value ABI. A JIT
   regression test (`Mod/tests/`) like `t-90-204` for f32/f16. **This is the
   80%.**
2. **Reductions & FMA**: `SUM`, `DOT`, `FMA`, `SQRT`, `ABS`, lane `MIN/MAX`,
   `SPLAT`, `VCVT`.
3. **`REAL16X8`**: f16 lanes + the host-CPU-feature/`+f16c` target fix so packed
   conversions use F16C; widen/compute/narrow idiom.
4. **`new-asm` unification**: `REAL32X4 ↔ FQuad`, `REAL32X8 ↔ FOct`, so SIMD
   intrinsics can be hand-written in ASM and called with vector types.
5. **256-bit (AVX) + integer lanes**: `REAL32X8`/`REAL64X4` (32-byte align —
   allocator note), `INT32X4`/`INT16X8`; masks, `SELECT`, shuffles/permutes.

---

## Open questions

- **Naming**: named pervasive types (`REAL32X4`) vs. a parameterized
  `VECTOR <n> OF <T>` former. This design recommends **named types first** (zero
  syntax change, matches `REAL32`), with the general `TypeKind::Vector`
  underneath so a `VECTOR n OF T` surface can be added later without rework.
- **Broadcast ergonomics**: should a bare scalar in `v + 1.0` broadcast
  implicitly (recommended, lowest friction) or require `SPLAT`? Recommend
  implicit for literals/same-element scalars, explicit `SPLAT` for differing
  types.
- **Masked / comparison results**: defer to phase 5; likely a `BOOLX4`-style
  mask vector + `SELECT(mask, a, b)`.
- **Alignment of stack arrays of vectors**: an `ARRAY OF REAL32X4` local needs a
  16-aligned `alloca`; confirm the frame layout honors over-aligned locals (LLVM
  does, but verify the stack-realignment prologue is emitted).
- **Denormals / fast-math**: whether SIMD ops opt into `fast`/`reassoc` flags
  (affects `SUM` reduction associativity). Recommend default-strict, with a
  pragma to opt into fast reductions.

---

## Touch-point checklist (for implementation)

- `src/newm2-sema/src/types.rs` — `TypeKind::Vector`; `intern`/`Display`;
  `is_same_family` (distinct).
- `src/newm2-sema/src/analyze.rs` — pervasive `REAL*X*`; `type_size_bytes`;
  `is_numeric_type`; arithmetic typing (vec⊕vec, vec⊕scalar broadcast);
  constructor + lane-index checking; `SPLAT/SUM/FMA/DOT/SQRT/VCVT` builtins;
  assignment/param compatibility.
- `src/newm2-ir/src/lower.rs` — `expr_is_float`/`transfer_class` for vectors;
  `VecExtract`/`VecInsert`/`VecSplat`/`VecConst` ops; reduction/FMA intrinsic
  lowering; `asm_type_from_type_id` → `FQuad`/`FOct`; `vector_bit_width`.
- `src/newm2-llvm/src/codegen.rs` — `builtin_type`/type map → `vec_type`;
  vector arithmetic; extract/insert; splat; `const_vector`; `align 16`
  load/store; vector intrinsic calls; layout descriptor "no pointers".
- `src/newm2-llvm/src/lib.rs` — JIT target machine: host CPU + `+f16c,+avx` for
  packed f16; keep the libcall-binding fallback.
- `new-asm/src/types.rs` — (phase 4) bridge `REAL32X4/REAL32X8` ↔ `FQuad/FOct`.
- `src/newm2-runtime/src/heap.rs` — 128-bit already covered (16-byte align);
  add a 32-byte path only when AVX-256 vectors land.
