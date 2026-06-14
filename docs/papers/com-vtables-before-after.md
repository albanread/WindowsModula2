# From hand-counted vtables to metadata-checked interfaces: a COM-safety case study in NewModula-2

*A before/after on teaching a young Modula-2 compiler to consume Windows COM
without anyone counting a vtable slot.*

## Abstract

NewModula-2 talks to Windows COM (Direct2D, DirectWrite, Direct3D) the way every
language eventually must: through vtables. The first cut transcribed those vtables
**by hand** — a Modula-2 abstract class mirroring the C++ interface, one
declaration per slot, the real method on the right offset only if you counted the
forty-six placeholders above it correctly. This paper shows what that cost, and
the language + toolchain work that replaced it: a first-class `INTERFACE`
construct whose slots the **compiler** assigns, a `<* @N *>` ordinal the compiler
**machine-checks**, and a generator that emits those interfaces straight from the
Windows metadata. The result, demonstrated on a live Direct2D/DirectWrite terminal
renderer: ~90 lines of hand-counted placeholders deleted, every slot now *verified*
rather than *trusted*, and the +N-shift class of bug rendered **unrepresentable**.

---

## 1. The problem

A COM interface is a pointer to a pointer to an array of function pointers — the
vtable. To call `ID2D1RenderTarget::Clear`, you load the object's vtable pointer
(at offset 0), index **slot 47**, and call it with the object as the first
argument. Slot 47 is not written anywhere you can import; it is implied by the
*order* of every method `ID2D1RenderTarget` and its bases declare. Get the count
wrong by one and you call `DrawGlyphRun` thinking it is `Clear`.

For a young compiler with no COM support, the pragmatic first move is to model an
interface as an **abstract class** whose method declaration order reproduces the
C++ vtable. It works — the memory layout is identical, so the M2 object *is* the
COM object — but it makes the programmer the keeper of three invariants the
language could keep instead.

## 2. Before: the hand-counted vtable

This is the real `ID2D1RenderTarget` binding the renderer shipped with
(`library/winrtmod/TermRender.mod`), abbreviated only where the abbreviation is
itself the point:

```modula2
(* ID2D1HwndRenderTarget vtable (inherits ID2D1RenderTarget). Real signatures
   only on the methods we call; the rest are placeholders holding their slot.
   NOTE: ID2D1RenderTarget has Set/GetTextRenderingParams between the antialias
   getters and SetTags — miss them and Clear/BeginDraw/EndDraw shift by 2. *)
ABSTRACT CLASS ID2D1RT;
  ABSTRACT PROCEDURE r0 (): INTEGER;  ABSTRACT PROCEDURE r1 (): INTEGER;  ABSTRACT PROCEDURE r2 (): INTEGER;
  ABSTRACT PROCEDURE r3 (): INTEGER;  ...  ABSTRACT PROCEDURE r7 (): INTEGER;
  ABSTRACT PROCEDURE CreateSolidColorBrush (color, props, brushOut: ADDRESS): INTEGER;  (* 8 *)
  ABSTRACT PROCEDURE r9 (): INTEGER;  ...  ABSTRACT PROCEDURE r16 (): INTEGER;
  ABSTRACT PROCEDURE FillRectangle (rect, brush: ADDRESS): INTEGER;                     (* 17 *)
  ABSTRACT PROCEDURE r18 (): INTEGER; ...  ABSTRACT PROCEDURE r26 (): INTEGER;
  ABSTRACT PROCEDURE DrawText (...): INTEGER;                                            (* 27 *)
  ABSTRACT PROCEDURE r28 (): INTEGER; ...  ABSTRACT PROCEDURE r46 (): INTEGER;
  ABSTRACT PROCEDURE Clear (color: ADDRESS): INTEGER;                                    (* 47 *)
  ABSTRACT PROCEDURE BeginDraw (): INTEGER;                                              (* 48 *)
  ABSTRACT PROCEDURE EndDraw (t1, t2: ADDRESS): INTEGER;                                 (* 49 *)
END ID2D1RT;
```

Across `TermRender.mod` (`ID2D1Factory`, `ID2D1RT`, `ID2D1Brush`) and `DWrite.mod`
(`IDWriteFactory`) that was **~90 lines of `rN`/`qN`/`bN`/`mN` placeholders** whose
only job was to be counted.

## 3. The three leaking invariants

A design review of a planned Direct3D11 demo flagged the **#1 risk** as, verbatim,
*"VTABLE SLOT MISCOUNT is the #1 risk and silent."* Three responsibilities had
leaked out of the type system and into the programmer's head:

1. **Slot ordinals** — the `r0..r46` padding. The compiler knew nothing of slot 47;
   the human did.
2. **The +N-shift hazard** — *"miss `Set/GetTextRenderingParams` and
   `Clear/BeginDraw/EndDraw` shift by 2."* This invariant lived in a **comment**.
   A correct, lethal, unchecked comment.
3. **`HRESULT` semantics** — direct DLL calls tested `hr < 0`; virtual COM calls
   tested `(hr BAND 80000000H) # 0`. Two success tests for one concept, carried by
   convention, on types of two different widths. The review caught a real bug here.

Each is a property the language *could* check. The work below promotes all three.

## 4. The design: promote invariants into compiler-checked properties

### 4.1 `INTERFACE` — the compiler owns the slots

A COM interface becomes a first-class declaration: a fieldless, all-abstract class
whose vtable slot ordinals the **compiler** assigns by walking the `INHERIT`
chain. It reuses the existing class/vtable machinery (an object's vtable pointer
already sits at field 0 — the COM ABI), so it added almost no codegen.

```modula2
INTERFACE IUnknown ["00000000-0000-0000-C000-000000000046"];
  PROCEDURE QueryInterface (riid, ppv: ADDRESS): HRESULT;   (* compiler: slot 0 *)
  PROCEDURE AddRef  (): CARDINAL32;                         (*           slot 1 *)
  PROCEDURE Release (): CARDINAL32;                         (*           slot 2 *)
END IUnknown;

INTERFACE ID2D1Resource ["2cd90691-..."];      INHERIT IUnknown;        (* +1 -> slot 3 *)
INTERFACE ID2D1RenderTarget ["2cd90694-..."];  INHERIT ID2D1Resource;   (* own methods 4.. *)
```

`rt.Clear(...)` now resolves `Clear` to slot 47 because the compiler counted
`IUnknown(3) + ID2D1Resource(1) + ...` — and inserting a forgotten method
auto-renumbers everything after it, *correctly*, because each slot index is
`len(slots)` at append time. **The +N-shift becomes the compiler doing the right
thing instead of a comment begging the human to.**

### 4.2 `@ordinal` — the build fails if a slot is off

`INTERFACE` makes the slots *computed*; it does not yet make them *checked*. A
generated (or hand-written) method may carry a `<* @N *>` annotation, and sema
**asserts the slot it computes equals N**:

```
PROCEDURE Clear (color: ADDRESS): HRESULT <* @47 *>;   (* computed == 47, or the build fails *)
```

A deliberately-wrong `<* @5 *>` on a method that is really slot 3 produces:

```
error: method 'DoThing' in 'IFoo' is annotated slot @5 but the compiler
       computed slot 3 — the INHERIT chain or method order disagrees
```

This is the keystone: it turns *"we transcribed the vtable carefully"* into
*"the build refuses if a vtable is off by one."*

### 4.3 `HRESULT` — one helper, two call kinds

`SUCCEEDED`/`FAILED` became compiler intrinsics lowering to the severity-bit test
`(h BAND 80000000H) = 0`. The same `FAILED(hr)` now covers a direct DLL call and a
virtual COM call; the `hr < 0` form, on a value that doesn't reliably sign-extend,
is gone.

### 4.4 The generator is the single source of truth

`INTERFACE` alone would only **relocate** the hand-counting — from the consumer
into the binding author. What makes the +N-shift *structurally impossible* is
sourcing the interface declarations from **Windows metadata** (the `.winmd` that
Microsoft generates their own projections from): the slot order, the IID, and the
base chain all come from the one place no human is counting.

## 5. The pipeline

```
Windows.Win32.winmd
      │  WinmdInspect (C#, System.Reflection.Metadata)
      │   • methods in metadata (= vtable) order
      │   • the GuidAttribute  → IID
      │   • InterfaceImpl      → base/extends
      ▼
windows_api.db (SQLite)   interface_methods · interface_method_params · types.iid · types.base_qualified_name
      │  winapi-gen (Rust)
      │   • walks the base chain: @N = Σ(base own-method counts) + own slot_index
      │   • cross-namespace INHERIT (System_Com.IUnknown), IID annotation
      │   • raw-ABI param mapping (pointer → ADDRESS, f32 → SHORTREAL, ...)
      ▼
library/NewM2/Graphics_Direct2D_types.def
      INTERFACE ID2D1RenderTarget* ["2cd90694-..."];
        INHERIT ID2D1Resource;
        PROCEDURE Clear (color: ADDRESS): HRESULT <* @47 *>;
        ...
      │  the M2 compiler
      ▼
   @ordinal machine-check ✓   — a clean compile *is* the proof the chain is right
```

`ID2D1RenderTarget.Clear` arrives at `@47`, `BeginDraw` at `@48`, `EndDraw` at
`@49` — the exact numbers the human used to count — now derived and verified.

## 6. After: the rewrite

`DWrite.mod` and `TermRender.mod`, rewritten to *use* the generated interfaces:

```modula2
(* DWrite.mod *)
FROM Graphics_DirectWrite IMPORT DWriteCreateFactory, IDWriteFactory;

(* TermRender.mod *)
FROM Graphics_Direct2D IMPORT D2D1CreateFactory,
  ID2D1Factory, ID2D1HwndRenderTarget, ID2D1SolidColorBrush;
```

That is the entire interface surface. The `ABSTRACT CLASS ID2D1RT; r0 ... r46 ...
END;` blocks — and the `+2 shift` comment — are **deleted**. Call sites are
unchanged except for the raw-ABI reconciliation (§7).

| | Before | After |
|---|---|---|
| Interface declaration lines (TermRender + DWrite) | ~90 hand-counted placeholders | 4 import names |
| Who assigns slot 47 | the programmer, by counting | the compiler, from metadata |
| The +2-shift invariant | a source comment | unrepresentable |
| `Clear`/`BeginDraw`/`EndDraw` correctness | trusted | machine-checked (`@47/@48/@49`) |
| HRESULT test | `hr<0` here, `BAND` there | `FAILED(hr)` everywhere |
| Net change in the consumers | — | **−56 lines** |

**It renders.** The terminal demo AOT-builds and runs live — factory → render
target → solid-colour brush → text, the full Direct2D/DirectWrite path, now
entirely through generated interfaces. The numbered suite stays 226/0, including
the DWrite and TermRender tests.

## 7. What the exercise exposed

Generating real interfaces and pointing the compiler at them flushed out genuine
bugs the hand-written, single-instance bindings never could — each fixed under a
standing "fix bugs as found" rule:

- **Vtable resolution order** — a derived class declared *alphabetically before*
  its base (e.g. `AsyncIAdviseSink` before `IUnknown`) cloned an *empty* base
  vtable, corrupting every slot offset. Sema now resolves classes base-before-
  derived.
- **Qualified `INHERIT`** — `INHERIT System_Com.IUnknown` needed module-scope
  resolution, not just local lookup.
- **Abstract classes emitted a `{Class}.vtable` global** — dead (an interface is
  never instantiated) *and* harmful: a hand-written `IDWriteFactory` and the
  generated one collided at link. A fully-abstract class now emits no vtable
  global.
- **The COM float ABI** — the raw-ABI mapping sent a by-value `FLOAT` to `REAL`
  (f64); `IDWriteFactory.CreateTextFormat` wants an f32, so it now maps to
  `SHORTREAL`. (Struct fields keep the lossy mapping; an interface ABI must be
  exact.)
- **The cross-index** — a single-namespace regen degraded cross-namespace struct
  fields to `ADDRESS`; the index is now built from the whole database.

The honest residue is a small, **enumerable** frontier the metadata cannot settle:
a handful of methods with small-struct-by-value returns or calling-convention
quirks that even Microsoft's own projections special-case by hand. The contract
turned *"every vtable is a chance to miscount"* into *"these few methods are on a
list."* The raw-ABI layer is always emitted as the escape hatch; an ergonomic
projection (reading `[out]`/`[retval]` directions into friendlier signatures) is a
later layer **above** it, never replacing it.

## 8. Results, and what's next

A young language now expresses COM contracts **more safely than C++ does**: where
C++ trusts the header author's slot order and `BEGIN_COM_MAP` boilerplate, NewM2
derives the order from metadata and *refuses to build* if it is wrong. The
consumer side is complete and proven on a live renderer.

The headline still ahead is the **producer** side — `CLASS … IMPLEMENTS` with a
compiler-synthesized `QueryInterface`/`AddRef`/`Release` (the tear-off model) — at
which point `BEGIN_COM_MAP` itself becomes a compiler product, and M2 can *publish*
COM objects, not only consume them.

---

### Appendix: commit trail

| Commit | Step |
|---|---|
| `f2afcd9` | `SUCCEEDED`/`FAILED` HRESULT intrinsics |
| `a36f52a` | consumer `INTERFACE` (compiler-assigned slots) |
| `19b5de4` | `@ordinal` machine-check |
| `fcb44b0` | winapi-gen emits `INTERFACE` decls from the winmd |
| `b6e01b0` | cross-index from the whole DB |
| `ccedc99` | abstract classes emit no vtable global |
| `ffab54c` | TermRender + DWrite use the generated interfaces |

Design doc: [`docs/design/com-interfaces.md`](../design/com-interfaces.md).
