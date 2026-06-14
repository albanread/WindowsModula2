# COM server support — design notes (for later)

Status: **not yet implemented.** The *consume* side is proven
(`t-90-080-com-malloc`: an M2 abstract class calls a real OS `IMalloc` via
virtual dispatch). The *server* (implement) side is the mirror and is ~90%
already present in the OO machinery.

## Why it's close

When you `NEW` a concrete class, `object[0]` already points at our `{Class}.vtable`
global, which is patched post-JIT with the method addresses. That object pointer
is, bit-for-bit, a usable COM interface pointer: the OS reads `object[0]`, indexes
a slot, and calls it with `this` as argument 0 — which lands as our method's
`SELF`. Same ABI we already exercise (x64 has a single calling convention, so our
methods are COM-callable as-is). So a concrete class that `INHERIT`s an interface
and `OVERRIDE`s its methods, once `NEW`'d, *is* a working COM object.

## Language-level expression (recommendation)

**Keep the language minimal — no `COM CLASS` keyword.** A COM server is just a
concrete class that `INHERIT`s the abstract interface class and `OVERRIDE`s its
methods (the donor pattern already in `library/comlibmod/ClassFactory.mod`). This
compiles and runs today against `SELF` / `EMPTY` / `DESTROY` / override / the
`NM2RT.GuidEq` helper. Handing the pointer to the OS is `SYSTEM.CAST(ADDRESS, obj)`.

Draw the three lines as:

1. **Language**: inheritance + `OVERRIDE` is the whole mechanism. Done.
2. **Library** (the ergonomic layer, *to build*):
   - Interface declarations: abstract classes, methods in vtable order. The Win32
     def-gen already emits these + `IID_*` constants — largely free.
   - A reusable **`IUnknownImpl` base class** (≈ ATL `CComObject`): a `refCount`
     field, concrete `AddRef`/`Release` (`Release` → `DESTROY(SELF)` at zero), and
     a `QueryInterface` that walks a small per-class IID→slot table. A server
     `INHERIT`s this and overrides only its *real* methods — IUnknown boilerplate
     disappears from each class.
3. **Runtime** (via `windows-sys`, like the consume glue, *to build*):
   `CoRegisterClassObject` / `DllGetClassObject`, `InterlockedIncrement/Decrement`
   for thread-safe ref counts.

**Optional compiler sugar (only if boilerplate hurts):** a class pragma
associating an IID (`<*IID:"{…}"*>`) so a generated `QueryInterface` can match
without hand-written constants. Hold off — explicit IID constants fit M2 better
and the def-gen already produces them.

## Limitations to decide on

- **Single inheritance → one interface *chain*.** `IFoo : IClassFactory : IUnknown`
  (linear) works. Two *unrelated* interfaces (`IFoo` + `IBar`) need COM's
  nested/tear-off pattern: a secondary object whose `QueryInterface` delegates and
  hands back a different pointer. Expressible manually today; making it ergonomic
  is a separate decision.
- **x64-only** is fine (single calling convention). x86 stdcall/thiscall would
  need work; not a target.

## Suggested first deliverable

Skip the registration-heavy in-proc-DLL path. Do a **callback/sink interface**:
implement an interface and pass `CAST(ADDRESS, obj)` to an OS API that calls it
back (an enumerator sink, an event sink, a local-server `IClassFactory`). Needs
zero registration plumbing — `IUnknownImpl` + one real method — and proves the
server direction the way `t-90-080` proved consume.
