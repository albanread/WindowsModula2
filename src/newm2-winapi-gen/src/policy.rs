//! The Windows -> Modula-2 type-mapping policy.
//!
//! Two layers:
//!   1. A fixed primitive map (winmd `u32`/`i32`/`char`/... -> NewM2 builtins).
//!   2. A curated WIN32 base typedef set (HANDLE/BOOL/HWND/LPARAM/... -> a
//!      builtin or pointer), which both *defines* the `WIN32` base module and
//!      *recognizes* those names when they appear in signatures. A leaf module
//!      imports the WIN32 names it uses; it never redefines them.
//!
//! Spelling is the ABI-alias style (DWORD/WORD/BYTE/...) for ADW parity, since
//! NewM2 already has those as builtins.

use std::collections::{BTreeSet, HashMap, HashSet};

use newm2_parser::ast::TypeExpr;

use crate::build;

/// A resolved Modula-2 type reference.
#[derive(Debug, Clone)]
pub enum M2Ref {
    /// A NewM2 builtin / pervasive type (DWORD, INTEGER32, ADDRESS, ...).
    Builtin(String),
    /// A name owned by the generated `WIN32` base module (needs an import).
    Win32(String),
    /// A type declared in the current leaf module (a sibling struct).
    Local(String),
    /// A type owned by another generated module — rendered `Module.Name`
    /// (qualified, to dodge cross-module name collisions) with a plain
    /// `IMPORT Module;`.
    CrossNs(String, String),
    /// `POINTER TO <inner>`.
    Pointer(Box<M2Ref>),
    /// Opaque fallback — rendered as `ADDRESS`.
    Address,
}

impl M2Ref {
    pub fn to_type_expr(&self) -> TypeExpr {
        match self {
            M2Ref::Builtin(n) | M2Ref::Win32(n) | M2Ref::Local(n) => build::named(n),
            M2Ref::CrossNs(module, name) => TypeExpr::Named(newm2_parser::ast::QualName {
                segments: vec![module.clone(), name.clone()],
                span: build::sp(),
            }),
            M2Ref::Pointer(inner) => build::pointer(inner.to_type_expr()),
            M2Ref::Address => build::named("ADDRESS"),
        }
    }

    /// Collect the imports this reference needs: WIN32 base names (for
    /// `FROM WIN32 IMPORT`) and cross-namespace module names (for `IMPORT`).
    pub fn collect_imports(&self, win32: &mut BTreeSet<String>, modules: &mut BTreeSet<String>) {
        match self {
            M2Ref::Win32(n) => {
                win32.insert(n.clone());
            }
            M2Ref::CrossNs(module, _) => {
                modules.insert(module.clone());
            }
            M2Ref::Pointer(inner) => inner.collect_imports(win32, modules),
            _ => {}
        }
    }
}

/// A global index of what each generated module actually *emits*, keyed by the
/// winmd qualified name. Built once over all namespaces being generated so a
/// cross-namespace reference resolves to the right form:
///   - a struct -> a qualified `Module.Name` reference (the struct is a type);
///   - an enum  -> its backing scalar (enums lower to CONSTs, not a type, and
///                 are value-sized, never an 8-byte ADDRESS);
///   - anything else (delegate, alias, interface) -> ADDRESS.
#[derive(Default)]
pub struct CrossIndex {
    /// qualified_name -> (module, simple_name)
    pub structs: HashMap<String, (String, String)>,
    /// qualified_name -> backing M2 builtin
    pub enums: HashMap<String, String>,
}

/// Context the resolver needs to recognise sibling types in the current module.
pub struct ResolveCtx {
    /// Simple names of structs emitted as types in the current module.
    pub local_structs: HashSet<String>,
    /// Simple enum name -> its backing M2 builtin (enums are emitted as CONST,
    /// so an enum-typed field resolves to the backing scalar).
    pub enum_backing: HashMap<String, String>,
}

impl Default for ResolveCtx {
    fn default() -> Self {
        Self { local_structs: HashSet::new(), enum_backing: HashMap::new() }
    }
}

/// Map a winmd primitive name to a NewM2 builtin. Returns None for non-primitives.
fn primitive(name: &str) -> Option<&'static str> {
    Some(match name {
        "bool" => "BOOLEAN",
        "char" => "CHAR",
        "i8" => "INTEGER8",
        "u8" => "BYTE",
        "i16" => "INTEGER16",
        "u16" => "WORD",
        "i32" => "INTEGER32",
        "u32" => "DWORD",
        "i64" => "INTEGER64",
        "u64" => "QWORD",
        "f32" => "REAL", // NOTE: NewM2 REAL is 64-bit; f32 ABI is lossy (warned).
        "f64" => "LONGREAL",
        "isize" => "ADRINT",
        "usize" => "ADRCARD",
        _ => return None,
    })
}

/// The WIN32 base module's typedefs: name -> its definition. This is the single
/// source of truth for both emitting the base and recognising the names.
pub fn win32_base_defs() -> Vec<(&'static str, M2Ref)> {
    fn b(n: &str) -> M2Ref {
        M2Ref::Builtin(n.to_string())
    }
    fn p(n: &str) -> M2Ref {
        M2Ref::Pointer(Box::new(M2Ref::Builtin(n.to_string())))
    }
    vec![
        ("HANDLE", b("ADDRESS")),
        ("BOOL", b("INTEGER32")),
        ("BOOLEAN", b("BYTE")),
        ("HRESULT", b("INTEGER32")),
        ("NTSTATUS", b("INTEGER32")),
        ("LPARAM", b("ADRINT")),
        ("WPARAM", b("ADRCARD")),
        ("LRESULT", b("ADRINT")),
        ("PVOID", b("ADDRESS")),
        ("LPVOID", b("ADDRESS")),
        ("WCHAR", b("CHAR")),
        ("PWSTR", p("CHAR")),
        ("PCWSTR", p("CHAR")),
        ("PSTR", p("ACHAR")),
        ("PCSTR", p("ACHAR")),
        ("HWND", b("ADDRESS")),
        ("HDC", b("ADDRESS")),
        ("HMODULE", b("ADDRESS")),
        ("HINSTANCE", b("ADDRESS")),
        ("HMENU", b("ADDRESS")),
        ("HICON", b("ADDRESS")),
        ("HBRUSH", b("ADDRESS")),
        ("HCURSOR", b("ADDRESS")),
        ("HBITMAP", b("ADDRESS")),
        ("HFONT", b("ADDRESS")),
        ("HGDIOBJ", b("ADDRESS")),
        ("HKEY", b("ADDRESS")),
        ("HGLOBAL", b("ADDRESS")),
        ("HLOCAL", b("ADDRESS")),
        ("HPEN", b("ADDRESS")),
        ("HRGN", b("ADDRESS")),
        ("HPALETTE", b("ADDRESS")),
        ("HFILE", b("ADDRESS")),
    ]
}

/// The set of names the WIN32 base module owns (incl. GUID, which is emitted as
/// a record separately).
pub fn win32_names() -> HashSet<String> {
    let mut s: HashSet<String> = win32_base_defs().into_iter().map(|(n, _)| n.to_string()).collect();
    s.insert("GUID".to_string());
    s
}

/// Resolve a winmd signature type-name string to an `M2Ref`, plus warnings.
/// `available` is the set of module names being generated together (so a
/// cross-namespace reference can resolve to `Module.Type` instead of ADDRESS);
/// `current` is the module being emitted (to avoid self-qualified references).
pub fn resolve(
    raw: &str,
    ctx: &ResolveCtx,
    index: &CrossIndex,
    current: &str,
    warnings: &mut Vec<String>,
) -> M2Ref {
    let mut s = raw.trim();
    let mut ptr_levels = 0;
    while let Some(rest) = s.strip_suffix('*') {
        ptr_levels += 1;
        s = rest.trim_end();
    }

    // A bare `void` outside a pointer has no M2 form; under a pointer it is
    // ADDRESS. Either way collapse to ADDRESS.
    if s == "void" {
        return M2Ref::Address;
    }

    // Array/fixed-buffer types (`T[]`, `T[,]`) carry no size in the signature
    // string and the `[` is not a legal identifier char — fall back to ADDRESS.
    if s.contains('[') {
        warnings.push(format!("array type '{s}' -> ADDRESS (size unknown)"));
        return M2Ref::Address;
    }

    let base = resolve_base(s, ctx, index, current, warnings);

    let mut r = base;
    for _ in 0..ptr_levels {
        r = match r {
            // POINTER TO an opaque/ADDRESS is just ADDRESS again.
            M2Ref::Address => M2Ref::Address,
            other => M2Ref::Pointer(Box::new(other)),
        };
    }
    r
}

fn resolve_base(
    s: &str,
    ctx: &ResolveCtx,
    index: &CrossIndex,
    current: &str,
    warnings: &mut Vec<String>,
) -> M2Ref {
    if let Some(b) = primitive(s) {
        if s == "f32" {
            warnings.push("f32 mapped to REAL (64-bit) — ABI width differs".to_string());
        }
        return M2Ref::Builtin(b.to_string());
    }

    let simple = s.rsplit('.').next().unwrap_or(s);

    if simple == "Guid" || simple == "GUID" {
        return M2Ref::Win32("GUID".to_string());
    }
    if win32_names().contains(simple) {
        return M2Ref::Win32(simple.to_string());
    }
    if let Some(backing) = ctx.enum_backing.get(simple) {
        return M2Ref::Builtin(backing.clone());
    }
    if ctx.local_structs.contains(simple) {
        return M2Ref::Local(simple.to_string());
    }

    // Cross-namespace: only resolve to a qualified reference for types another
    // generated module actually emits as a *type* (a struct). Cross-namespace
    // enums become their backing scalar; everything else (delegate, alias,
    // interface) falls back to ADDRESS.
    if let Some((module, name)) = index.structs.get(s) {
        return if module == current {
            M2Ref::Local(name.clone())
        } else {
            M2Ref::CrossNs(module.clone(), name.clone())
        };
    }
    if let Some(backing) = index.enums.get(s) {
        return M2Ref::Builtin(backing.clone());
    }

    warnings.push(format!("unresolved type '{s}' -> ADDRESS (opaque)"));
    M2Ref::Address
}

/// Map a COM interface method's param/return `type_name` to its RAW-ABI M2 type.
///
/// This is the low-level vtable convention proven by the hand-written
/// TermRender/DWrite bindings: every pointer argument (an interface pointer, a
/// struct pointer, or an out-param) is passed as a bare `ADDRESS`; only a
/// by-value scalar keeps its precise M2 type.
///
///   * `T*` (any pointer)            -> `ADDRESS`
///   * a by-value scalar / enum / HRESULT -> resolved via `resolve_base`
///     (so a FLOAT stays REAL, an enum lowers to its backing int, HRESULT ->
///     the WIN32 HRESULT alias).
///
/// A by-value interface (a bare interface name, no `*`) is itself a COM pointer
/// at the ABI; `resolve_base` maps it to ADDRESS via its opaque fallback, which
/// is exactly right (warns as "opaque"). A by-value struct return is the only
/// awkward case — it falls through `resolve_base` to a real type/ADDRESS and is
/// flagged in `warnings`.
pub fn resolve_iface_type(
    raw: &str,
    ctx: &ResolveCtx,
    index: &CrossIndex,
    current: &str,
    warnings: &mut Vec<String>,
) -> M2Ref {
    let s = raw.trim();
    if s.ends_with('*') {
        // Any pointer depth collapses to a single raw machine address.
        return M2Ref::Address;
    }
    if s == "void" {
        return M2Ref::Address;
    }
    // COM by-value float args are EXACT width: a FLOAT is 32-bit. Map to
    // SHORTREAL (a real f32), NOT REAL (f64) — passing an f64 where the vtable
    // expects an f32 corrupts the virtual call. Struct fields tolerate the lossy
    // REAL mapping, but an interface ABI must be exact (the hand-written DWrite
    // binding used SHORTREAL for precisely this reason).
    if s == "f32" {
        return M2Ref::Builtin("SHORTREAL".to_string());
    }
    if s == "f64" {
        return M2Ref::Builtin("LONGREAL".to_string());
    }
    resolve_base(s, ctx, index, current, warnings)
}

/// Map a winmd enum underlying type to its M2 backing builtin (defaults DWORD).
pub fn enum_backing_builtin(underlying: &str) -> String {
    primitive(underlying).unwrap_or("DWORD").to_string()
}
