# GUARD + ISMEMBER — Final Design

**Status: IMPLEMENTED (Phases 0–2, native-class). Date: 2026-06-22.**

Phases 0–2 are built, verified (gates `t-90-280…285`, `t-91-030`; full m2_tests green;
JIT + AOT; live IDE render), and applied (the four `Surface.mod` `KindOf()`+`CAST`
sites are now `GUARD`s). A 4-dimension adversarial review followed; its real findings
are fixed or recorded below.

## Implementation status & adversarial-review follow-ups

**Fixed during review:**
- **typeinfo at `vtable[-1]`** (not the `+1`-shift the draft implied) — keeps method
  dispatch byte-identical for native *and* foreign-COM objects (`+1` crashed `t-90-080`).
- **Method-less concrete classes** now emit a `[typeinfo]`-only vtable, so RTTI on a
  field-only class answers correctly (was always FALSE). Gate `t-90-285`.
- **Interface gate** — GUARD/ISMEMBER on an INTERFACE selector/arm/operand is a compile
  error (no QI lowering yet). Gate `t-91-030`.
- **`Stmt::Guard` added to the closure-capture walker** (`collect_refs_stmt`) and the
  heap-check pass — a non-exhaustive match had silently skipped it (capture miscompile).
- typeinfo linkage is `weak_odr` + post-link promotion to external (RTDyld drops weak
  data globals; abstract COM-mirror classes must coalesce).

**Deferred (recorded, not blocking native-class GUARD/ISMEMBER):**
- **B3 — foreign-COM abstract-class mirror.** A COM interface consumed via an
  `ABSTRACT CLASS` (the `IMalloc` idiom in `t-90-080/229`) is indistinguishable in the
  symbol table from a genuine native abstract base, so the interface gate cannot catch
  it. `GUARD`/`ISMEMBER` on such a (foreign-backed) object reads a foreign vtable's
  `[-1]` slot → UB. **Not a regression** (no shipping code does this; the old unchecked
  `CAST` was UB on misuse too) but a foot-gun. Fix needs a foreign/COM marker on
  `ClassSymbol`, or requiring COM mirrors to be declared `INTERFACE`. Do before Phase 3.
- **B4 — read-only denoter passable as a `VAR` argument.** A pre-existing general
  CONST-param gap (the VAR-arg check doesn't reject read-only actuals). Harmless for
  native arms; **must** be closed before Phase-3 interface arms (their Release soundness
  relies on read-only).
- **B6 — field mutation through a denoter is over-rejected.** `is_const_param_target`
  ignores selectors, so `cc.field := x` inside an arm is wrongly rejected (reading +
  method calls work). Tangled with global CONST-param semantics — decide before changing.
- **D1 — dead-arm / always-true / duplicate-arm lints.** No correctness impact
  (first-match-wins is correct at runtime); parked in Phase 4 by the original design.

---

## 1. Motivation

NewModula-2 has single-inheritance classes with vtable dispatch but **no runtime type
information and no checked downcast**. Every "is this object actually a `T`?" decision is
hand-rolled, and the only way to narrow a `Backend` to a `TextGridBackend` is an
*unchecked* `CAST`, which is a blind pointer reinterpret (`is_pointer_like(Class) =>
CastKind::BitCast`, `lower.rs:5577`/`5679` → LLVM `bitcast`, `codegen.rs:2254`). The
discriminant that "proves" the cast is safe is a hand-maintained virtual method.

The live, shipping instance of this hazard is `library/uimod/Surface.mod`:

```m2
PROCEDURE TermOf (b: Backend): ADDRESS;
  VAR tg: TextGridBackend;
BEGIN
  IF (b # NIL) AND (b.KindOf() = TextGrid) THEN tg := CAST(TextGridBackend, b); RETURN tg.term END;
  RETURN NIL
END TermOf;                                                       (* Surface.mod:211-216 *)
```

```m2
PROCEDURE AsControl (b: Backend): ControlBackend;
BEGIN
  IF (b # NIL) AND (b.KindOf() = NativeControl) THEN RETURN CAST(ControlBackend, b) END;
  RETURN NIL
END AsControl;                                                    (* Surface.mod:327-331 *)
```

`KindOf()` (declared `ABSTRACT PROCEDURE KindOf (): Kind;` at `Surface.def:21`, returning
the manual `Kind = (TextGrid, Raster, Canvas, Indexed, Shader, NativeControl, Custom)`
enum at `Surface.def:12`) is a *parallel, hand-maintained type tag*. Every `Backend`
subclass must override it correctly; if a tag ever drifts from the real class, the
following `CAST` is undefined behaviour and the compiler offers zero protection
(documented in the cast-lowering facts). The same idiom recurs verbatim at
`Surface.mod:214` (`TermOf`), `:224` (`VisibleCells`), `:237` (`CellSize`), and `:329`
(`AsControl`) — four sites, one bug class.

`GUARD` and `ISMEMBER` replace this with a *compiler-synthesized* type test: the narrowing
becomes a `BitCast` that is **dominated by a real RTTI check**, so a drifted tag is
structurally impossible (there is no tag). The same two test primitives also let us
**unify the native-class and COM-interface worlds**: a GUARD arm whose guarded type is a
COM `INTERFACE` lowers to `QueryInterface` by IID. This directly closes the
"GUARD-on-interface frontier" that `docs/design/com-interfaces.md` flagged as blocked on
the bound temp's AddRef/Release lifecycle — we *solve* that lifecycle here rather than
deferring it.

> **The spine of this design is COM unification: GUARD is ONE construct whose arm-lowering
> is selected per-arm by the guarded type's kind.** A native-CLASS arm → an RTTI
> subclass-of test + a zero-cost `BitCast` (no refcount). A COM-INTERFACE arm →
> `QueryInterface(IID, &tmp)`; on success a read-only temp *owns* the AddRef'd reference
> and is Released at every controlled exit edge of the arm. `ISMEMBER` is the boolean of a
> single arm and shares the same two primitives (`nm2_rtti_isa` for classes; a
> non-binding QI-probe-then-Release for interfaces).

---

## 2. Semantics

### 2.1 Selector and static vs dynamic type

`GUARD selector AS … END` evaluates `selector` **exactly once** into a single materialised
value. The selector's *static* type fixes a class hierarchy used only for compile-time
diagnostics (dead-arm warnings, relatedness). The actual arm selection uses the *dynamic*
type: for a native class, the object's runtime RTTI; for an interface arm, whatever
`QueryInterface` reports. The static type is never used to pick the arm.

### 2.2 First-match-wins

Arms are tested top-to-bottom; the first arm whose test succeeds is taken and no later arm
is considered. This is the type analogue of `CASE`'s ordered evaluation. Crucially this is
**load-bearing across the kind boundary**: a native-class arm tests RTTI, an interface arm
tests QI, and an object may satisfy several arms (a coclass that is-a `TextGridBackend`
*and* answers `IFoo`). Only the first matching arm runs.

### 2.3 EMPTY / NIL → ELSE

`EMPTY` is already the pervasive nil constant (nil pseudo-type, `analyze.rs:714`). A
`NIL`/`EMPTY` selector takes the `ELSE` arm. If there is no `ELSE`, a nil selector raises
`guardException` (§2.5). The implementation emits one `sel = NIL` test *before* any arm
test (so we never dereference a null object to read its RTTI). The comparison uses the
same lowering `EMPTY` lowers to, so literal `NIL` and `EMPTY` both route to `ELSE`.

> **NIL-safety scope (inherited from `com-interfaces.md:355-360`).** GUARD/ISMEMBER
> guarantee *NIL-selector → ELSE* only. They provide **no** protection against
> dangling/freed interface pointers or garbage class references — exactly the contract of
> today's method dispatch, which also blindly loads field 0. Do not market the NIL check
> as null-safety.

### 2.4 The arm-bound temp (read-only, arm-scoped)

An arm may bind a denoter: `obj : T DO …`. Inside that arm body `obj` is a fresh local of
type `T` — the *narrowed view* — visible only in that arm body (not other arms, not
`ELSE`, not after `END`). It is **read-only**: assignment to it, or passing it as a `VAR`
/ `OUT` / `INOUT` parameter, is a sema error. (Read-only matters for refcount soundness:
the interface-arm `ScopeRelease` releases exactly the pointer `QueryInterface` produced; if
the user could reassign `obj` the Release would target the wrong reference.)

### 2.5 No-match exception

No-match with no `ELSE` raises **`guardException`**, a **NewM2-proprietary** exception (it
is *not* an ISO exception — see §6.5). It is catchable in an `EXCEPT` handler via the same
machinery as a runtime check, but it lives in its own source-id namespace and never
pollutes `M2EXCEPTION.M2Exceptions`.

### 2.6 Nested GUARD

A GUARD arm body is an ordinary statement sequence and may contain nested GUARDs. The
eval-once selector temp and any interface-arm bound temps form a stack of cleanups; an
`EXIT`/`RETURN` traversing several nested arms must release every interface temp it crosses
(§6.4). Native arms have no cleanup, so nesting native arms is unrestricted.

### 2.7 ISMEMBER

`ISMEMBER(p1, p2): BOOLEAN` is TRUE iff the (dynamic-or-static) type of `p1` is a
subclass-of-or-equal-to `p2`. It is the boolean of one arm and shares the two test
primitives. Each of `p1`, `p2` is independently either a **TYPE** designator or a
**VARIABLE/expression**; sema classifies by *resolved symbol kind* (`SymbolKind::Type` vs
`Var`/`Const`), never by `Expr::Designator` shape (a type name and a variable are both bare
designators). The accepted matrix is pinned in §7.

---

## 3. Grammar

### 3.1 Soft-keyword strategy

`GUARD`, `AS`, and `ISMEMBER` are **soft keywords**: they are *not* added to the lexer
`Keyword` enum (`newm2-lexer/src/token.rs:102-161`). They remain `Ident` tokens, so
existing identifiers spelled `guard`/`as`/`ismember` keep working everywhere they are not
in structural position. This mirrors the existing `eat_soft_kw` discipline
(`parser.rs:1196`) used for `INHERIT`/`REVEAL`/`OVERRIDE`/`UNSAFEGUARDED`/etc.

**GUARD recognition (unambiguous, side-effect-free lookahead).** In `parse_statement`
(`parser.rs:2285`), add an arm **before** the fallback designator/assignment arm:

```text
TokenKind::Ident(n) if n == "GUARD" && self.starts_guard_stmt() => self.parse_guard(),
```

`starts_guard_stmt()` commits to GUARD **only** when `peek(0) == Ident("GUARD")` **and**
`peek(1)` is *not* a designator-continuation/assignment token — i.e. not one of
`:=`, `.`, `[`, `(`, `^`, `,`. This keeps every ordinary statement that merely *starts*
with a variable named `guard` (`guard := x;`, `guard.f := y;`, `guard(args);`,
`guard[i] := z;`) on the assignment/call path. After committing, the parser requires a
soft `AS` after the selector; if `AS` is absent it is a hard parse error (a statement of
the form `GUARD <expr>` with no continuation is never valid M2, so committing here is
safe and needs no backtracking). The `AS` probe, where used as a secondary disambiguator,
is **bounded to the current statement** (stops at `;` or any statement-starting keyword) so
a following identifier `as` on the next line cannot mis-trigger. Speculative parsing, if
any, snapshots the full cursor (`self.pos` + error count) and suppresses diagnostics on the
rejected path.

**ISMEMBER** needs **no grammar change**: it is an ordinary call `ISMEMBER(p1, p2)` that
parses as `Expr::Call`. It is recognised as a **soft pervasive** in sema (callee is the
identifier `ISMEMBER` at a call site) and lowered in IR, exactly like `NEW`/`CAST`/`VAL`.
A user identifier `ismember` in non-call position is unaffected. (Generated COM defs do
contain a method named `IsMember` — `Networking_ActiveDirectory`, `System_Search`,
`UI_Shell` — but those are *selector* calls `x.IsMember(...)`, which never reach the
pervasive path.)

### 3.2 EBNF

Soft-keyword terminals are quoted and matched as identifiers in context; `"|"` is the
existing `TokenKind::Pipe`; `DO`, `END`, `ELSE` are existing hard keywords.

```ebnf
GuardStatement =
    "GUARD" guardSelector "AS"
      GuardArm { "|" GuardArm }
    [ ELSE StatementSequence ]
    END .

GuardArm =
    [ objDenoter ":" ] guardedType DO StatementSequence .

guardSelector = Expression .   (* a CLASS or INTERFACE reference (or POINTER TO such); evaluated ONCE *)
objDenoter    = ident .        (* read-only, arm-scoped narrowed view *)
guardedType   = qualident .    (* a CLASS or INTERFACE type name *)

(* ISMEMBER is not grammar — it is a pervasive call: *)
IsMemberCall  = "ISMEMBER" "(" objectOrType "," objectOrType ")" .
objectOrType  = Expression .   (* a class/interface TYPE name OR an object value *)
```

The arm reads `name : Type DO …`, mirroring `CaseArm`'s `labels : body`. A leading `|`
on the first arm is optional (mirrors `parse_case`, `parser.rs:2424`).

### 3.3 AST changes (`newm2-parser/src/ast.rs`)

Alongside `Stmt::Case` (lines 409-414):

```rust
Stmt::Guard {
    selector: Expr,
    arms: Vec<GuardArm>,
    else_arm: Option<Vec<Stmt>>,
    span: Span,
}

pub struct GuardArm {
    pub denoter: Option<String>,   // objDenoter (None = no binding)
    pub denoter_span: Span,
    pub guarded_type: QualName,    // reuse QualName (as ClassDecl.implements, ast.rs:94)
    pub type_span: Span,
    pub body: Vec<Stmt>,
    pub span: Span,
}
```

No new `Expr` variant for `ISMEMBER` — it is `Expr::Call` with a `Designator{"ISMEMBER"}`
callee and two args, already representable.

`parser.rs` gains `parse_guard()` / `parse_guard_arm()` near `parse_case` (`2418`):
structurally a clone of `parse_case`/`parse_case_arm` but: selector via `parse_expr`;
expect soft `AS` instead of `OF`; each arm = optional `ident ":"` (recorded as a denoter
**only** when an `Ident` is immediately followed by `:`) then a `qualident`, then
`Keyword::Do`, then `parse_stmt_seq`; arms separated by `Pipe`; optional `ELSE`; `END`.

### 3.4 Parser regression tests (mandatory, Phase 2 gate)

`guard := 1;`, `guard.f := 2;`, `guard(3);`, `guard[i] := 4;`, `as := guard;`,
`ismember := TRUE;` must **all** parse as ordinary statements; an identifier `as` in
expression position must parse as `Ident`.

---

## 4. Sema

New pass `analyse_guard` in `newm2-sema/src/analyze.rs`, beside the CASE checker
(`analyze.rs:5374-5437`), plus an `ISMEMBER` arm in `analyse_builtin_call` dispatch
(after FMA, ~`4635`), and `"ISMEMBER"` added to the pervasive registry (`analyze.rs:729`).

### 4.1 Selector type rule

The selector's static type must be `TypeKind::Class { .. }` (native class **or**
interface), or `POINTER TO` such. **Reject** plain `ADDRESS`, records, scalars, and a
literally-`EMPTY`/nil-typed selector (a nil selector can only ever take `ELSE` — it is
dead by construction): error *"GUARD selector must be an object reference"*. This gate is
essential because the native-arm lowering loads RTTI at a fixed object offset; on a
non-object that would be unchecked memory corruption.

### 4.2 Arm type rules (per-arm lowering kind from `ClassSymbol.is_interface`)

Resolve each `guardedType` via the class arena (`class.rs`). The arm's lowering kind is
chosen **strictly** from the resolved `ClassSymbol.is_interface` flag (never a name
heuristic). Let `S` = selector static type, `T` = arm type:

- **Native class `T`, native class selector `S`:** require `is_subclass_or_equal(T, S)`
  (a downcast is the point). If `T` is provably *unrelated* to `S` (neither
  ancestor nor descendant), it is a **compile error** — *"guard type `T` can never be the
  dynamic type of a `S` selector"*. This turns the KindOf-drift bug class into a compile
  error. If `T` is a strict *supertype* of `S`, warn (the arm is statically always-true
  and shadows everything after it).
- **Interface `T`:** if `S` is itself an **INTERFACE** (a foreign COM pointer with a real
  IUnknown-rooted vtable at field 0), accept any interface `T` — `QueryInterface` may
  legally cross to an unrelated interface at runtime.
- **Interface `T` on a NATIVE-class selector `S`:** **compile error** until producer-side
  tear-off QI synthesis lands (`com-interfaces.md:197-280` confirms it is unimplemented).
  A native object's field 0 is the M2 class vtable, **not** `IUnknown`, so a blind field-0
  QI would be a wrong-vtable call, not a clean `E_NOINTERFACE`. Message:
  *"GUARD to an interface requires an interface selector; native coclass → interface
  narrowing is not yet implemented (no QI tear-off)"*.
- **Native class `T` on an INTERFACE selector `S`:** **compile error** — a foreign COM
  object has no M2 `__typeinfo`; reading it would corrupt memory. (Closes the gap where
  native and interface lowerings collide.)

Mixed native-class arms and interface arms in one GUARD are allowed (this is the COM
unification requirement) **as long as the selector is an interface** — only then can an
interface arm be lowered. A native-class arm on an interface selector is rejected per the
rule above, so in practice a *native-class selector* yields all-native arms and an
*interface selector* yields all-interface arms.

### 4.3 Dead-arm / unreachability diagnostics (sound only within the native tree)

First-match-wins makes a later arm dead when an earlier arm subsumes it. Subsumption is
**only** valid within the native single-inheritance tree (the RTTI walk is total there):

- Warn when later native arm `Tj` has an earlier native arm `Ti` with `Ti` a
  supertype-or-equal of `Tj`.
- Warn when a native arm whose type equals the selector's static type appears before any
  other arm (it matches every non-nil object).
- **Emit no cross-kind warning.** A class arm can shadow a still-satisfiable interface arm
  and vice-versa, but QI has no static subsumption to reason about; warning would be
  unsound. Within interfaces, warn only on *exact duplicate* interface types.

No exhaustiveness requirement (open hierarchies); the runtime no-match path handles the
rest. We do **not** optimize a redundant `ELSE` on a closed-within-module hierarchy.

### 4.4 Bound denoter

For `x : T DO …`, introduce `x` into a fresh child scope wrapping **only** that arm body,
type `T`, marked **read-only** with a genuine new attribute (a `read_only` flag on the
`Var` symbol, or a dedicated `SymbolKind::Bound`). The assignment checker (the
`is_readonly_target` consult site, `analyze.rs:5298` region) must reject assignment to it,
and the by-reference-argument check must reject passing it as `VAR`/`OUT`/`INOUT`.

> We do **not** reuse a "FOR control variable read-only" mechanism — verified that
> `is_readonly_target` (`analyze.rs:3681`) recognizes only `Const`/`EnumMember`/read-only
> `WITH` records, and FOR control variables are *not* made read-only. The read-only
> attribute here is new.

### 4.5 ISMEMBER sema

Returns `Builtin::Boolean`. Exactly 2 args. Classify each by *resolved symbol kind*:
`Type`/`Class` → static type arg; `Var`/`Const` → dynamic object arg. Reject scalar/record
args (*"ISMEMBER requires class types or object references"*). For the accepted/rejected
matrix and constant-folding, see §7.

### 4.6 IID validation (at INTERFACE-symbol construction)

When the interface `ClassSymbol` is built, parse its `iid` string to a canonical 16-byte
GUID **immediately** and error on malformed input — *not* at codegen, so a bad IID is a
compile error at the declaration, never a silently-dead arm. See §6.6 for the canonicalizer.

---

## 5. RTTI representation

RTTI is **native-class-only**. Interfaces are **QI-only** and carry no `__typeinfo`; this
invariant isolates the whole RTTI feature from the COM ABI and protects the `@ordinal`
machine-check (`class.rs:265-321`).

### 5.1 Where the descriptor lives — and why NOT in the object record

The chosen representation is a per-class constant global `{Class}.typeinfo`:

```text
TypeInfo = RECORD
  parent : ADDRESS;    (* -> base class {Base}.typeinfo, NIL at a root *)
  name   : ADDRESS;    (* -> interned, NUL-terminated class name (reflection substrate) *)
  depth  : CARDINAL;   (* 0 at root, parent.depth + 1 (ancestor-walk early-out) *)
  (* reserved: fields, methods : ADDRESS — NIL today; future reflection, append-only *)
END;
```

The runtime object reaches its descriptor via **the per-class vtable**, *not* a new object
header word. We put the `{Class}.typeinfo` pointer at **vtable slot −1** (one slot before
slot 0): `{Class}.vtable` becomes `[1 + N x ptr]` where physical element 0 holds the
typeinfo pointer and the symbol `{Class}.vtable` is an alias/GEP-constant pointing at
physical element 1 (the first method). Existing dispatch (`lower.rs:4116-4135`, indexing
from slot 0) is **byte-for-byte unchanged**; the typeinfo lives at `vtable[-1]`.
`lower_class_new` (`lower.rs:5118`) is unchanged — it already stores the (already-offset)
`{Class}.vtable` symbol into object field 0.

> **Why not an object-record field (the rejected alternative).** Adding `__typeinfo` as
> object field 1 shifts every user field by +1 and is a **cross-module ABI flag-day**:
> `resolve_fields` (`class.rs:246`) clones `base.all_fields` into each derived
> `object_record` *at the derived module's compile time*. Any already-compiled consumer
> (including the known-stale committed `library/NewM2` defs) would read field `N` where the
> producer now writes `N+1` → silent memory corruption, with the Phase-0 "259 tests green"
> gate proving only *intra-build* transparency. The vtable is keyed by **class identity,
> not field offset**, so placing the tag there leaves every object-record offset
> byte-identical and **eliminates the entire +1-shift blast radius**. This is the decisive
> reason the vtable placement wins; the only worry against it — slot math vs the `@ordinal`
> COM check — is answered by using slot −1 (a dedicated companion slot below slot 0) and by
> keeping **interface vtables RTTI-free** (their slot 0 stays `IUnknown.QueryInterface`,
> untouched).

### 5.2 Subclass-of-or-equal test

Single inheritance ⇒ a linear ancestor walk:

```text
nm2_rtti_isa(cand: *TypeInfo, target: *TypeInfo) -> bool:
    if cand == NULL: return false               # NIL object is a member of nothing
    while cand != NULL:
        if cand.depth < target.depth: return false   # free early-out
        if cand == target: return true
        cand = cand.parent
    return false
```

Pointer identity is sound because each class has exactly one `{Class}.typeinfo` global
(deduped by symbol name, like `.vtable` at `codegen.rs:495`). The parent-pointer chain is
the **single source of truth** and is dynamic-load-safe; we deliberately **do not** add
interval/display/Cohen O(1) encodings — depth here is 2 (Backend → TextGridBackend), so the
walk is one or two compares, and the extra machinery is premature. `depth` gives a
free early-out and doubles as reflection metadata.

### 5.3 Emission, linkage, and ordering

- Emit `Global::TypeInfo { class_name, parent_name: Option<String>, depth }` for
  **every native class, including abstract bases** (e.g. `Backend`). Interfaces are
  **excluded** (foreign layout; interface arms never read `__typeinfo`).
- Emission runs in a **separate loop** that is *independent of* the abstract-vtable
  suppression at `lower.rs:209` (`if class.vtable all-abstract { continue; }`). That
  `continue` skips abstract `.vtable` globals; it must **not** skip typeinfo, or
  `GUARD x AS a:Backend` and the `TextGridBackend.parent → Backend` chain link would
  dangle and a legitimately-`Backend` object would fail an `AS Backend` arm.
- Linkage: `linkonce_odr` / COMDAT (weak-any) on `{Class}.typeinfo`, so two modules
  emitting the same shared abstract base's typeinfo **coalesce** instead of colliding —
  the exact reason abstract vtables were suppressed, here solved by linkage rather than
  omission.
- **Ordering / forward decls.** Typeinfo emission has a base-before-derived dependency only
  for the *parent symbol reference* (a name), not the parent's *body*: a derived class's
  typeinfo references `{Base}.typeinfo` **by symbol**, resolved by the linker (AOT) or the
  symbol table (JIT). A `FORWARD`-declared class (`body_resolved=false`, `class.rs:48`) that
  appears as a guarded type must still get its typeinfo emitted; emit a typeinfo stub keyed
  on the class id as soon as the name is known, fill `parent`/`depth` when the body
  resolves. The chain link is a name reference, so forward use is safe.

### 5.4 JIT vs AOT

`{Class}.typeinfo` holds **data pointers only** (parent typeinfo + name string). MCJIT
relocates data-pointer constant *initializers* fine — the function-pointer restriction that
forced post-JIT vtable patching (`lib.rs::patch_vtables`) does **not** apply. So typeinfo is
a true constant initializer in **both** JIT and AOT; **no `patch_typeinfo` is needed.**

> **Verified hooks (gaps closed):**
> - The runtime `Store` in `lower_class_new` of `{Class}.vtable` into object field 0 is the
>   existing path and is unchanged; the typeinfo pointer is *not* stored per-object (it
>   lives in the shared vtable), so there is no new runtime Store to verify.
> - Anchor `{Class}.typeinfo` **and** its interned name-string constant in `@llvm.used`
>   (extend the anchoring loop at `codegen.rs:544-560` — add typeinfo + its name string to
>   `anchored`). Typeinfo data globals are not reachable from any call site, so without
>   anchoring DCE could drop them before `nm2_rtti_isa` walks the chain.
> - `nm2_rtti_isa` must be linked in **both** the JIT runtime crate and the
>   `lang_start`-free AOT path used by the demos; verify the symbol is reachable in both.

---

## 6. Lowering

Two new IR instructions in `newm2-ir/src/inst.rs` and one cleanup node. `lower_guard`
mirrors `lower_case` (`lower.rs:2326`): eval the selector **once** into `sel: ValueId`;
pre-allocate one block per arm + `guard_else` + `guard_join`; emit a `sel = NIL` test first
(→ `guard_else`, the EMPTY→ELSE path); then chain arms as an if-else **ladder** (not a
`Switch` — type tests are not dense ordinals), each arm testing its own predicate and
branching to its arm block or the next test. The default executes `ELSE` or raises
`guardException`, exactly like CASE's no-match (`lower.rs:2404-2406`, generalised to take a
looked-up ordinal instead of the hardcoded `2`). `guard_join` merges arm exits.

### 6.1 Native-CLASS arm (RTTI / type-tag check)

```text
Inst::RttiIsA { dst: ValueId(bool), obj: ValueId, type_name: String }
```

Codegen lowers it as: **null-guard first** (`obj = NIL → dst := FALSE`), then load
`obj`'s vtable (object field 0), load `vtable[-1]` → `cand: *TypeInfo`, then
`dst := nm2_rtti_isa(cand, &{Type}.typeinfo)`. The null-guard is *inside* `RttiIsA` so that
**ISMEMBER reuses it null-safely** (§7) without the GUARD-level pre-check. `nm2_rtti_isa`
(the §5.2 walk) is the single source of truth for the ancestor walk.

On TRUE → arm block. If the arm binds `x : T`, materialise `x` as `sel` reinterpreted to
`T`'s object_record — the existing class-to-class `BitCast`
(`is_pointer_like`/`classify_transfer_cast`, `lower.rs:5577`/`5679`; codegen
`codegen.rs:2254`) — **now dominated by `RttiIsA`, so it is a proven-safe zero-cost
reinterpret**, not a blind cast. `x` is read-only; no `Store` to it is emitted. **No
refcount.** Early `RETURN`/`EXIT` inside a native arm is **unrestricted** (this is what
makes `TermOf` and `AsControl`, which both `RETURN` from inside the arm, legal — §8).

### 6.2 COM-INTERFACE arm (QueryInterface by IID) + refcount lifecycle

An interface arm does not use `__typeinfo`. It lowers to a real QI:

1. Reserve a stack temp `ppv: ADDRESS` (`Allocate`), init `NIL`.
2. Materialise the IID: emit a 16-byte GUID constant `{iid}.guid` (`[16 x BYTE]`) from
   `ClassSymbol.iid` via the shared canonicalizer (§6.6); pass `ADR(it)`.
3. Indirect-call `IUnknown::QueryInterface` on `sel` (an interface pointer with a real
   IUnknown-rooted vtable): load `sel`'s vtable (field 0), slot 0 = `QueryInterface`,
   `IndCall(self=sel, ADR(iid), ADR(ppv)) -> hr`, reusing `try_method_dispatch`'s
   machinery (`lower.rs:4102-4155`).
4. `cond := SUCCEEDED(hr) AND (ppv # NIL)` via the existing HRESULT intrinsic
   (`lower_hresult_test_builtin`).
5. On TRUE → arm block. QI implicitly **AddRef'd** `ppv`: `ppv` now owns one reference.

**Refcount lifecycle of the bound temp — the frontier this design closes.** The bound
denoter `x := ppv` (read-only, type `T`) owns exactly one reference and **must be Released
on every controlled exit edge of the arm body**: normal fall-through, and `RETURN`/`EXIT`
leaving the arm. The mechanism is a new narrow node:

```text
Inst::ScopeRelease { obj: ValueId }   (* IF obj # NIL THEN obj.Release() END — vtable slot 2 *)
```

> **The landingpad story is dropped — it is incompatible with this compiler's exception
> model.** Verified (`lower.rs:1698-1754`): EXCEPT/FINALLY is **not** per-frame
> landingpads. A protected region is *outlined* into a separate function run via
> `nm2_run_protected(body_fn, state)` (setjmp/longjmp style); a raise longjmps straight
> back to the wrapper, **skipping every intervening frame**, so there is no cleanup edge
> codegen could hang a Release on. Therefore:

- **Structured exits (fall-through, `RETURN`, `EXIT`) — fully handled now.** `lower_guard`
  routes every controlled exit of an interface arm through an **arm-epilogue block** that
  emits `ScopeRelease(x)` then proceeds to the real `Goto(join)` / `Terminator::Return` /
  loop-exit target. `RETURN`/`EXIT` inside the arm are lowered as `Goto(arm_epilogue)`
  rather than a direct terminator — modelled on the existing `retry_target` / function
  result-slot threading. Nested GUARD arms register their interface temps on a cleanup
  stack so an `EXIT`/`RETURN` crossing several arms emits each `ScopeRelease` in order.
- **Exception propagating *through* an interface arm — NOT exception-safe in v1; release on
  raise is a follow-up.** Because `nm2_run_protected` does not run per-frame cleanups,
  Phase 3 ships with a **sema restriction**: an interface arm body that can reach a
  `RAISE`, or that sits inside an enclosing `EXCEPT`/protected region such that an
  exception could unwind past it, is a compile error *until* a real scope-cleanup runtime
  mechanism exists. The structured-exit path (the common case, including the Surface.mod
  retirements) ships first; the exception-through-arm fix (option: outline each
  interface-arm body as its own protected region whose FINALLY-equivalent Releases then
  re-raises) is a separately-gated follow-up. **We do not claim exception-safe Release
  until `nm2_run_protected` can run per-scope cleanups.**

**Non-binding interface arm.** An interface arm with **no** denoter (a pure boolean test)
lowers to the **non-binding QI-probe** (QI then immediate Release on `ppv # NIL`, §7),
*not* the owning-temp path — it never needs `ScopeRelease`, avoiding a needless owned
reference.

### 6.3 Default / join

Identical to `lower_case`: if `ELSE` present, lower it (→ `join`); else
`raise_m2_exception_guard()` → the runtime entry for `guardException` (§6.5), then
`Unreachable`.

### 6.4 Selector that is itself an AddRef'd interface (gap closed)

If the **selector expression** is a COM call returning an AddRef'd interface (a common COM
idiom), the eval-once selector temp *also* owns a reference that must be Released at GUARD
exit, independently of any arm's bound temp. `lower_guard` therefore tracks the selector
temp on the same cleanup stack: if the selector is a freshly-produced owning interface
value (not a borrowed variable read), register a `ScopeRelease(sel)` that fires on **every**
exit of the whole GUARD (each arm epilogue and the default/join), subject to the same
exception-through restriction as §6.2. A selector that is a plain variable read borrows and
is not released.

### 6.5 guardException raising (NewM2-proprietary source — must-fix designed away)

`guardException` is **not** added to `M2EXCEPTION.M2Exceptions`. Verified
(`library/isodef/M2EXCEPTION.def`): that enum is the ISO 10514-1 **closed** 15-member set
(`indexException=0 … exException=14`), mirrored in `M2EXCEPTION.mod` and
`exceptions.rs::m2exc`. Raising a 16th ordinal through `nm2_raise_m2` would make
`M2Exception()` (which `VAL`s the ordinal into `M2Exceptions`) yield an **out-of-range enum
value (UB)**, corrupt `MIN`/`MAX(M2Exceptions)`, and print a nameless exception. We
therefore use a **separate reserved exception source**, exactly mirroring the existing
`ASSERT_SOURCE`/`M2_SOURCE` sentinels (`exceptions.rs:213-218`):

```rust
/// Reserved exception source for the NewM2 GUARD no-match exception (non-ISO).
pub const GUARD_SOURCE: u64 = u64::MAX - 2;

#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_raise_guard() -> ! {
    install_panic_hook();
    panic::panic_any(ExceptionPayload {
        source: GUARD_SOURCE, number: 0,
        message: b"GUARD selector matched no arm".to_vec(),
    });
}
```

It is catchable via the same `IsCurrentSource(GUARD_SOURCE)` machinery as ASSERT. A
NewM2-proprietary def module (e.g. `M2OOEXCEPTION` / a `NM2GUARD` pseudo-module) exposes a
`guardException` constant and an `IsGuardException()` predicate. The source id and any
ordinal are threaded **symbolically** (looked up, never hardcoded) so the raise site and
the catchable constant cannot drift — unlike `caseSelectException=2`, which is a literal at
`lower.rs:2405`. ISO `M2EXCEPTION` stays **byte-for-byte standard.**

### 6.6 Codegen (`newm2-llvm/src/codegen.rs`) and the shared IID canonicalizer

- **TypeInfo global:** in `declare_globals` beside the `ClassDesc` arm (`codegen.rs:482`),
  declare `{Class}.typeinfo` as a constant struct `{ ptr parent, ptr name, i64 depth }`,
  `parent = get_global("{parent}.typeinfo")` or `null`, `name =` an interned string const,
  `set_constant(true)`, `linkonce_odr`, anchored in `@llvm.used` (with its name string).
- **`Inst::RttiIsA`:** null-guard `obj`, GEP object field 0 → load vtable → GEP `vtable[-1]`
  → load `cand`, then `call nm2_rtti_isa(cand, &{Type}.typeinfo) -> i1`.
- **Class-arm narrowing:** `emit_cast` `BitCast` (`codegen.rs:2254`), unchanged, now
  dominated by `RttiIsA`.
- **Interface arm:** `build_indirect_call` (`codegen.rs:1179`) for QI and for Release
  (vtable slot 2); the IID `[16 x i8]` const; `SUCCEEDED` via the existing HRESULT
  intrinsic.
- **`Inst::ScopeRelease`:** a null-guarded indirect Release call, placed at the arm-epilogue
  exit points only (no landingpad path — §6.2).
- **Shared IID canonicalizer (must-fix designed away):** `ClassSymbol.iid` is a raw String
  (`class.rs:45`), never canonicalised. QI's `riid` is a **mixed-endian** 16-byte GUID
  (first three fields little-endian, last 8 bytes as-written). A naive hex parse silently
  produces bytes QI's memcmp rejects → `E_NOINTERFACE` → the arm *silently never fires*.
  Add **one** tested `iid_str_to_le16(s) -> [u8; 16]` used by the GUARD interface arm,
  interface ISMEMBER, **and** the future producer side, validated at sema time (§4.6) with a
  regression asserting it reproduces the canonical 16 bytes of
  `IID_IUnknown {00000000-0000-0000-C000-000000000046}`.

Runtime (`newm2-runtime`): add `nm2_rtti_isa(cand, target) -> bool` (the §5.2 walk,
null-tolerant) and `nm2_raise_guard()` (§6.5).

---

## 7. ISMEMBER — registration and lowering

Registered at `analyze.rs:729` (soft pervasive), dispatched after FMA (~`4635`), lowered in
a new `lower_ismember_builtin` in the `eval_call` cascade (~`4200`). It computes a target
test for `p2` against a candidate from `p1`. **NIL-safety: any object operand that is
`NIL`/`EMPTY` yields `FALSE`** — the `RttiIsA` null-guard (§6.1) covers `p1`; the `(var,*)`
forms reading `p2`'s descriptor must null-check `p2` *before* loading its vtable (must-fix:
`ISMEMBER(nilBackend, T)` and `ISMEMBER(x, nilVar)` must not segfault — gated by a test).

The accepted matrix (each operand TYPE or VARIABLE; `p2` class or interface):

| `p1` | `p2` | class `p2` | interface `p2` |
|------|------|-----------|----------------|
| **TYPE** | **TYPE** | **compile-time const-fold** (walk static base chain → `Const` bool; e.g. `ISMEMBER(Derived, Base)`) | const-fold iff `p1` statically inherits/implements `p2`; **else error** *"ISMEMBER on two unrelated interface TYPES is undecidable — a type arg has no instance to query"* |
| **VAR** | **TYPE** | `nm2_rtti_isa(p1.__typeinfo, &{T}.typeinfo)` (null `p1` → FALSE) | **non-binding QI-probe:** `QI(p1, IID_T, &ppv); r := SUCCEEDED(hr) AND ppv#NIL; IF ppv#NIL THEN Release(ppv) END` (see warning below) |
| **VAR** | **VAR** | `nm2_rtti_isa(p1.__typeinfo, p2.__typeinfo)` (null either → FALSE) | **error** — *"ISMEMBER cannot test against an interface VARIABLE: COM interface pointers carry no runtime IID; use an interface TYPE name"* |
| **TYPE** | **VAR** | `nm2_rtti_isa(&{T}.typeinfo, p2.__typeinfo)` (null `p2` → FALSE) | **error** (same reason as VAR/VAR-interface) |

Constant folding for `(TYPE, TYPE)` happens in sema (walk the static base chain) → emit a
`Const` bool, no runtime call.

> **Interface-probe Release ordering (must-fix designed away).** Release **iff
> `ppv # NIL`**, *decoupled* from the `SUCCEEDED` test, to balance any AddRef even on a
> surprising `FAILED`-but-non-NIL return; never trust `SUCCEEDED` alone to decide whether an
> AddRef happened.
>
> **Interface ISMEMBER is a non-binding PROBE.** Its truth does **not** make the probed
> pointer usable as the target interface — COM does not guarantee `p1` itself answers `T`'s
> vtable (aggregation/tear-offs return a *different* pointer). Use **GUARD** (which binds
> the QI'd pointer) to actually call target-interface methods. Document loudly; consider a
> sema warning when an interface-ISMEMBER truthy branch calls a `T`-only method on the
> original pointer.

The TYPE-vs-VARIABLE classification is by **resolved symbol kind**, never `Expr::Designator`
shape. The two interface-variable rejections are a documented semantic cliff; each gets a
specific message and a dedicated rejection test so the cliff is enforced, not accidental.

---

## 8. Migration — retiring the Surface.mod KindOf idiom

`Backend` is an `ABSTRACT CLASS`; `TextGridBackend` and `ControlBackend` are subclasses.
After this design the *class-level* discriminant (`KindOf()` returning `TextGrid` /
`NativeControl`) is replaced by compiler `__typeinfo` and the four sites become
compiler-checked GUARDs.

> **Scope caveat (must-fix designed away).** The `Kind` enum is **not** deleted wholesale.
> `KButton`/`KEdit`/`KList`/`KTree`/`KCombo` are a **per-instance field on the single
> `ControlBackend` class** (`Surface.mod:286,295,304,312,320`), *not* subclasses. RTTI
> discriminates **class**, not the intra-class control-kind. We retire only the
> **class-level** tag (`TextGrid`/`NativeControl`); the `Kind` enum's control sub-kind
> members and the `ControlBackend.kind` field **stay**. Re-audit every `KindOf()` call site
> for any that distinguishes control sub-kinds before deleting the abstract method.

**TermOf** (native arm, RETURN-in-arm is legal):

```m2
PROCEDURE TermOf (b: Backend): ADDRESS;
BEGIN
  GUARD b AS
    tg : TextGridBackend DO RETURN tg.term
  ELSE
    RETURN NIL
  END
END TermOf;
```

**AsControl** (returns the narrowed concrete type; callers `SetText`/`GetText` keep using
the wrapper):

```m2
PROCEDURE AsControl (b: Backend): ControlBackend;
BEGIN
  GUARD b AS
    c : ControlBackend DO RETURN c
  ELSE
    RETURN NIL
  END
END AsControl;
```

> **`ISMEMBER` is NOT a drop-in for `AsControl`.** `ISMEMBER(b, ControlBackend)` returns a
> boolean and does **not** narrow; substituting it for `AsControl` would break the
> downstream `c.pending` / field access. The two are not interchangeable.

**VisibleCells** and **CellSize** previously did **nothing** on mismatch (an implicit
do-nothing `IF` else, preset `0,0`). A GUARD with no `ELSE` *raises* `guardException`, so
each MUST gain an explicit (empty) `ELSE`:

```m2
PROCEDURE VisibleCells (b: Backend; VAR cols, rows: CARDINAL);
BEGIN
  cols := 0; rows := 0;
  GUARD b AS
    tg : TextGridBackend DO
      IF (tg.cellW > 0) AND (tg.cellH > 0) THEN
        cols := tg.lastW DIV tg.cellW; rows := tg.lastH DIV tg.cellH
      END
  ELSE
    (* not a TextGrid: leave 0,0 *)
  END
END VisibleCells;
```

`CellSize` retires identically with an empty `ELSE`.

> **Hard migration checklist:** every retired site whose old `IF` had an *implicit
> do-nothing fall-through* (VisibleCells, CellSize) **must** gain an explicit empty `ELSE`;
> every site with an explicit `RETURN NIL` fall-through (TermOf, AsControl) maps to
> `ELSE RETURN NIL`. Make *"no-ELSE raises guardException"* a loud documented language
> rule (mirror CASE).

After retirement: the four unchecked `CAST(...)` downcasts are gone (the bound denoter is
the checked narrowing); the `(b # NIL)` guards are gone (EMPTY→ELSE subsumes them); the
abstract `KindOf()` method and its overrides are deleted; the cross-subclass coupling
(every subclass maintaining a correct `KindOf`) is gone. The KindOf-drift UB is
structurally impossible.

---

## 9. Implementation plan

Each phase is independently testable. New gate files follow the `t-90-NNN-*.mod`
convention; the next free numbers after `t-90-278` are **t-90-279 … t-90-285**.

**Phase 0 — exception + RTTI substrate (S, ~1.5 d).**
`GUARD_SOURCE` + `nm2_raise_guard()` (`exceptions.rs`); the NewM2 `guardException` def
module + symbolic ordinal threading; generalise `raise_m2_exception` to take a looked-up
ordinal. `Global::TypeInfo` (`ir/module.rs`); the separate all-native-classes emission loop
(incl. abstract bases, `linkonce_odr`, independent of `lower.rs:209`); codegen
declare/anchor (`codegen.rs:482`, `@llvm.used` incl. name strings); vtable widening with the
`vtable[-1]` typeinfo slot + `{Class}.vtable`-aliases-element-1; `nm2_rtti_isa` (runtime,
null-tolerant, depth early-out); the shared `iid_str_to_le16` canonicalizer + IUnknown
regression. **Gate `t-90-279`:** a 3-level abstract chain `Root(abstract) → Mid(abstract)
→ Leaf` with `nm2_rtti_isa` returning the correct subclass relations incl. abstract bases;
existing 259 m2_tests still green (proves no object-record/dispatch perturbation — the
tag is in the vtable, offsets unchanged).

**Phase 1 — ISMEMBER pervasive, native + const-fold (S, ~1 d).**
Registry (`analyze.rs:729`) + sema dispatch (~`4635`, classify by symbol kind) +
`lower_ismember_builtin` (~`4200`) for `(var,type)`, `(type,type)` fold, `(var,var)`,
`(type,var)` via `RttiIsA`; `Inst::RttiIsA` in `inst.rs` + codegen with the inline
null-guard. **Gate `t-90-280`:** ISMEMBER over `Backend`/`TextGridBackend`/`ControlBackend`
all four native combos **including `ISMEMBER(nilBackend, TextGridBackend) = FALSE`** and a
`(type,type)` const-fold.

**Phase 2 — GUARD native-class only (M, ~2 d).**
Soft-keyword `parse_guard`/`parse_guard_arm` + `starts_guard_stmt` (`parser.rs:2418`
neighbourhood) + `Stmt::Guard`/`GuardArm` AST; the §3.4 parser regression tests;
`analyse_guard` (selector gate §4.1, per-arm kind §4.2 native subset, read-only bound temp
§4.4, dead-arm warnings §4.3, eval-once); `lower_guard` if-ladder (EMPTY/NIL→ELSE,
`RttiIsA` + dominated `BitCast` narrowing, no-match→`guardException`). **Retire the four
Surface.mod sites** (TermOf/AsControl `ELSE RETURN NIL`; VisibleCells/CellSize empty
`ELSE`); delete the abstract `KindOf()` + overrides; **keep** the `Kind` control sub-kind
members + `ControlBackend.kind`. **Gates:** `t-90-281` (native GUARD: nested GUARD,
eval-once side-effect, no-ELSE-raises-guardException, read-only-binder rejection,
RETURN-inside-native-arm), `t-90-282` (GUARD over the abstract 3-level chain with
`AS Root`/`AS Mid` arms). Surface consumers build + the FastPanesM2 render-harness PNG is
unchanged.

**Phase 3 — COM-interface arm + structured-exit lifecycle (L, ~3 d, highest risk).**
Interface-arm QI-by-IID lowering (reuse `try_method_dispatch` + `SUCCEEDED`); `{iid}.guid`
via the shared canonicalizer; `Inst::ScopeRelease` + the **arm-epilogue routing** for
fall-through/`RETURN`/`EXIT` (and the nested-arm cleanup stack); selector-temp release
(§6.4); the **sema restriction** barring an interface arm reachable by `RAISE`/enclosing
EXCEPT (until per-scope cleanup exists); interface arms allowed only on interface
selectors (§4.2); non-binding interface ISMEMBER (§7). **Gate `t-90-283`:** a
refcount-instrumented test (a counted IUnknown stub) proving AddRef/Release balance across
`{match+fallthrough, match+RETURN-in-arm, match+EXIT-from-loop-in-arm, no-match,
nested-GUARD-RETURN}`; **`t-90-284`:** consume a synthetic foreign-COM object via GUARD
(modelled on `t-90-248`) + the interface-variable-target ISMEMBER rejections.

**Phase 4 — polish + docs (S, ~0.5 d).**
Exhaustiveness/unreachable-arm diagnostic tuning; EMPTY-selector folding; close the
`com-interfaces.md` "GUARD-on-interface frontier"; conformance-suite gates. **Gate
`t-90-285`:** the soft-keyword regression suite (`guard`/`as`/`ismember` as identifiers).

Total ~7–8 working days. Phases 0–2 deliver the Surface.mod retirement and the conformance
value; Phase 3 delivers the COM-unification headline and carries the real risk; the
exception-through-interface-arm release is an explicitly-gated follow-up beyond Phase 3.

---

## 10. Risks & open questions

1. **vtable[-1] negative-offset alias.** Aliasing `{Class}.vtable` to element 1 of an
   `[1+N x ptr]` array must be exactly right under MCJIT or every dispatch breaks. Fallback
   if the alias proves fragile: shift dispatch indices by +1 and store typeinfo at element
   0 — but then the `@ordinal` machine-check (`class.rs:265-321`) must compare against the
   *logical* ordinal (the +1 must be invisible to it). Decide in Phase 0 and test against
   `t-90-248`. **Interface vtables stay unshifted** regardless (IUnknown QI @0).
2. **Exception-through-interface-arm leak.** v1 bars it by sema rule; the real fix
   (outline each interface-arm body as a protected region that Releases then re-raises)
   depends on `nm2_run_protected` gaining per-scope cleanups — a separate project. Until
   then, a GUARD-on-interface inside an `EXCEPT` is a compile error, not a silent leak.
3. **Producer-side COM is unimplemented.** Interface arms work only for *consuming* foreign
   COM objects (interface selector). Narrowing a native M2 coclass to an implemented
   interface is a sema error until tear-off QI synthesis lands (`com-interfaces.md`).
4. **Aggregation / tear-off identity.** A QI'd pointer is not the selector's pointer; forbid
   identity comparison of the bound temp against the selector and document that
   re-entering GUARD for the same interface may yield a different pointer.
5. **Reflection creep.** `name`/`depth`/reserved field/method slots make `TypeInfo` a
   reflection substrate; keep the reserved slots `NIL` and do **not** implement reflection
   in this work.
6. **Open question — closed-hierarchy exhaustiveness.** Single-inheritance hierarchies
   within one module are closed-knowable; we currently neither warn nor optimize a
   redundant `ELSE`/raise on a fully-covered guard. Worth a future lint.
7. **Open question — `guardException` module home.** `M2OOEXCEPTION` (ISO 10514-3 OO
   exceptions) vs a dedicated `NM2GUARD` pseudo-module. Either is fine since it is a
   distinct source id; pick the one that best fits future OO-exception work.

---

## 11. Appendix — TRACED / objects-only GC: an honest answer

**Question:** "Given we already have a heap and a GC, could GC apply to objects only, with
no impact on anything else?"

**Short answer: not for free, and the cost is not the collector.** A tracing collector
restricted to class objects is conceptually clean — objects already begin with a vtable
pointer (field 0), and §5 now gives every native object a reachable `{Class}.typeinfo`
carrying a field map (the reserved `fields` slot), so a *per-object* trace ("which of my
fields are object references?") is straightforward. The mark/sweep (or mark/compact) loop
itself is the **easy** part: walk the worklist, follow object-typed fields via the typeinfo
field map, mark, sweep the free list. We could even reuse the existing heap allocator's
metadata.

**Where the real cost lands: precise root identification.** A *precise* collector must
enumerate **every live object reference reachable from the roots** — globals, the current
locals/parameters of every active call frame, and object-typed fields of non-object
aggregates (a record or array holding a class reference). That demands:

- **Stack maps** for every call site: at any GC-safepoint the collector must know which
  stack slots and registers currently hold object references. LLVM's `gc.statepoint`/
  stack-map machinery exists but would have to be threaded through `newm2-llvm` codegen,
  and every call would become a potential safepoint — a pervasive codegen change.
- **Global root registration:** every object-typed global (and object-typed field within a
  global record/array) must be discoverable — exactly the "safeguarded module" root-set
  machinery: a compiler-emitted table of root locations per module, populated as modules
  initialise.
- **Field-precise tracing of mixed aggregates:** a `RECORD` or `ARRAY` containing class
  references needs its own layout descriptor so the collector can find the embedded
  references — i.e. the typeinfo field map generalised to *all* aggregate types, not just
  objects.

That is the same root-precision burden a full GC carries; "objects only" shrinks the
*heap* the collector manages but **not** the root-set machinery, which is where the
engineering, the ABI risk, and the conformance exposure actually concentrate. A
*conservative* collector (scan the stack as untyped words, treat anything that looks like a
heap pointer as a root) avoids stack maps but introduces false retention and is unsound to
combine with a compacting/moving heap — a poor fit for a systems language that also does
manual `NEW`/`DISPOSE` and `CAST`s pointers to integers.

**Recommendation: defer.** It does not pull its weight against the manual-`NEW`/`DISPOSE`
model plus the already-shipped `--protect-heap` guard and the static heapcheck pass, which
together catch the leaks/double-frees GC would prevent. If ever pursued, the
**smallest-viable sketch** is:

1. **Non-moving mark/sweep, objects-only heap**, allocated from a segregated arena so the
   collector never has to reason about non-object allocations.
2. **Precise field tracing** via the typeinfo `fields` slot (already reserved in §5) —
   implement the object field map first; defer mixed-aggregate tracing by *pinning* (never
   collecting an object reachable only through a non-object aggregate, tracked via an
   explicit write-barrier-free "rooted from raw memory" set).
3. **Cooperative safepoints at allocation only** (collect synchronously inside `NEW` when
   the arena is full), so no stack maps are needed yet — the collector scans only the
   global root table plus a shadow stack of object handles that the codegen pushes/pops
   around object-typed locals. The shadow stack is the cheap stand-in for full stack maps
   and is the single new piece of "safeguarded module" machinery to build.
4. Keep `DISPOSE` working as an explicit hint (immediate free) so the feature is opt-in and
   coexists with manual management.

Even this minimal version is a multi-week effort dominated entirely by step 3 (root
precision), confirming the thesis: **the collector is easy; precise roots are the cost.**
