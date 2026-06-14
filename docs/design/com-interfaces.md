# COM interfaces in Modula-2: `INTERFACE`, `HRESULT`, and synthesized `QueryInterface`

Status: **design, awaiting sign-off** · Supersedes ad-hoc COM notes · Acceptance test: `ShaderView` (the D3D11 Mandelbrot demo)

## Why — the demo is the teacher

Consuming COM from M2 today means hand-transcribing vtables. `TermRender.mod`'s
`ID2D1RT` is the brief: ~47 hand-written `rN` placeholder slots so that ~5 real
methods land on the right offset, guarded by a *comment*:

```
(* NOTE: ID2D1RenderTarget has Set/GetTextRenderingParams between the antialias
   getters and SetTags — miss them and Clear/BeginDraw/EndDraw shift by 2. *)
ABSTRACT CLASS ID2D1RT;
  ABSTRACT PROCEDURE r0 (): INTEGER; ... ABSTRACT PROCEDURE r7 (): INTEGER;
  ABSTRACT PROCEDURE CreateSolidColorBrush (color, props, brushOut: ADDRESS): INTEGER;  (* 8 *)
  ... 38 more placeholders ...
  ABSTRACT PROCEDURE Clear (color: ADDRESS): INTEGER;     (* 47 *)
  ABSTRACT PROCEDURE BeginDraw (): INTEGER;               (* 48 *)
  ABSTRACT PROCEDURE EndDraw (t1, t2: ADDRESS): INTEGER;  (* 49 *)
END ID2D1RT;
```

The ShaderView D3D11 bring-up would need ~100 more such lines, and the
design-review critic's #1 risk for that demo was literally *"VTABLE SLOT MISCOUNT
is the #1 risk and silent."* Three invariants are leaking out of the type system
into the programmer's head:

1. **Slot ordinals** — hand-counted placeholder padding (`r0..r46`, `c3..c50`).
2. **The +N-shift hazard** — "miss a method and everything after shifts" lives in
   a comment. Silent and lethal.
3. **`HRESULT` semantics** — `hr < 0` for direct DLL calls vs.
   `(hr BAND 80000000H) # 0` for virtual calls, carried by convention. The
   width even differs (`INTEGER32` vs `INTEGER`), so `hr < 0` is not reliably the
   severity-bit test. The ShaderView critic caught a real bug here.

Each is a responsibility the language hands the programmer that it could carry.
This design promotes all three into compiler-checked properties.

## The central principle: the generator is the single source of truth, and the compiler machine-checks it

The language feature **alone** is not enough — it would merely move the
hand-counting from `TermRender.mod` into `winapi-gen`'s output, the same hazard at
a different layer. What makes the +N-shift *structurally impossible* rather than
merely centralized is sourcing the interface declarations — slot order, IID, base
chain — **from Windows metadata** (the same `win32metadata`/winmd that Microsoft
generates their own projections from). There is no count for a human to get wrong
because no human is counting.

But "generated" is not the same as "correct." The adversarial review found the
keystone gap: the compiler computes `Clear = 47` *only if the input lists methods
in IDL order*, and nothing checks that. So the generator's output must be
**machine-checked**, not trusted:

> winapi-gen emits each method's winmd vtable ordinal as a **checked annotation**,
> and sema **asserts `computed_index == declared_ordinal`** for every slot.

```
INTERFACE ID2D1RenderTarget ["2cd90694-12e2-11dc-9fed-001143a055f9"];
  INHERIT ID2D1Resource;
  ...
  PROCEDURE Clear (color: ADDRESS): HRESULT;     (* @47 — checked, not a comment *)
  PROCEDURE BeginDraw (): HRESULT;               (* @48 *)
  PROCEDURE EndDraw (tag1, tag2: ADDRESS): HRESULT;  (* @49 *)
END ID2D1RenderTarget;
```

This is the difference between "we wrote the vtable once, carefully" and "the
build fails if a vtable is wrong by one slot." It is also the structural answer to
the `[propget]`/`[propput]` hazard (below): the assertion is `len(slots) ==
metadata method count`, keyed on the metadata method token, never a demangled
name.

---

## Part A — Consumer side: the `INTERFACE` construct

A COM interface declared as a first-class, fieldless, all-abstract type whose
vtable slot ordinals are **assigned by the compiler** from the declared
inheritance chain.

### Grammar (no lexer change — soft keywords)

`INTERFACE` and `IMPLEMENTS` are soft keywords (`Ident` matched by string), exactly
as `CLASS`/`INHERIT`/`REVEAL`/`OVERRIDE` already are. No `token.rs` change.

```ebnf
InterfaceDecl =
    "INTERFACE" ident [ "*" ] [ IidAnnotation ] ";"
    [ "INHERIT" QualName ";" ]                 (* exactly 0 or 1 base; must be an INTERFACE *)
    { InterfaceMethod }
    "END" ident ";" ;

IidAnnotation  = "[" string "]" ;             (* a GUID literal right after the name *)
InterfaceMethod =
    [ "ABSTRACT" ] "PROCEDURE" ident [ "(" [ FormalParams ] ")" ] [ ":" TypeExpr ]
    [ "(*" "@" number "*)" ]                   (* the CHECKED ordinal, emitted by winapi-gen *)
    { ProcAttr } ";" ;
```

AST: reuse `ClassDecl` with a `kind: ClassKind {Class, Interface}` discriminant
plus `iid: Option<String>` and `implements: Vec<QualName>` — minimal churn, no new
`Decl` variant. An interface is parsed as a specialised class: **reject fields,
reject method bodies, force every method `is_abstract`**.

> **Correction to an earlier draft:** the `[ "..." ]` IID annotation is *net-new*
> parser surface on the class/interface header. It does **not** reuse the ADW
> external-linkage bracket slot, which exists only on procedure headers. It is
> small (parse a string literal between the name and the `;`), but it is new.

### Slot assignment — the algorithm

Reuses `ClassArena::resolve_vtable` (`class.rs:187-223`) verbatim; the only change
is that the base chain now supplies the leading slots instead of hand-written
padding.

```
assign_slots(I):
  if I has no base (the IUnknown root):
      slots(I) := own_methods(I) in declaration order → indices 0, 1, 2, …
  else (I INHERITs B):
      base := assign_slots(B)                  # recurse
      slots(I) := clone(base)                  # base slots keep their indices (strict prefix)
      for m in own_methods(I) in declaration order:
          m.vtable_index := len(slots(I))      # append after all base slots
          slots(I).push(slot_for(m))
```

Invariant by construction: base methods occupy `[0 .. len(base)-1]`, own methods
follow in declaration order. No compiler-inserted slot (no RTTI/destructor) is ever
added — `vtable[0]` is genuinely the first declared method, byte-for-byte the
C++/MIDL layout. Inserting a forgotten method auto-renumbers every later slot
**correctly**, because the index is `len(slots)` at append time. The "+2 shift"
becomes the compiler doing the right thing.

**Invariants the compiler enforces:**
- An `INTERFACE` has **at most one** `INHERIT` base, which must itself be an
  `INTERFACE` rooted (transitively) at `IUnknown`. Reject multi-base or a
  non-interface base (an `ABSTRACT CLASS` base would let fields leak in). COM has
  no interface diamonds at the vtable level, so strict-linear is correct and fits
  ISO 10514-2's single-inheritance / multiple-roots model.
- Reject `OVERRIDE`, fields, and method bodies inside an `INTERFACE`.
- **The `@ordinal` check (keystone):** for every method, assert
  `computed vtable_index == declared @ordinal`; mismatch is a hard error. A method
  name not found at a call site is "no such interface method" (today: silently no
  binding).

### Calling — unchanged mechanic

`find_class_method_binding` already resolves a method *by name* to its flattened
vtable position; because the flattened vtable is base-first/declaration-order, that
position **is** the COM slot. An `ADDRESS` binds to an `INTERFACE`-typed local with
the existing implicit `ADDRESS → class` rule:

```
VAR rt: ID2D1HwndRenderTarget;
rt := gRT;                            (* ADDRESS → INTERFACE, existing mechanic *)
IF FAILED(rt.BeginDraw()) THEN ... END;
... rt.Clear(ADR(cf)) ...            (* slot 47, computed by the compiler, never typed *)
```

Consumer dispatch is verified JIT- **and** AOT-safe: it loads field 0 of a
*foreign* object (the OS DLL's real vtable), so it does not depend on our own
vtable-global materialization (which is AOT-only).

### `HRESULT` as a distinct type

Today `HRESULT` is a transparent alias to `INTEGER32` (`policy.rs:131`), which is
why two success tests coexist. Make `HRESULT` a **distinct** `Builtin::Hresult`
(i32 machine layout — ABI unchanged — but *not* `is_same_family` with INTEGER):

- `SUCCEEDED(h)` ≡ `(h BAND 80000000H) = 0`, `FAILED(h)` ≡ `… # 0` — compiler
  intrinsics, lowering to one AND + compare. `S_OK`, `E_FAIL`, `E_NOINTERFACE`,
  `E_POINTER`, `E_OUTOFMEMORY` emitted as `HRESULT` constants.
- Relational operators (`<`, `>=`, …) on `HRESULT` are a **type error** — this is
  what kills the `hr < 0` footgun. Explicit `VAL`/`CAST` bridges to `INTEGER32`
  for rare bit-twiddling.
- **Unification:** both a virtual `INTERFACE` method returning `HRESULT` and a
  direct external entry point returning `HRESULT` now produce the *same* type, so
  `FAILED(…)` is the single helper for both. The width-mismatch hazard vanishes.

**Migration is atomic** (critic-flagged blast radius): the *same commit* that makes
`HRESULT` distinct must rewrite `TermRender.mod` and `DWrite.mod` call sites to
`SUCCEEDED`/`FAILED` and re-type their locals, or those builds break. The affected
files are exactly the hand-written COM consumers we are rewriting anyway.

### The proof — before/after

`ID2D1RT` retired: the ~47 `rN` placeholders, the "+2 shift" comment, and the
`hr<0` vs `BAND` split all disappear at once. The generated interface declarations
arrive pre-slotted; the consumer writes **zero** placeholders and one `FAILED`
helper. ShaderView's three D3D11 interfaces (which I deliberately did *not* write
in hand-counted form) become imports + calls.

---

## Part B — Producer side: `CLASS … IMPLEMENTS` + synthesized `QueryInterface`

The headline contribution: when the compiler knows each interface's IID and which
a class implements, it emits the `QueryInterface`/`AddRef`/`Release` trio and the
IID→sub-vtable dispatch **itself**. The C++/ATL `BEGIN_COM_MAP` macro-swamp becomes
a compiler product.

### Decision: the tear-off / aggregation model (not multi-vtable)

Grounded in the codegen-feasibility map:

- **Multi-vtable** (classic ATL coclass — N embedded vtable pointers, non-primary
  interface pointers pointing mid-object) needs **three net-new, ABI-fragile**
  codegen capabilities the compiler has *no* analogue for: (1) multiple `__vtable`
  words + shared refcount in one object; (2) a `this`-adjusting thunk per
  (interface, method) doing `ptr→int / sub(offset) / int→ptr`; (3) **guaranteed
  `musttail` with verbatim, ABI-faithful argument forwarding**. The compiler builds
  every call's args arg-by-arg from typed values — there is no "forward the same
  args verbatim" facility and no tail-call emission. Hand re-marshalling would
  silently corrupt the Win64 ABI for exactly FLOAT / by-value-struct / by-ref /
  sret params. High risk.
- **Tear-off** (one interface = one tiny `{__vtable, back}` object, vtable at
  offset 0) needs **zero** new codegen primitives. Every mechanic already exists
  and is exercised: a record with a vtable pointer at field 0, a constant `[N x
  ptr]` vtable global (AOT path), installing it at field 0, the SELF-first Win64
  ABI, and delegation via an ordinary field load + call. Because each interface
  pointer is its own object whose vtable is at offset 0, `this` already equals the
  object the method expects — **no this-adjustment, no thunk, no musttail, no arg
  re-marshalling, ever.** The ABI-fragile cases never arise.

Cost: +16 bytes per exposed interface (eager) or one lazy alloc on first QI.
Identity: correct COM identity holds because `QueryInterface(IID_IUnknown)` is
canonicalised to one fixed primary tear-off and tear-off addresses are stable for
the object's lifetime (non-`IUnknown` interface pointers differing by address is
legal COM). **Tear-off is decisively lower-risk in this compiler and is chosen.**
Multi-vtable is deferred, gated on first landing a `musttail`-emitting `TailCall` IR
node — and only if pointer-stable single-allocation identity ever becomes a hard
external requirement.

### Prerequisite checks the producer side needs (critic blockers)

These do **not** exist today and are prerequisites, not extras:

1. **OVERRIDE signature-equality.** `validate()` currently checks only for
   *unimplemented* abstract methods; it does **not** compare signatures, and
   `resolve_vtable` blindly overwrites the slot sig on OVERRIDE. A coclass whose
   `Clear` override has the wrong parameter list would compile and emit a slot
   whose `call_sig` disagrees with what foreign callers push — silent Win64 ABI
   corruption at the COM boundary. **Add real `ProcSig` structural-equality
   checking** (param modes + types + return) before producer codegen.
2. **IMPLEMENTS completeness.** `CLASS C IMPLEMENTS IFoo` inherits its *own* base,
   not `IFoo`, so `IFoo`'s methods are never injected into `C`'s vtable, and the
   existing "unimplemented abstract slot" check never fires — a class implementing
   *zero* of `IFoo`'s methods passes today's `validate()`. **Add an explicit
   cross-check:** for each implemented interface, walk its flattened vtable and
   require a matching concrete method (name + checked signature) on the coclass.

### Layout, synthesis, GUIDs

- Per implemented interface `I`: a `TearOff_I` record `{__vtable, back}`; the
  coclass carries the shared `__refcount`.
- A **new IR global kind** `Global::ComVtable { symbol, slot_fn_names }` (distinct
  from the existing `ClassDesc` "one `{Class}.vtable`" path — this is net-new
  emission, *not* a verbatim reuse): per interface, a constant vtable with slots
  0/1/2 pinned to the synthesized `QueryInterface`/`AddRef`/`Release` and slots 3..
  to the coclass override bodies, emitted under the exact symbol names the vector
  references and DCE-anchored in `llvm.used` (only foreign callers invoke them).
- **One canonical 16-byte GUID representation** for both the `["…"]` compile-time
  constants and the `riid` parameter; `IsEqualIID` is a fixed 16-byte memcmp
  independent of the M2 surface type the caller used (today consumers pass
  `ARRAY[0..15] OF BYTE`, generated entry points type `riid` as `POINTER TO GUID`).
  This must be resolved *before* synthesis — QI cannot be generated correctly while
  the IID layout is ambiguous.
- Synthesized `QueryInterface`: a compile-time-unrolled IID compare chain returning
  the right tear-off (`IID_IUnknown` → primary), `AddRef` on success, `*ppv := NULL`
  + no AddRef on `E_NOINTERFACE`. `AddRef`/`Release` INC/DEC the shared refcount,
  dispose at zero.

### Producer is AOT-only (for now)

Coclass production is **AOT-only** until JIT vtable patching covers synthesized COM
vtables (JIT class vtables are zero-until-`patch_vtables`). This is an asymmetry
worth stating plainly: **consumer-side `INTERFACE` is JIT- and AOT-safe** (foreign
vtable); **producer-side coclass is AOT-only**.

---

## Part C — winapi-gen as the single source of truth

The generator reads Windows metadata and emits `INTERFACE` declarations so the
whole COM surface arrives pre-slotted. This is what makes the hazard structurally
impossible. Requirements:

- **Real-hierarchy reconstruction.** Emit the base chain from metadata
  (`ID2D1HwndRenderTarget (ID2D1RenderTarget)` → `(ID2D1Resource)` → `(IUnknown)`),
  so inheritance does the slot arithmetic. Never a flattened placeholder run.
- **Checked `@ordinal` annotations + slot-count assertion.** Emit each method's
  winmd vtable ordinal as the checked `(* @N *)` annotation; the compiler asserts
  `computed == declared` and `len(slots) == metadata method count` per interface.
- **`[propget]`/`[propput]` get distinct slots.** `get_Foo`/`put_Foo` each occupy a
  real slot; the emitter keys on the **metadata method token, never a demangled
  name**, so a property pair can never collide and eat a slot (which would
  reproduce the shift-by-N bug). The slot-count assertion guards this.
- **`HRESULT` carried from metadata's marked return** — not degraded to a raw int
  at the boundary.
- **Parameter-direction policy — decided:** the generator emits the **raw ABI
  shape as the canonical, always-present layer** (all-`ADDRESS` / explicit-width).
  That is the non-negotiable escape hatch for anything the projection logic doesn't
  anticipate. Direction metadata (`[in]`/`[out]`/`[retval]`) is *recorded* now but
  an *ergonomic* projection (friendlier signatures) is a **separate, opt-in layer
  generated above the raw one, later — never replacing it.**
- **The ABI-quirk frontier becomes a bounded shim registry.** Metadata is a clean
  oracle for *what* and *where* (slot/IID/order) but not always *how the bytes
  pass* — the handful of low-level D3D/DXGI methods with small-struct-by-value
  returns or calling-convention quirks that even Microsoft's projections
  special-case by hand. These are right about slot order, possibly wrong about
  marshalling. So: ~99% pre-slotted and correct, with a short, **named, committed
  list of "these N methods need a hand-written shim,"** each guarded by a test.
  "Every vtable is a chance to miscount" becomes "six methods are on a list" — a
  bounded, auditable frontier.
- **Server side from the same metadata.** The same contracts (methods, IIDs, base
  chains, directions) that power consumer `INTERFACE` generation give a producer
  `CLASS … IMPLEMENTS IFoo` the exact method set + IID the compiler checks
  completeness against and synthesizes QI from. The producer side is the same
  source of truth read in the other direction.

---

## Staged implementation plan

Consumer first (unblocks ShaderView safely); producer second (the headline).

| Stage | Component | Work |
|------|-----------|------|
| **P0** | sema / winapi-gen | `Builtin::Hresult` (distinct, i32); `SUCCEEDED`/`FAILED` intrinsics; relational-op-on-HRESULT = type error; emit `S_OK`/`E_*`. **Atomically** migrate `TermRender`/`DWrite` call sites. |
| **P1** | lexer / parser | Soft keyword `INTERFACE`; `ClassKind`, `iid`, `implements` on `ClassDecl`; `parse_interface_decl` (reject fields/bodies, force abstract); parse `["…"]` IID and the `@N` ordinal annotation; extend the VAR-section guard. |
| **P2** | sema | Interface = `ClassSymbol{is_abstract, kind=Interface, base, iid}`; reuse `resolve_vtable`; **assert `computed_index == @ordinal`** + `len(slots)==count`; reject OVERRIDE/fields/non-interface base; one-or-zero base. |
| **P3** | ir / codegen | Consumer dispatch is identical to abstract-class dispatch — verify the computed slots match TermRender's hand counts (regression: `Clear=47`, `BeginDraw=48`, `EndDraw=49`). No new IR node. |
| **P4** | sema (opt.) | Round-trip interface `ClassSymbol`s through `ModuleInterface` (`iface.rs`) for the **binary `.sym` cache only**. *Clarification:* source-`.def`-in-graph consumers already recompute identical slots, so P4 is an optimization, **not** on the ShaderView critical path. |
| **P5** | parser / sema | Parse `IMPLEMENTS` list; resolve interfaces; **real OVERRIDE signature-equality check** + **IMPLEMENTS completeness cross-check** (prerequisites). Optional CLSID on the class. |
| **P6** | sema / ir | Tear-off synthesis: `TearOff_I` records, shared `__refcount`, the new `Global::ComVtable` per interface, synthesized QI/AddRef/Release from existing IR ops. |
| **P7** | ir / codegen | 16-byte GUID constants + `IsEqualIID` memcmp; coclass constructor (install vtables, set `back`, refcount:=1); `llvm.used` anchors; heap+refcount lifetime (never GC); AOT-only. Spike: AOT coclass exposing `IUnknown`+one interface, called from a tiny C harness. |
| **P8** | winapi-gen | Confirm `windows_api.db` carries method order + `GuidAttribute` + extends (else extend ingestion); emit `INTERFACE` decls (base + IID + own methods in IDL order + `@N`), IID constants, propget/propput distinct slots, the raw layer + shim registry. |

---

## Open questions (deferred, not blocking the consumer milestone)

- **Refcount thread-safety:** plain INC/DEC (STA-only) vs always-interlocked
  (`InterlockedIncrement`, needs a runtime seam) for MTA/free-threaded safety.
- **True aggregation** (controlling outer `IUnknown` / `pUnkOuter`): tear-off gives
  delegation, not subsumed-inner-IUnknown aggregation. Required anywhere?
- **winmd availability:** does `windows_api.db` already capture interface method
  order, `GuidAttribute`, and the extends chain, or only struct/enum/function? If
  the schema lacks them, P8 also needs the upstream winmd ingestion extended.
- **REVEAL × INTERFACE:** are all interface methods implicitly exported (likely),
  or does an interface participate in REVEAL visibility?

## Explicitly out of scope

- **NIL-safety.** Calling a method on a NIL interface pointer null-derefs (same as
  today's abstract-class dispatch). COM-safety here means *slot/HRESULT/QI*
  correctness, not nil-safety. An optional ISO runtime nil-check before the field-0
  load could be added later under the existing runtime-checks machinery.
