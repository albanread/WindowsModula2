//! Main semantic analysis pass.
//!
//! Entry point: [`check_module_graph`].  Walks the topological order of
//! the module graph (dependency before dependent) and analyses each
//! module.  A module's scope is built in two passes:
//!   1. *Declaration scan* — register every declared name; allocate a
//!      fresh `TypeId` placeholder for every type declaration.
//!   2. *Resolution* — fill in every placeholder; form record/array/
//!      pointer layouts; evaluate constant expressions; build class
//!      vtables.
//!
//! Scope chain used per module:
//!   pervasive → module scope (imports + own declarations)
//!
//! For procedure bodies (IMPLEMENTATION/PROGRAM modules):
//!   pervasive → module → procedure (params + locals)
//!
//! Diagnostics are accumulated rather than aborted at first error, so
//! a single invocation can report all errors in a module.

use std::collections::HashMap;

use newm2_lexer::{LiteralFlavor, Span};
use newm2_loader::{ModuleGraph, ModuleId};
use newm2_parser::ast;

use crate::{
    class::{ClassArena, ClassError, ClassSymbolId, FieldSlot, MethodSlot},
    constant::{ConstValue, EvalError, eval_const},
    scope::{BindingId, CallingConv, DeclarationId, ImportProvenanceHop, NamedParam, ProcAttrKind, ProcSig, ScopeArena, ScopeId, ScopeKind, Symbol, SymbolKind, SymbolProvenance},
    symcache::{self, CacheConfig},
    types::{Builtin, ParamMode, ProcParam, RecordFieldSlot, RecordLayout, TypeArena, TypeId, TypeKind, VariantArmLayout, VariantLabel, VariantLayout},
};

// ---- Diagnostics ----------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub severity: Severity,
    pub message: String,
    pub span: Span,
    /// Module where this diagnostic originates.
    pub module_id: ModuleId,
}

/// Key for span-annotated maps. Includes the `ModuleId` because source byte
/// offsets are only unique *within* a file — without the module, expressions
/// at the same offset in different modules collide (e.g. an INTEGER `+` in one
/// module reading a REAL type annotated at the same offset in another).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SpanKey {
    pub module: ModuleId,
    pub start: usize,
    pub end: usize,
}

impl SpanKey {
    pub fn new(module: ModuleId, span: Span) -> Self {
        Self {
            module,
            start: span.start.offset,
            end: span.end.offset,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectorBinding {
    Field { ty: TypeId, index: Option<u32> },
    /// A class method selector (`obj.M`). `vtable_index` is the slot to load
    /// from the object's vtable for virtual dispatch; `ty` is the return type
    /// (or a placeholder for a proper procedure). `class` is the static class.
    Method { ty: TypeId, vtable_index: u32, class: ClassSymbolId },
}

#[derive(Debug, Clone)]
pub struct ResolvedName {
    pub name: String,
    pub kind: SymbolKind,
    pub provenance: SymbolProvenance,
    pub declaration_id: DeclarationId,
    pub binding_id: BindingId,
    pub declaration_span: Span,
    pub exported: bool,
}

impl ResolvedName {
    pub fn declaration_id(&self) -> DeclarationId {
        self.declaration_id
    }

    pub fn binding_id(&self) -> BindingId {
        self.binding_id
    }

    pub fn declaring_module(&self) -> Option<(ModuleId, &str)> {
        self.provenance.declaring_module()
    }

    pub fn immediate_import(&self) -> Option<&ImportProvenanceHop> {
        self.provenance.immediate_import()
    }

    pub fn import_chain(&self) -> &[ImportProvenanceHop] {
        self.provenance.import_chain()
    }

    pub fn root_name(&self) -> &str {
        self.provenance.root_name().unwrap_or(self.name.as_str())
    }

    pub fn is_imported(&self) -> bool {
        self.provenance.is_imported()
    }
}

// ---- SemaResult -----------------------------------------------------------

pub struct SemaResult {
    /// Map from `ModuleId` to the top-level scope of that module.
    pub module_scopes: HashMap<ModuleId, ScopeId>,
    /// Map from `(ModuleId, procedure_name)` to that procedure's body scope.
    pub proc_scopes: HashMap<(ModuleId, String), ScopeId>,
    pub types: TypeArena,
    pub classes: ClassArena,
    pub scopes: ScopeArena,
    pub expr_types: HashMap<SpanKey, TypeId>,
    pub designator_types: HashMap<SpanKey, TypeId>,
    pub selector_bindings: HashMap<SpanKey, SelectorBinding>,
    pub resolved_names: HashMap<SpanKey, ResolvedName>,
    pub diagnostics: Vec<Diagnostic>,
    /// The `ScopeId` of the pervasive (built-in) scope.
    pub pervasive: ScopeId,
}

impl SemaResult {
    pub fn has_errors(&self) -> bool {
        self.diagnostics.iter().any(|d| d.severity == Severity::Error)
    }

    pub fn expr_type(&self, module: ModuleId, span: Span) -> Option<TypeId> {
        self.expr_types.get(&SpanKey::new(module, span)).copied()
    }

    pub fn designator_type(&self, module: ModuleId, span: Span) -> Option<TypeId> {
        self.designator_types.get(&SpanKey::new(module, span)).copied()
    }

    pub fn selector_binding(&self, module: ModuleId, span: Span) -> Option<SelectorBinding> {
        self.selector_bindings.get(&SpanKey::new(module, span)).copied()
    }

    pub fn resolved_name(&self, module: ModuleId, span: Span) -> Option<&SymbolKind> {
        self.resolved_binding(module, span).map(|resolved| &resolved.kind)
    }

    pub fn resolved_binding(&self, module: ModuleId, span: Span) -> Option<&ResolvedName> {
        self.resolved_names.get(&SpanKey::new(module, span))
    }

    pub fn resolved_provenance(&self, module: ModuleId, span: Span) -> Option<&SymbolProvenance> {
        self.resolved_binding(module, span).map(|resolved| &resolved.provenance)
    }

    pub fn resolved_declaration_id(&self, module: ModuleId, span: Span) -> Option<DeclarationId> {
        self.resolved_binding(module, span).map(|resolved| resolved.declaration_id)
    }

    pub fn resolved_binding_id(&self, module: ModuleId, span: Span) -> Option<BindingId> {
        self.resolved_binding(module, span).map(|resolved| resolved.binding_id)
    }
}

// ---- Context --------------------------------------------------------------

/// The mutable context threaded through all analysis functions.
struct Ctx {
    types: TypeArena,
    classes: ClassArena,
    scopes: ScopeArena,
    module_scopes: HashMap<ModuleId, ScopeId>,
    proc_scopes: HashMap<(ModuleId, String), ScopeId>,
    expr_types: HashMap<SpanKey, TypeId>,
    designator_types: HashMap<SpanKey, TypeId>,
    selector_bindings: HashMap<SpanKey, SelectorBinding>,
    resolved_names: HashMap<SpanKey, ResolvedName>,
    diagnostics: Vec<Diagnostic>,
    pervasive: ScopeId,
    /// Current module being analysed.
    current_module: ModuleId,
    current_module_name: String,
    next_declaration_id: u32,
    next_binding_id: u32,
    /// Modules whose interface is mid-construction — guards the on-demand
    /// interface recursion against import cycles (IOChan ↔ IOLink).
    building: std::collections::HashSet<ModuleId>,
    /// While building interfaces, a cross-module qualified constant bound may
    /// not be resolvable yet; suppress the const-eval error so the re-resolve
    /// phase can report any that genuinely persist.
    defer_const_errors: bool,
    /// True while forming the *target* type of a `POINTER TO …`. A huge fixed
    /// array (`POINTER TO ARRAY [0..MAX(CARDINAL)-1] OF CHAR`) is a legitimate
    /// flex-buffer view — only the pointer is stored, never the array — so the
    /// "array too large" check is suppressed for anything behind a pointer.
    in_pointer_target: bool,
    /// Active `WITH` record types, innermost last. A bare field name inside a
    /// `WITH r DO … END` resolves against the nearest of these whose record
    /// has that field. The flag is `true` when the WITH designator is read-only
    /// (a constant), so assignment to its fields is rejected.
    with_stack: Vec<(TypeId, bool)>,
    /// Signatures of `FORWARD`-declared procedures, keyed by (scope, name). The
    /// later defining declaration must match its forward declaration.
    forward_proc_sigs: std::collections::HashMap<(ScopeId, String), ProcSig>,
    /// Per-scope cache of the constant-lookup map (`collect_scope_consts`),
    /// tagged with the scope's symbol count when built. Rebuilding it for every
    /// `CONST` is O(n²) on the huge Win32 constant tables (10k+ consts); the
    /// cache makes it O(n). Invalidated when the symbol count changes (a new
    /// symbol was added); const-value updates patch the entry in place.
    const_cache: HashMap<ScopeId, (usize, HashMap<String, ConstValue>)>,
    /// Pedantic mode (driver `--strict`). OFF by default — the dialect is
    /// deliberately lenient — gating the optional static checks (e.g. a
    /// compile-time-constant index proven out of bounds) that some users want but
    /// most find inconvenient. Lenient builds still catch these at run time.
    strict: bool,
}

impl Ctx {
    fn new() -> Self {
        let mut scopes = ScopeArena::default();
        let mut types = TypeArena::new();
        let mut next_declaration_id = 0;
        let mut next_binding_id = 0;

        // Build the pervasive scope with all pre-declared names.
        let pervasive = scopes.push(ScopeKind::Pervasive, None);
        build_pervasive_scope(
            &mut scopes,
            &mut types,
            pervasive,
            &mut next_declaration_id,
            &mut next_binding_id,
        );

        Ctx {
            types,
            classes: ClassArena::new(),
            scopes,
            module_scopes: HashMap::new(),
            proc_scopes: HashMap::new(),
            expr_types: HashMap::new(),
            designator_types: HashMap::new(),
            selector_bindings: HashMap::new(),
            resolved_names: HashMap::new(),
            diagnostics: Vec::new(),
            pervasive,
            current_module: ModuleId(0),
            current_module_name: String::new(),
            next_declaration_id,
            next_binding_id,
            building: std::collections::HashSet::new(),
            defer_const_errors: false,
            in_pointer_target: false,
            with_stack: Vec::new(),
            forward_proc_sigs: std::collections::HashMap::new(),
            const_cache: HashMap::new(),
            strict: false,
        }
    }

    fn fresh_declaration_id(&mut self) -> DeclarationId {
        let id = DeclarationId(self.next_declaration_id);
        self.next_declaration_id += 1;
        id
    }

    fn fresh_binding_id(&mut self) -> BindingId {
        let id = BindingId(self.next_binding_id);
        self.next_binding_id += 1;
        id
    }

    fn error(&mut self, span: Span, msg: impl Into<String>) {
        self.diagnostics.push(Diagnostic {
            severity: Severity::Error,
            message: msg.into(),
            span,
            module_id: self.current_module,
        });
    }

    fn warning(&mut self, span: Span, msg: impl Into<String>) {
        self.diagnostics.push(Diagnostic {
            severity: Severity::Warning,
            message: msg.into(),
            span,
            module_id: self.current_module,
        });
    }

    fn eval_error(&mut self, e: EvalError) {
        self.diagnostics.push(Diagnostic {
            severity: Severity::Error,
            message: e.message,
            span: e.span,
            module_id: self.current_module,
        });
    }

    fn class_error(&mut self, e: ClassError) {
        self.diagnostics.push(Diagnostic {
            severity: Severity::Error,
            message: e.message,
            span: e.span,
            module_id: self.current_module,
        });
    }

    fn note_expr_type(&mut self, span: Span, ty: TypeId) {
        self.expr_types.insert(SpanKey::new(self.current_module, span), ty);
    }

    fn note_designator_type(&mut self, span: Span, ty: TypeId) {
        self.designator_types.insert(SpanKey::new(self.current_module, span), ty);
        self.note_expr_type(span, ty);
    }

    fn note_selector_binding(&mut self, span: Span, binding: SelectorBinding) {
        self.selector_bindings.insert(SpanKey::new(self.current_module, span), binding);
    }

    fn note_name_resolution(&mut self, span: Span, sym: &Symbol) {
        self.resolved_names.insert(
            SpanKey::new(self.current_module, span),
            ResolvedName {
                name: sym.name.clone(),
                kind: sym.kind.clone(),
                provenance: sym.provenance.clone(),
                declaration_id: sym.declaration_id,
                binding_id: sym.binding_id,
                declaration_span: sym.span,
                exported: sym.exported,
            },
        );
    }
}

// ---- Entry point ----------------------------------------------------------

/// Analyse every module in the graph.
///
/// Two phases so that mutually-importing modules (the canonical IOChan ↔
/// IOLink) resolve each other: first build every module's *interface* (imports,
/// types, consts, procedure signatures — but not bodies), then analyse the
/// bodies. Interfaces are built on demand (see [`ensure_interface`]) so a
/// module's imports are ready before it is resolved.
pub fn check_module_graph(graph: &ModuleGraph) -> SemaResult {
    check_module_graph_impl(graph, None, false)
}

/// As [`check_module_graph`], but with pedantic `--strict` static checks enabled.
pub fn check_module_graph_strict(graph: &ModuleGraph, strict: bool) -> SemaResult {
    check_module_graph_impl(graph, None, strict)
}

/// Like [`check_module_graph`], but a [`CacheConfig`] enables the separate-
/// compilation symbol cache: a module whose interface is found valid on disk is
/// re-interned instead of re-checked, and freshly-checked interfaces are written
/// back. With `cache = None` this is identical to [`check_module_graph`].
pub fn check_module_graph_cached(graph: &ModuleGraph, cache: &CacheConfig) -> SemaResult {
    check_module_graph_impl(graph, Some(cache), false)
}

/// As [`check_module_graph_cached`], with pedantic `--strict` checks enabled.
pub fn check_module_graph_cached_strict(
    graph: &ModuleGraph,
    cache: &CacheConfig,
    strict: bool,
) -> SemaResult {
    check_module_graph_impl(graph, Some(cache), strict)
}

fn check_module_graph_impl(
    graph: &ModuleGraph,
    cache: Option<&CacheConfig>,
    strict: bool,
) -> SemaResult {
    let mut ctx = Ctx::new();
    ctx.strict = strict;
    // Modules whose interface came from the cache (re-interned, not checked):
    // they skip the interface-resolution sub-phases and body analysis below.
    let mut cached: std::collections::HashSet<ModuleId> = std::collections::HashSet::new();

    // Pass 1 — interfaces. Defer const-eval errors: a cross-module bound may
    // not be resolvable until every interface exists.
    ctx.defer_const_errors = true;
    for &mid in &graph.topo_order {
        // A cyclic peer may already be fully built — an earlier module fell back
        // to a full check and recursively built this one as an import. Never
        // re-intern over it (that would split a shared type's identity and rob it
        // of the pass-1.5 alias repair its peer's body depends on).
        if ctx.module_scopes.contains_key(&mid) {
            continue;
        }
        if let Some(cfg) = cache {
            // Cache ONLY pure-DEF modules (a DEFINITION with no IMPLEMENTATION
            // body). A module with a body must be fully checked AND code-lowered;
            // a re-interned interface-only scope cannot be body-lowered (build
            // would miscompile), and stdlib cycles (IOChan↔IOLink) concretize
            // opaque types in their bodies, which re-intern cannot reproduce.
            // Pure-DEF modules have nothing to lower, so skipping their interface
            // check is sound — and they are exactly the heavy Win32 type surface.
            if cfg.read && is_pure_def(graph.get(mid)) {
                if let Some(iface) = symcache::load_valid_interface(graph, mid, cfg) {
                    if try_intern_cached(&mut ctx, graph, mid, &iface) {
                        cached.insert(mid);
                        continue;
                    }
                }
            }
        }
        ensure_interface(&mut ctx, graph, mid);
    }
    ctx.defer_const_errors = false;

    // Pass 1.5 — re-resolve named-type aliases. A cross-module alias built
    // during cyclic interface construction (e.g. IOChan's `ChanId =
    // IOLink.DeviceTablePtr`) may have cloned an as-yet-unresolved target; now
    // that every interface exists, resolve it for real. (Cached interfaces are
    // already fully resolved.)
    for &mid in &graph.topo_order {
        if cached.contains(&mid) {
            continue;
        }
        reresolve_named_aliases(&mut ctx, graph, mid);
    }

    // Pass 1.6 — reject infinite *pure-alias* type cycles (`A = B; B = A`).
    // Cycles that pass through a pointer/record/array are legal (the pointer
    // breaks the recursion), so only chains of plain `TYPE X = Y` names count.
    for &mid in &graph.topo_order {
        if cached.contains(&mid) {
            continue;
        }
        check_type_alias_cycles(&mut ctx, graph, mid);
    }

    // Pass 2 — bodies (procedure bodies + module bodies). Cached modules are
    // interface-only (a DEF reloaded from disk) with no bodies to analyse.
    for &mid in &graph.topo_order {
        if cached.contains(&mid) {
            continue;
        }
        let node = graph.get(mid);
        if node.is_intrinsic {
            continue;
        }
        if let (Some(ast), Some(&scope)) = (
            node.impl_ast.as_ref().or(node.def_ast.as_ref()),
            ctx.module_scopes.get(&mid),
        ) {
            ctx.current_module = mid;
            ctx.current_module_name = node.name.clone();
            analyse_module_bodies(&mut ctx, graph, mid, ast, scope);
        }
    }

    let result = SemaResult {
        module_scopes: ctx.module_scopes,
        proc_scopes: ctx.proc_scopes,
        types: ctx.types,
        classes: ctx.classes,
        scopes: ctx.scopes,
        expr_types: ctx.expr_types,
        designator_types: ctx.designator_types,
        selector_bindings: ctx.selector_bindings,
        resolved_names: ctx.resolved_names,
        diagnostics: ctx.diagnostics,
        pervasive: ctx.pervasive,
    };

    if cache.is_some() && std::env::var("NEWM2_CACHE_DEBUG").is_ok() {
        eprintln!(
            "[cache] re-interned {} of {} modules",
            cached.len(),
            graph.topo_order.len()
        );
    }

    // Write-back — store freshly-checked interfaces for next time. Skip ones we
    // loaded from the cache (unchanged) and anything not faithfully exportable.
    if let Some(cfg) = cache {
        if cfg.write && !result.has_errors() {
            for &mid in &graph.topo_order {
                if cached.contains(&mid) || !is_pure_def(graph.get(mid)) {
                    continue;
                }
                if let Some(iface) = crate::iface::export_interface(&result, graph, mid) {
                    symcache::store_interface(graph, mid, cfg, &iface);
                }
            }
        }
    }

    result
}

/// A pure-DEFINITION module: a parsed DEF with no IMPLEMENTATION body, and not
/// an intrinsic. Only these are safe to cache — they have no body to lower and
/// don't concretize opaque types, so a re-interned interface fully replaces a
/// fresh check of them.
fn is_pure_def(node: &newm2_loader::ModuleNode) -> bool {
    !node.is_intrinsic && node.def_ast.is_some() && node.impl_ast.is_none()
}

/// Re-intern a cached interface into the live `Ctx`, registering its module
/// scope. Returns `false` (a clean fall-back to a full check) if any referenced
/// import isn't interned yet — e.g. a module in an import cycle.
fn try_intern_cached(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    iface: &crate::iface::ModuleInterface,
) -> bool {
    // Resolver source: every named type of every already-interned module.
    let mut import_types: HashMap<(String, String), TypeId> = HashMap::new();
    for (&bmid, &scope) in &ctx.module_scopes {
        let bname = graph.get(bmid).name.clone();
        for sym in ctx.scopes.get(scope).iter() {
            if let SymbolKind::Type(ty) = &sym.kind {
                import_types.insert((bname.clone(), sym.name.clone()), *ty);
            }
        }
    }
    // Pre-check: every cross-module reference must already be available, so we
    // never half-build into the arena and then fail.
    for (m, n) in crate::iface::referenced_import_types(iface) {
        if m != iface.module && !import_types.contains_key(&(m.to_string(), n.to_string())) {
            return false;
        }
    }
    let resolve = |m: &str, n: &str| import_types.get(&(m.to_string(), n.to_string())).copied();
    match crate::iface::intern_interface(
        iface,
        mid,
        &mut ctx.types,
        &mut ctx.scopes,
        ctx.pervasive,
        &mut ctx.next_declaration_id,
        &mut ctx.next_binding_id,
        &resolve,
    ) {
        Some(scope) => {
            ctx.module_scopes.insert(mid, scope);
            true
        }
        None => false,
    }
}

// ---- Pervasive scope ------------------------------------------------------

fn build_pervasive_scope(
    scopes: &mut ScopeArena,
    types: &mut TypeArena,
    pervasive: ScopeId,
    next_declaration_id: &mut u32,
    next_binding_id: &mut u32,
) {
    use Builtin::*;
    let scope = scopes.get_mut(pervasive);

    let mut fresh_declaration_id = || {
        let id = DeclarationId(*next_declaration_id);
        *next_declaration_id += 1;
        id
    };
    let mut fresh_binding_id = || {
        let id = BindingId(*next_binding_id);
        *next_binding_id += 1;
        id
    };

    macro_rules! builtin_type {
        ($name:expr, $b:ident) => {
            scope.insert(Symbol {
                name: $name.into(),
                kind: SymbolKind::Type(types.builtin($b)),
                span: dummy_span(),
                declaration_id: fresh_declaration_id(),
                binding_id: fresh_binding_id(),
                provenance: SymbolProvenance::Pervasive,
                exported: true,
            })
        };
    }

    // A pervasive SIMD lane-vector type (`REAL32X4` = `<4 x float>`, …).
    macro_rules! vector_type {
        ($name:expr, $lanes:expr, $base:ident) => {{
            let base = types.builtin($base);
            let vid = types.alloc(TypeKind::Vector { lanes: $lanes, base });
            scope.insert(Symbol {
                name: $name.into(),
                kind: SymbolKind::Type(vid),
                span: dummy_span(),
                declaration_id: fresh_declaration_id(),
                binding_id: fresh_binding_id(),
                provenance: SymbolProvenance::Pervasive,
                exported: true,
            })
        }};
    }

    // Standard scalar types.
    builtin_type!("BOOLEAN", Boolean);
    builtin_type!("CHAR", Char);
    builtin_type!("INTEGER", Integer);
    builtin_type!("CARDINAL", Cardinal);
    builtin_type!("REAL", Real);
    builtin_type!("LONGINT", LongInt);
    builtin_type!("LONGCARD", LongCard);
    builtin_type!("LONGREAL", LongReal);
    builtin_type!("BITSET", Bitset);
    builtin_type!("PROC", Proc);
    builtin_type!("COMPLEX", Complex);
    builtin_type!("LONGCOMPLEX", LongComplex);

    // ADW exact-width types.
    builtin_type!("INTEGER8", Integer8);
    builtin_type!("INTEGER16", Integer16);
    builtin_type!("INTEGER32", Integer32);
    builtin_type!("INTEGER64", Integer64);
    builtin_type!("CARDINAL8", Cardinal8);
    builtin_type!("CARDINAL16", Cardinal16);
    builtin_type!("CARDINAL32", Cardinal32);
    builtin_type!("CARDINAL64", Cardinal64);
    builtin_type!("BYTE", Byte);
    builtin_type!("WORD", Word);
    builtin_type!("DWORD", Dword);
    builtin_type!("QWORD", Qword);
    builtin_type!("ADDRESS", Address);
    builtin_type!("ADRINT", Adrint);
    builtin_type!("ADRCARD", Adrcard);
    // PROTECTION is a pervasive type in ADW (interrupt protection level)
    builtin_type!("PROTECTION", Cardinal);
    // DWORDBOOL is an ADW pervasive alias for 32-bit BOOLEAN (C BOOL).
    builtin_type!("DWORDBOOL", Cardinal32);
    // ADW C-interop boolean/word typedefs used in win32 headers.
    builtin_type!("BOOL8",    Cardinal8);
    builtin_type!("BYTEBOOL", Cardinal8);
    builtin_type!("WORDBOOL", Cardinal16);
    builtin_type!("BITSET16", Cardinal16);
    builtin_type!("SHORTCARD", Cardinal16);
    builtin_type!("ACHAR", Achar);
    builtin_type!("UCHAR", Uchar);
    // PIM short scalar types (pervasive, like SHORTCARD). SHORTINT is true
    // 16-bit signed; SHORTREAL is a genuine distinct 32-bit float (Real32, NOT
    // an alias of REAL) so a SHORTREAL/REAL mismatch is still rejected.
    builtin_type!("SHORTINT", Integer16);
    builtin_type!("SHORTREAL", Real32);
    builtin_type!("SHORTCOMPLEX", Complex);

    // 128-bit SIMD lane vectors (pervasive). See docs/design/simd-laned-vectors.md.
    vector_type!("REAL64X2", 2, Real);
    vector_type!("REAL32X4", 4, Real32);

    // Boolean constants.
    scope.insert(Symbol {
        name: "TRUE".into(),
        kind: SymbolKind::Const {
            ty: types.builtin(Boolean),
            value: ConstValue::Bool(true),
        },
        span: dummy_span(),
        declaration_id: fresh_declaration_id(),
        binding_id: fresh_binding_id(),
        provenance: SymbolProvenance::Pervasive,
        exported: true,
    });
    scope.insert(Symbol {
        name: "FALSE".into(),
        kind: SymbolKind::Const {
            ty: types.builtin(Boolean),
            value: ConstValue::Bool(false),
        },
        span: dummy_span(),
        declaration_id: fresh_declaration_id(),
        binding_id: fresh_binding_id(),
        provenance: SymbolProvenance::Pervasive,
        exported: true,
    });
    // NIL constant (its "type" is the nil pseudo-type).
    scope.insert(Symbol {
        name: "NIL".into(),
        kind: SymbolKind::Const {
            ty: types.builtin(Nil),
            value: ConstValue::Nil,
        },
        span: dummy_span(),
        declaration_id: fresh_declaration_id(),
        binding_id: fresh_binding_id(),
        provenance: SymbolProvenance::Pervasive,
        exported: true,
    });
    // EMPTY — the null class reference (ADW OO). A synonym for NIL typed as the
    // nil pseudo-type; assignable to / comparable with any class reference.
    scope.insert(Symbol {
        name: "EMPTY".into(),
        kind: SymbolKind::Const {
            ty: types.builtin(Nil),
            value: ConstValue::Nil,
        },
        span: dummy_span(),
        declaration_id: fresh_declaration_id(),
        binding_id: fresh_binding_id(),
        provenance: SymbolProvenance::Pervasive,
        exported: true,
    });
    // MAX / MIN as pseudo-procedures — we treat them as Type symbols
    // pointing at a placeholder; the real evaluation is type-system-
    // dependent and handled in the constant evaluator's caller.
    // (The pervasive scope just needs a name so lookups don't fail.)
    for name in ["MAX", "MIN", "SIZE", "TSIZE", "INC", "DEC", "INCL", "EXCL",
                 "NEW", "DISPOSE", "DESTROY", "HALT", "ASSERT", "HIGH", "LEN", "LENGTH",
                 "ORD", "CHR", "VAL", "ABS", "ODD", "CAP", "TRUNC", "FLOAT",
                 "LFLOAT", "INT", "ENTIER", "RE", "IM", "CMPLX",
                 // COM HRESULT severity-bit tests (see docs/design/com-interfaces.md).
                 "SUCCEEDED", "FAILED",
                 // SIMD reductions / fused multiply-add (see simd-laned-vectors).
                 "SUM", "DOT", "FMA"] {
        scope.insert(Symbol {
            name: name.into(),
            kind: SymbolKind::Proc(ProcSig {
                params: vec![],
                return_ty: None,
                calling_conv: CallingConv::Default,
                attrs: vec![],
                external_linkage: None,
            }),
            span: dummy_span(),
            declaration_id: fresh_declaration_id(),
            binding_id: fresh_binding_id(),
            provenance: SymbolProvenance::Pervasive,
            exported: true,
        });
    }
}

fn build_intrinsic_module_scope(ctx: &mut Ctx, mid: ModuleId, module_name: &str) {
    // Intrinsic pseudo-modules export a fixed set of names.
    let scope = ctx.scopes.push(ScopeKind::Module, Some(ctx.pervasive));
    if module_name == "SYSTEM" {
        use Builtin::*;
        // SYSTEM pseudo-types (ISO 10514 + ADW extensions).
        for (name, b) in [
            ("ADDRESS",     SysAddress),
            ("LOC",         SysLoc),
            ("BYTE",        SysByte),
            ("WORD",        SysWord),
            // exact-width word types (unsigned storage units).
            ("WORD16",      Cardinal16),
            ("WORD32",      Cardinal32),
            ("WORD64",      Cardinal64),
            ("BITSET",      SysBitset),
            // ADW address-arithmetic aliases exported from SYSTEM.
            ("ADRINT",      Adrint),
            ("ADRCARD",     Adrcard),
            ("MACHINEWORD", Adrcard),   // same size as address word
            // ADW exact-width aliases for C interop.
            ("CARD8",       Cardinal8),
            ("CARD16",      Cardinal16),
            ("CARD32",      Cardinal32),
            ("CARD64",      Cardinal64),
            ("INT8",        Integer8),
            ("INT16",       Integer16),
            ("INT32",       Integer32),
            ("INT64",       Integer64),
            // PROTECTION = interrupt protection level (cardinal-sized)
            ("PROTECTION",  Cardinal),
            // VA_LIST = C variadic argument list pointer (address-sized)
            ("VA_LIST",     SysAddress),
            // FUNC = ADW generic function/procedure pointer type
            ("FUNC",        SysAddress),
            // PIM PROCESS = the coroutine/process handle for NEWPROCESS/TRANSFER.
            // Address-sized, same as the ISO COROUTINES.COROUTINE handle, so the
            // two interoperate (NEWPROCESS into a PROCESS, TRANSFER between them).
            ("PROCESS",     SysAddress),
            // sized real/complex/set + C-interop aliases. REAL64 = REAL
            // (both f64); REAL32/REAL16 are genuine distinct narrow floats.
            // CSIZE_T/COFF_T are the Win64 size_t/off_t widths.
            ("REAL64",      Real),
            ("REAL32",      Real32),
            ("REAL16",      Real16),
            ("COMPLEX32",   Complex),
            ("COMPLEX64",   Complex),
            ("BITSET32",    Cardinal32),
            ("CSIZE_T",     Cardinal64),
            ("COFF_T",      Integer64),
        ] {
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: name.into(),
                kind: SymbolKind::Type(ctx.types.builtin(b)),
                span: dummy_span(),
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Intrinsic {
                    module: mid,
                    module_name: module_name.to_string(),
                },
                exported: true,
            });
        }
        // SYSTEM constants (ISO 10514). A LOC is the smallest addressable unit
        // (a byte = 8 bits) and a WORD holds the natural machine word; on this
        // 64-bit build a WORD is 8 LOCs.
        for (name, value) in [
            ("BITSPERLOC", 8i128),
            ("LOCSPERBYTE", 1),
            ("LOCSPERWORD", 8),
        ] {
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: name.into(),
                kind: SymbolKind::Const {
                    ty: ctx.types.builtin(Cardinal),
                    value: ConstValue::Int(value),
                },
                span: dummy_span(),
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Intrinsic {
                    module: mid,
                    module_name: module_name.to_string(),
                },
                exported: true,
            });
        }
        // SYSTEM functions (treated as proc symbols for lookup purposes).
        // The coroutine entries remain as legacy aliases so sema can issue a
        // focused "Not yet implemented" diagnostic instead of unresolved-name
        // noise while the ISO COROUTINES pseudo-module is taking over.
        for name in ["ADR", "TSIZE", "TBITSIZE", "ADDADR", "SUBADR", "DIFADR", "MAKEADR",
                     "NEWPROCESS", "TRANSFER", "IOTRANSFER", "SHIFT", "ROTATE",
                     "THROW",
                     "CAST", "PIN", "UNPIN", "GC_REGISTER", "COLLECT", "GCREPORT",
                     // ADW extras
                     "OFFS",
                     "UNREFERENCED_PARAMETER", "ASSERT",
                     "VA_START", "VA_END", "VA_ARG",
                     "PUSHREGISTERS", "POPREGISTERS",
                     "GetCurrentCoroutineId",
                     // ADW endian swap intrinsics
                     "SWAPENDIAN", "BIGENDIAN"] {
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: name.into(),
                kind: SymbolKind::Proc(ProcSig {
                    params: vec![],
                    return_ty: None,
                    calling_conv: CallingConv::Default,
                    attrs: vec![],
                    external_linkage: None,
                }),
                span: dummy_span(),
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Intrinsic {
                    module: mid,
                    module_name: module_name.to_string(),
                },
                exported: true,
            });
        }
    } else if module_name == "COROUTINES" {
        for (name, ty) in [
            ("COROUTINE", ctx.types.builtin(Builtin::SysAddress)),
            ("INTERRUPTSOURCE", ctx.types.builtin(Builtin::Cardinal)),
        ] {
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: name.into(),
                kind: SymbolKind::Type(ty),
                span: dummy_span(),
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Intrinsic {
                    module: mid,
                    module_name: module_name.to_string(),
                },
                exported: true,
            });
        }
        for name in [
            "NEWCOROUTINE",
            "TRANSFER",
            "IOTRANSFER",
            "ATTACH",
            "DETACH",
            "IsATTACHED",
            "HANDLER",
            "CURRENT",
            "LISTEN",
            "PROT",
            "COROUTINEDONE",
        ] {
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: name.into(),
                kind: SymbolKind::Proc(ProcSig {
                    params: vec![],
                    return_ty: None,
                    calling_conv: CallingConv::Default,
                    attrs: vec![],
                    external_linkage: None,
                }),
                span: dummy_span(),
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Intrinsic {
                    module: mid,
                    module_name: module_name.to_string(),
                },
                exported: true,
            });
        }
    }
    ctx.module_scopes.insert(mid, scope);
}

fn is_unimplemented_coroutine_call(
    ctx: &Ctx,
    designator: &ast::Designator,
    scope: ScopeId,
) -> bool {
    // NEWPROCESS / TRANSFER are implemented (fibers); IOTRANSFER (interrupt
    // driven) and the legacy id query remain unimplemented.
    const LEGACY_SYSTEM: &[&str] = &["IOTRANSFER", "GetCurrentCoroutineId"];
    // NEWCOROUTINE / TRANSFER / CURRENT are implemented (fibers); the
    // interrupt-driven device-driver primitives remain unimplemented.
    const ISO_COROUTINES: &[&str] = &[
        "IOTRANSFER",
        "ATTACH",
        "DETACH",
        "IsATTACHED",
        "HANDLER",
        "LISTEN",
        "PROT",
        "COROUTINEDONE",
    ];

    match designator.base.segments.as_slice() {
        [module, name] if designator.selectors.is_empty() && module == "SYSTEM" && LEGACY_SYSTEM.contains(&name.as_str()) => {
            true
        }
        [module, name] if designator.selectors.is_empty() && module == "COROUTINES" && ISO_COROUTINES.contains(&name.as_str()) => {
            true
        }
        [module]
            if matches!(module.as_str(), "SYSTEM" | "COROUTINES")
                && matches!(designator.selectors.as_slice(), [ast::Selector::Field(_, _)]) =>
        {
            let ast::Selector::Field(name, _) = &designator.selectors[0] else {
                unreachable!();
            };
            if (module == "SYSTEM" && LEGACY_SYSTEM.contains(&name.as_str()))
                || (module == "COROUTINES" && ISO_COROUTINES.contains(&name.as_str()))
            {
                return true;
            }
            false
        }
        [name] if designator.selectors.is_empty() => {
            let Some(sym) = ctx.scopes.lookup(scope, name) else {
                return false;
            };
            match &sym.provenance {
                SymbolProvenance::Intrinsic { module_name, .. }
                    if (module_name == "SYSTEM" && LEGACY_SYSTEM.contains(&name.as_str()))
                        || (module_name == "COROUTINES" && ISO_COROUTINES.contains(&name.as_str())) =>
                {
                    true
                }
                SymbolProvenance::Imported {
                    original_module_name,
                    from_module_name,
                    ..
                } => {
                    let module_name = original_module_name.as_deref().unwrap_or(from_module_name.as_str());
                    (module_name == "SYSTEM" && LEGACY_SYSTEM.contains(&name.as_str()))
                        || (module_name == "COROUTINES" && ISO_COROUTINES.contains(&name.as_str()))
                }
                _ => false,
            }
        }
        _ => false,
    }
}

fn analyse_unimplemented_intrinsic_call(
    ctx: &mut Ctx,
    callee: &ast::Expr,
    args: &[ast::Expr],
    span: Span,
    scope: ScopeId,
) -> Option<Option<TypeId>> {
    let ast::Expr::Designator(designator) = callee else {
        return None;
    };
    if !is_unimplemented_coroutine_call(ctx, designator, scope) {
        return None;
    }

    ctx.error(span, "Not yet implemented");
    for arg in args {
        let _ = analyse_expr(ctx, arg, scope);
    }
    Some(None)
}

// ---- Module analysis ------------------------------------------------------

/// Module names referenced by an import (the real module for `IMPORT a := M`).
fn import_module_names(imp: &ast::Import) -> Vec<String> {
    match imp {
        ast::Import::From { module, .. } => vec![module.clone()],
        ast::Import::Plain { names, .. } => names
            .iter()
            .map(|n| n.alias.clone().unwrap_or_else(|| n.name.clone()))
            .collect(),
    }
}

/// Build a module's *interface* — imports, types, consts, variables, procedure
/// signatures, classes — but not procedure or module bodies. Recursively
/// ensures imported modules' interfaces first; cycle-safe via `ctx.building`
/// (pass-1 placeholders are registered before imports so a mutually-importing
/// peer can still find this module's names).
fn ensure_interface(ctx: &mut Ctx, graph: &ModuleGraph, mid: ModuleId) {
    if ctx.module_scopes.contains_key(&mid) || ctx.building.contains(&mid) {
        return;
    }
    let node = graph.get(mid);
    if node.is_intrinsic {
        let name = node.name.clone();
        ctx.current_module = mid;
        ctx.current_module_name = name.clone();
        build_intrinsic_module_scope(ctx, mid, &name);
        return;
    }
    let Some(ast) = node.impl_ast.as_ref().or(node.def_ast.as_ref()) else {
        return;
    };
    let def_for_merge = node.impl_ast.is_some().then(|| node.def_ast.as_ref()).flatten();

    ctx.building.insert(mid);
    let scope = ctx.scopes.push(ScopeKind::Module, Some(ctx.pervasive));
    ctx.module_scopes.insert(mid, scope);

    // Pass-1 (register names + TypeId placeholders) BEFORE imports, so a cyclic
    // peer that imports us mid-build still resolves our names.
    ctx.current_module = mid;
    ctx.current_module_name = node.name.clone();
    for decl in &ast.decls {
        pass1_decl(ctx, decl, scope);
    }
    check_duplicate_decls(ctx, &ast.decls);
    let def_only = def_for_merge.map(|d| merge_def_pass1(ctx, d, scope)).unwrap_or_default();

    // Mark public symbols now (before imports) so a mutually-importing peer,
    // whose interface we build mid-recursion, can already see our exports.
    // Best-effort (no validation): re-exported imported names aren't in scope
    // until imports run, below.
    mark_module_exports(ctx, ast, node.def_ast.as_ref(), scope, false);

    // Ensure imported interfaces exist, then bring their symbols in.
    for imp in &ast.imports {
        for name in import_module_names(imp) {
            if let Some(imp_mid) = graph.lookup(&name) {
                ensure_interface(ctx, graph, imp_mid);
            }
        }
    }
    ctx.current_module = mid;
    ctx.current_module_name = node.name.clone();
    bring_in_imports(ctx, graph, mid, &ast.imports, scope, None);

    // A DEFINITION module's imports are part of its interface (needed to
    // express exported types) and may differ from the IMPLEMENTATION's imports
    // — e.g. `SIOResult.def` imports `IOConsts` for `ReadResults =
    // IOConsts.ReadResults`, while `SIOResult.mod` imports `IOChan, StdChans`.
    // Ensure + bind the def's imports too, so def-only aliases resolve.
    if let Some(def) = def_for_merge {
        for imp in &def.imports {
            for name in import_module_names(imp) {
                if let Some(imp_mid) = graph.lookup(&name) {
                    ensure_interface(ctx, graph, imp_mid);
                }
            }
        }
        ctx.current_module = mid;
        ctx.current_module_name = node.name.clone();
        bring_in_imports(ctx, graph, mid, &def.imports, scope, None);
    }

    // Pass-2 resolution — types, constants, signatures (no bodies yet).
    for decl in &ast.decls {
        pass2_decl(ctx, graph, mid, decl, scope, false);
    }
    // A CONST aggregate (`c = T{...}` for a RECORD/ARRAY T) declared *before*
    // its type in the same block could not fold during the source-order pass
    // above (T was still unresolved). Now that every type is resolved, re-fold
    // those aggregate constants so they carry their proper type and value.
    reeval_aggregate_consts(ctx, &ast.decls, scope);
    if let Some(def) = def_for_merge {
        merge_def_pass2(ctx, graph, mid, def, scope, &def_only);
        check_def_impl_proc_sigs(ctx, graph, mid, def, scope);
    }

    resolve_classes_in_scope(ctx, scope);
    // Re-mark exports now that imports + pass-2 (enum members, re-exported
    // names) are in scope; validate that the DEF's exports all exist.
    mark_module_exports(ctx, ast, node.def_ast.as_ref(), scope, true);

    ctx.building.remove(&mid);
}

/// Re-resolve a module's `TYPE A = SomeNamedType` aliases. Used after all
/// interfaces are built to repair cross-module aliases that, during cyclic
/// interface construction, cloned a still-`Unresolved` target.
fn reresolve_named_aliases(ctx: &mut Ctx, graph: &ModuleGraph, mid: ModuleId) {
    let node = graph.get(mid);
    if node.is_intrinsic {
        return;
    }
    let Some(&scope) = ctx.module_scopes.get(&mid) else {
        return;
    };
    ctx.current_module = mid;
    ctx.current_module_name = node.name.clone();
    for ast in [node.impl_ast.as_ref(), node.def_ast.as_ref()].into_iter().flatten() {
        for decl in &ast.decls {
            if let ast::Decl::Type(t) = decl
                && matches!(&t.def, Some(ast::TypeExpr::Named(_)) | Some(ast::TypeExpr::Subrange(..)))
                && let Some(SymbolKind::Type(type_id)) =
                    ctx.scopes.get(scope).get(&t.name).map(|s| s.kind.clone())
            {
                let te = t.def.as_ref().unwrap();
                let resolved = form_type_expr(ctx, graph, mid, te, scope);
                let kind = ctx.types.get(resolved).clone();
                ctx.types.set(type_id, kind);
            }
        }
    }
}

/// Reject infinite type-alias cycles: a chain of plain `TYPE X = Y` names that
/// returns to a name already on the chain. Aliases to a structural type
/// (pointer/record/array) or a builtin are not links, so legal recursive types
/// (`List = POINTER TO Node; Node = RECORD next: List END`) are never flagged.
fn check_type_alias_cycles(ctx: &mut Ctx, graph: &ModuleGraph, mid: ModuleId) {
    let node = graph.get(mid);
    if node.is_intrinsic {
        return;
    }
    for ast in [node.impl_ast.as_ref(), node.def_ast.as_ref()].into_iter().flatten() {
        // name -> (single-segment alias target, span)
        let mut aliases: HashMap<&str, (&str, Span)> = HashMap::new();
        for decl in &ast.decls {
            if let ast::Decl::Type(t) = decl
                && let Some(ast::TypeExpr::Named(qn)) = &t.def
                && qn.segments.len() == 1
            {
                aliases.insert(t.name.as_str(), (qn.segments[0].as_str(), t.span));
            }
        }
        for &start in aliases.keys() {
            let mut cur = start;
            // Bounded walk; a return to `start` closes a cycle.
            for _ in 0..aliases.len() + 1 {
                let Some(&(next, span)) = aliases.get(cur) else { break };
                if next == start {
                    ctx.error(span, format!("cyclic type definition: '{start}'"));
                    break;
                }
                cur = next;
            }
        }
    }
}

/// Mark which of a module's top-level symbols are public: every symbol in a
/// DEFINITION module, otherwise the names listed in the separate DEFINITION.
fn mark_module_exports(
    ctx: &mut Ctx,
    ast: &ast::Module,
    def_ast: Option<&ast::Module>,
    scope: ScopeId,
    validate: bool,
) {
    if ast.kind == ast::ModuleKind::Definition {
        for sym in ctx.scopes.get_mut(scope).iter_mut() {
            sym.exported = true;
        }
    }
    if let Some(def_ast) = def_ast {
        apply_def_exports(ctx, def_ast, scope, validate);
    }
}

/// Analyse a module's bodies (procedure bodies + the module body), assuming its
/// interface scope is already built.
fn analyse_module_bodies(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    ast: &ast::Module,
    scope: ScopeId,
) {
    for decl in &ast.decls {
        analyse_decl_body(ctx, graph, mid, decl, scope);
    }
    if let Some(body) = &ast.body {
        analyse_block(ctx, graph, mid, body, scope, None);
    }
}

/// Analyse the body part of a declaration (procedure bodies, nested-module
/// bodies). Interface work was already done by [`ensure_interface`].
fn analyse_decl_body(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    decl: &ast::Decl,
    scope: ScopeId,
) {
    match decl {
        ast::Decl::Procedure(p) => {
            if let Some(body) = &p.body {
                let sig = match ctx.scopes.get(scope).get(&p.name).map(|s| s.kind.clone()) {
                    Some(SymbolKind::Proc(sig)) => sig,
                    _ => form_proc_sig(ctx, graph, mid, p, scope),
                };
                analyse_proc_body(ctx, graph, mid, p, body, scope, &sig);
            }
        }
        ast::Decl::LocalModule(m) => {
            if let Some(SymbolKind::Module(_, local_scope)) =
                ctx.scopes.get(scope).get(&m.name).map(|s| s.kind.clone())
            {
                for d in &m.decls {
                    analyse_decl_body(ctx, graph, mid, d, local_scope);
                }
                if let Some(body) = &m.body {
                    analyse_block(ctx, graph, mid, body, local_scope, None);
                }
            }
        }
        ast::Decl::Class(cd) => {
            let Some(SymbolKind::Class(cid)) =
                ctx.scopes.get(scope).get(&cd.name).map(|s| s.kind.clone())
            else {
                return;
            };
            for member in &cd.members {
                if let ast::ClassMember::Method(m) = member {
                    if m.body.is_some() {
                        analyse_method_body(ctx, graph, mid, cid, m, scope);
                    }
                }
            }
        }
        _ => {}
    }
}

/// Analyse a class method body. The receiver `SELF` (the class type) and the
/// method parameters are in scope; the class's fields are visible unqualified
/// (an implicit `WITH SELF`, modelled by pushing the object record onto the
/// WITH stack so bare names resolve to fields of `SELF`).
fn analyse_method_body(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    cid: ClassSymbolId,
    m: &ast::MethodDecl,
    parent_scope: ScopeId,
) {
    let Some(body) = &m.body else {
        return;
    };
    let method_scope = ctx.scopes.push(ScopeKind::Procedure, Some(parent_scope));
    let class_name = ctx.classes.get(cid).name.clone();
    ctx.proc_scopes
        .insert((mid, format!("{class_name}.{}", m.name)), method_scope);

    // The receiver SELF, typed as the class.
    let class_ty = ctx.classes.get(cid).type_id;
    register_local_var(ctx, method_scope, "SELF", class_ty, Some(ParamMode::Value), m.span);

    // Method parameters.
    for param in &m.params {
        let ty = form_type_expr(ctx, graph, mid, &param.ty, method_scope);
        let mode = match param.mode {
            ast::ParamMode::Var => ParamMode::Var,
            ast::ParamMode::Const => ParamMode::Const,
            ast::ParamMode::Value => ParamMode::Value,
        };
        for name in &param.names {
            register_local_var(ctx, method_scope, name, ty, Some(mode), param.span);
        }
    }
    let return_ty = m
        .return_ty
        .as_ref()
        .map(|te| form_type_expr(ctx, graph, mid, te, method_scope));

    for decl in &body.decls {
        pass1_decl(ctx, decl, method_scope);
    }
    for decl in &body.decls {
        pass2_decl(ctx, graph, mid, decl, method_scope, true);
    }

    let object_record = ctx.classes.get(cid).object_record;
    if let Some(or) = object_record {
        // SELF's fields are writable inside a method.
        ctx.with_stack.push((or, false));
    }
    analyse_block(ctx, graph, mid, &body.body, method_scope, return_ty);
    if object_record.is_some() {
        ctx.with_stack.pop();
    }
}

/// Insert a `Var` (parameter or `SELF`) into a method/procedure scope.
fn register_local_var(
    ctx: &mut Ctx,
    scope: ScopeId,
    name: &str,
    ty: TypeId,
    param_mode: Option<ParamMode>,
    span: Span,
) {
    let declaration_id = ctx.fresh_declaration_id();
    let binding_id = ctx.fresh_binding_id();
    ctx.scopes.get_mut(scope).insert(Symbol {
        name: name.to_string(),
        kind: SymbolKind::Var { ty, param_mode },
        span,
        declaration_id,
        binding_id,
        provenance: SymbolProvenance::Declared {
            module: ctx.current_module,
            module_name: ctx.current_module_name.clone(),
        },
        exported: false,
    });
}

/// Bring DEFINITION-declared `CONST` / `TYPE` / `VAR` that the
/// IMPLEMENTATION does not itself redeclare into the implementation scope.
///
/// Modula-2 semantics: an implementation module inherits its definition's
/// constants and (non-opaque) types — they are not repeated in the `.mod`.
/// Only `PROCEDURE` bodies and opaque-type completions appear in the
/// implementation, and those are already in scope from the `.mod` scan.
/// Pass-1 half of the DEF merge: register DEF-only `CONST`/`TYPE`/`VAR` names
/// the IMPLEMENTATION does not redeclare, returning their decl indices so the
/// pass-2 half can resolve exactly those.
fn merge_def_pass1(ctx: &mut Ctx, def_ast: &ast::Module, scope: ScopeId) -> Vec<usize> {
    let mut def_only = Vec::new();
    for (i, decl) in def_ast.decls.iter().enumerate() {
        let missing = match decl {
            ast::Decl::Const(c) => ctx.scopes.get(scope).get(&c.name).is_none(),
            ast::Decl::Type(t) => ctx.scopes.get(scope).get(&t.name).is_none(),
            ast::Decl::Var(v) => v.names.iter().any(|n| ctx.scopes.get(scope).get(n).is_none()),
            _ => false,
        };
        if missing {
            def_only.push(i);
        }
    }
    for &i in &def_only {
        pass1_decl(ctx, &def_ast.decls[i], scope);
    }
    def_only
}

/// Pass-2 half of the DEF merge: resolve the DEF-only decls from
/// [`merge_def_pass1`] (consts/types/vars only — never procedure bodies).
fn merge_def_pass2(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    def_ast: &ast::Module,
    scope: ScopeId,
    def_only: &[usize],
) {
    for &i in def_only {
        pass2_decl(ctx, graph, mid, &def_ast.decls[i], scope, false);
    }
}

/// A procedure declared in both the DEFINITION and the IMPLEMENTATION must agree
/// on its signature: parameter count, each parameter's VAR mode and (structural)
/// type, and the result type. The IMPLEMENTATION's signature is already in
/// scope; the DEFINITION header is re-formed and compared structurally.
fn check_def_impl_proc_sigs(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    def_ast: &ast::Module,
    scope: ScopeId,
) {
    for decl in &def_ast.decls {
        let ast::Decl::Procedure(pd) = decl else { continue };
        let impl_sig = match ctx.scopes.get(scope).get(&pd.name).map(|s| &s.kind) {
            Some(SymbolKind::Proc(sig)) => sig.clone(),
            _ => continue,
        };
        let def_sig = form_proc_sig(ctx, graph, mid, pd, scope);
        if !proc_sigs_compatible(ctx, &def_sig, &impl_sig) {
            ctx.error(
                pd.span,
                format!(
                    "procedure '{}' does not match its DEFINITION-module signature",
                    pd.name
                ),
            );
        }
    }
}

fn apply_def_exports(ctx: &mut Ctx, def_ast: &ast::Module, scope: ScopeId, validate: bool) {
    if def_ast.kind != ast::ModuleKind::Definition {
        return;
    }

    for sym in ctx.scopes.get_mut(scope).iter_mut() {
        sym.exported = false;
    }

    let mut explicit_exports: Option<Vec<String>> = None;

    for decl in &def_ast.decls {
        match decl {
            ast::Decl::Const(c) => mark_scope_symbol_exported(ctx, scope, &c.name, c.span, validate),
            ast::Decl::Type(t) => {
                mark_scope_symbol_exported(ctx, scope, &t.name, t.span, validate);
                mark_enum_members_exported(ctx, scope, &t.name);
            }
            ast::Decl::Var(v) => {
                for name in &v.names {
                    mark_scope_symbol_exported(ctx, scope, name, v.span, validate);
                }
            }
            ast::Decl::Procedure(p) => {
                mark_scope_symbol_exported(ctx, scope, &p.name, p.span, validate)
            }
            ast::Decl::Class(c) => mark_scope_symbol_exported(ctx, scope, &c.name, c.span, validate),
            ast::Decl::Export { names, .. } => {
                explicit_exports = Some(names.clone());
            }
            ast::Decl::Pragma(_) | ast::Decl::LocalModule(_) => {}
        }
    }

    if let Some(names) = explicit_exports {
        for sym in ctx.scopes.get_mut(scope).iter_mut() {
            sym.exported = false;
        }
        for name in names {
            mark_scope_symbol_exported(ctx, scope, &name, def_ast.span, validate);
            mark_enum_members_exported(ctx, scope, &name);
        }
    }
}

fn mark_scope_symbol_exported(
    ctx: &mut Ctx,
    scope: ScopeId,
    name: &str,
    span: Span,
    validate: bool,
) {
    if let Some(sym) = ctx.scopes.get_mut(scope).get_mut(name) {
        sym.exported = true;
    } else if validate {
        ctx.error(span, format!("definition exports '{name}' but implementation does not declare it"));
    }
}

fn mark_enum_members_exported(ctx: &mut Ctx, scope: ScopeId, type_name: &str) {
    let enum_ty = match ctx.scopes.get(scope).get(type_name) {
        Some(sym) => match sym.kind {
            SymbolKind::Type(ty) => Some(ty),
            _ => None,
        },
        None => None,
    };

    if let Some(enum_ty) = enum_ty {
        if let TypeKind::Enum { names, .. } = ctx.types.get(enum_ty) {
            for member_name in names.clone() {
                if let Some(sym) = ctx.scopes.get_mut(scope).get_mut(&member_name) {
                    sym.exported = true;
                }
            }
        }
    }
}

/// Note a declared name in `seen`, raising a duplicate diagnostic the second
/// time a name appears in the same declaration block.
fn note_decl_name(ctx: &mut Ctx, seen: &mut HashMap<String, ()>, name: &str, span: Span) {
    if seen.insert(name.to_string(), ()).is_some() {
        ctx.error(span, format!("'{name}' is already declared in this scope"));
    }
}

/// Within a single RECORD, every field name must be unique — across the fixed
/// fields, the variant tag, and every variant arm (they are all fields of the
/// same record). Recurses into nested inline records.
fn check_record_dup_fields(ctx: &mut Ctx, te: &ast::TypeExpr) {
    fn collect(ctx: &mut Ctx, seen: &mut HashMap<String, ()>, fields: &[ast::RecordField]) {
        for f in fields {
            for n in &f.names {
                note_decl_name(ctx, seen, n, f.span);
            }
            // A field whose type is itself an inline record has its own scope.
            check_record_dup_fields(ctx, &f.ty);
        }
    }
    fn collect_variant(ctx: &mut Ctx, seen: &mut HashMap<String, ()>, vp: &ast::VariantPart) {
        if let Some(tag) = &vp.tag_name {
            note_decl_name(ctx, seen, tag, vp.span);
        }
        for arm in &vp.arms {
            collect(ctx, seen, &arm.fields);
            if let Some(inner) = &arm.variant {
                collect_variant(ctx, seen, inner);
            }
        }
        if let Some(else_fields) = &vp.else_arm {
            collect(ctx, seen, else_fields);
        }
    }
    match te {
        ast::TypeExpr::Record(rec) => {
            let mut seen: HashMap<String, ()> = HashMap::new();
            collect(ctx, &mut seen, &rec.fields);
            if let Some(vp) = &rec.variant {
                collect_variant(ctx, &mut seen, vp);
            }
        }
        ast::TypeExpr::Array(_, elem, _)
        | ast::TypeExpr::OpenArray(elem, _)
        | ast::TypeExpr::Pointer(elem, _) => check_record_dup_fields(ctx, elem),
        ast::TypeExpr::Set { element, .. } => check_record_dup_fields(ctx, element),
        _ => {}
    }
}

/// Reject a name declared more than once in the same declaration block — a
/// duplicate CONST/TYPE/VAR/enum-member/procedure (dupconst, dupvar, duptype,
/// dupenum), or a duplicate RECORD field (dupfield). Recurses into procedure
/// bodies and local modules, each of which forms its own scope.
fn check_duplicate_decls(ctx: &mut Ctx, decls: &[ast::Decl]) {
    let mut seen: HashMap<String, ()> = HashMap::new();
    for d in decls {
        match d {
            ast::Decl::Const(c) => note_decl_name(ctx, &mut seen, &c.name, c.span),
            ast::Decl::Type(t) => {
                note_decl_name(ctx, &mut seen, &t.name, t.span);
                if let Some(te) = &t.def {
                    // Enumeration members live in the enclosing scope, so they
                    // collide with each other and with other declared names.
                    if let ast::TypeExpr::Enum(members, _, espan) = te {
                        for m in members {
                            note_decl_name(ctx, &mut seen, m, *espan);
                        }
                    }
                    check_record_dup_fields(ctx, te);
                }
            }
            ast::Decl::Var(v) => {
                for n in &v.names {
                    note_decl_name(ctx, &mut seen, n, v.span);
                }
            }
            ast::Decl::Procedure(p) => {
                // A FORWARD header and its later definition share a name
                // legitimately; only count the real definition.
                if !p.is_forward {
                    note_decl_name(ctx, &mut seen, &p.name, p.span);
                }
                if let Some(body) = &p.body {
                    check_duplicate_decls(ctx, &body.decls);
                }
            }
            ast::Decl::Class(c) => note_decl_name(ctx, &mut seen, &c.name, c.span),
            ast::Decl::LocalModule(m) => check_duplicate_decls(ctx, &m.decls),
            _ => {}
        }
    }
}

/// Add all imported names to `scope`.
///
/// `enclosing` is `Some` for a *local* module (`MODULE m; IMPORT x; … END m`
/// nested inside a procedure or module): a bare `IMPORT x` there imports `x`
/// from the enclosing scope (a surrounding variable, type, procedure or
/// module), not from a separate compilation unit.
fn bring_in_imports(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    _mid: ModuleId,
    imports: &[ast::Import],
    scope: ScopeId,
    enclosing: Option<ScopeId>,
) {
    // Names explicitly imported in this import list, to reject importing the
    // same name twice (`FROM M IMPORT bar ; FROM M IMPORT bar`). Scoped to a
    // single call so a DEF and its IMPL importing the same name (separate
    // calls into the shared scope) are not cross-flagged.
    let mut seen_imports: std::collections::HashMap<String, Span> = std::collections::HashMap::new();
    for imp in imports {
        match imp {
            ast::Import::From { module, names, span } => {
                let mod_scope = find_module_scope(ctx, graph, module, *span);
                let from_mid = graph.lookup(module);
                if names.is_empty() {
                    // Wildcard import: `FROM Mod IMPORT *` — bring in every
                    // exported symbol from the module.
                    if let Some(s) = mod_scope {
                        let exported_base: Vec<Symbol> = ctx.scopes.get(s).iter()
                            .filter(|sym| sym.exported)
                            .cloned()
                            .collect();
                        let exported: Vec<Symbol> = exported_base.into_iter()
                            .map(|sym| match from_mid {
                                Some(mid) => sym.imported_from(
                                    mid,
                                    module,
                                    *span,
                                    ctx.fresh_binding_id(),
                                ),
                                None => sym,
                            })
                            .collect();
                        for sym in exported {
                            ctx.scopes.get_mut(scope).insert(sym);
                        }
                    }
                } else {
                    for name in names {
                        if seen_imports.insert(name.clone(), *span).is_some() {
                            ctx.error(*span, format!("'{name}' is imported more than once"));
                        }
                        let imported = mod_scope
                            .and_then(|s| ctx.scopes.lookup(s, name))
                            .filter(|s| s.exported)
                            .cloned()
                            .map(|sym| match from_mid {
                                Some(mid) => sym.imported_from(
                                    mid,
                                    module,
                                    *span,
                                    ctx.fresh_binding_id(),
                                ),
                                None => sym,
                            });
                        if let Some(sym) = imported {
                            // Importing an enumeration *type* also makes its
                            // member constants visible, as the ISO spec
                            // requires: `FROM
                            // ChanConsts IMPORT OpenResults` brings in `opened`,
                            // `wrongNameFormat`, … without listing each.
                            let enum_tid = match sym.kind {
                                SymbolKind::Type(tid)
                                    if matches!(ctx.types.get(tid), TypeKind::Enum { .. }) =>
                                {
                                    Some(tid)
                                }
                                _ => None,
                            };
                            ctx.scopes.get_mut(scope).insert(sym);
                            if let (Some(tid), Some(src)) = (enum_tid, mod_scope) {
                                let raw: Vec<Symbol> = ctx
                                    .scopes
                                    .get(src)
                                    .iter()
                                    .filter(|m| {
                                        m.exported
                                            && matches!(&m.kind,
                                                SymbolKind::EnumMember { ty, .. } if *ty == tid)
                                    })
                                    .cloned()
                                    .collect();
                                for m in raw {
                                    let member = match from_mid {
                                        Some(mid) => m.imported_from(
                                            mid,
                                            module,
                                            *span,
                                            ctx.fresh_binding_id(),
                                        ),
                                        None => m,
                                    };
                                    ctx.scopes.get_mut(scope).insert(member);
                                }
                            }
                        } else if mod_scope.is_some() {
                            // Name not exported from the module — emit a diagnostic
                            // if the module was found; skip if the module itself
                            // wasn't resolved (already reported).
                            ctx.error(
                                *span,
                                format!("'{name}' is not exported from module '{module}'"),
                            );
                        }
                    }
                }
            }
            ast::Import::Plain { names, span } => {
                for imp_name in names {
                    // `IMPORT local := Real` aliases module `Real` under `local`.
                    // The real module is the alias target (or the name itself
                    // when unaliased); the bound symbol uses the local name.
                    let real_module = imp_name.alias.as_ref().unwrap_or(&imp_name.name);
                    let local_name = &imp_name.name;
                    let mod_scope = find_module_scope(ctx, graph, real_module, imp_name.span);
                    if let Some(s) = mod_scope {
                        // Bind the local name as a Module symbol so qualified
                        // `local.x` lookup resolves to the real module.
                        if let Some(mid2) = graph.lookup(real_module) {
                            let declaration_id = ctx.fresh_declaration_id();
                            let binding_id = ctx.fresh_binding_id();
                            ctx.scopes.get_mut(scope).insert(Symbol {
                                name: local_name.clone(),
                                kind: SymbolKind::Module(mid2, s),
                                span: imp_name.span,
                                declaration_id,
                                binding_id,
                                provenance: SymbolProvenance::Imported {
                                    from_module: mid2,
                                    from_module_name: real_module.clone(),
                                    original_module: Some(mid2),
                                    original_module_name: Some(real_module.clone()),
                                    original_name: real_module.clone(),
                                    import_span: imp_name.span,
                                    import_chain: vec![ImportProvenanceHop {
                                        from_module: mid2,
                                        from_module_name: real_module.clone(),
                                        import_span: imp_name.span,
                                    }],
                                },
                                exported: false,
                            });
                        }
                    } else if let Some(enc) = enclosing
                        && imp_name.alias.is_none()
                        && let Some(sym) = ctx.scopes.lookup(enc, local_name).cloned()
                    {
                        // Local-module import: bring the name in from the
                        // enclosing scope (a surrounding var/type/proc/module).
                        ctx.scopes.get_mut(scope).insert(sym);
                    } else {
                        ctx.error(
                            *span,
                            format!("module '{}' not found", real_module),
                        );
                    }
                }
            }
        }
    }
}

/// Find the scope of a module by name, returning `None` if not found
/// (already diagnosed).
fn find_module_scope(
    ctx: &Ctx,
    graph: &ModuleGraph,
    name: &str,
    span: Span,
) -> Option<ScopeId> {
    let _ = span; // span used only if we emit an error, which we do below
    if let Some(mid) = graph.lookup(name) {
        if let Some(&sid) = ctx.module_scopes.get(&mid) {
            return Some(sid);
        }
    }
    None
}

// ---- Pass 1: register names with placeholder types -----------------------

fn pass1_decl(ctx: &mut Ctx, decl: &ast::Decl, scope: ScopeId) {
    match decl {
        ast::Decl::Const(c) => {
            // We'll fill the value in pass 2; insert a placeholder.
            let ty = ctx.types.builtin(Builtin::Integer); // refined in pass2
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: c.name.clone(),
                kind: SymbolKind::Const { ty, value: ConstValue::Int(0) },
                span: c.span,
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Declared {
                    module: ctx.current_module,
                    module_name: ctx.current_module_name.clone(),
                },
                exported: c.exported,
            });
        }
        ast::Decl::Type(t) => {
            let type_id = ctx.types.alloc_unresolved();
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: t.name.clone(),
                kind: SymbolKind::Type(type_id),
                span: t.span,
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Declared {
                    module: ctx.current_module,
                    module_name: ctx.current_module_name.clone(),
                },
                exported: t.exported,
            });
            if let Some(ast::TypeExpr::Enum(names, values, _)) = &t.def {
                let ords = enum_member_ordinals(ctx, scope, names, values);
                for (i, member_name) in names.iter().enumerate() {
                    let declaration_id = ctx.fresh_declaration_id();
                    let binding_id = ctx.fresh_binding_id();
                    ctx.scopes.get_mut(scope).insert(Symbol {
                        name: member_name.clone(),
                        kind: SymbolKind::EnumMember {
                            ty: type_id,
                            ord: ords[i],
                        },
                        span: t.span,
                        declaration_id,
                        binding_id,
                        provenance: SymbolProvenance::Declared {
                            module: ctx.current_module,
                            module_name: ctx.current_module_name.clone(),
                        },
                        exported: t.exported,
                    });
                }
            }
        }
        ast::Decl::Var(v) => {
            let type_id = ctx.types.alloc_unresolved();
            for name in &v.names {
                let declaration_id = ctx.fresh_declaration_id();
                let binding_id = ctx.fresh_binding_id();
                ctx.scopes.get_mut(scope).insert(Symbol {
                    name: name.clone(),
                    kind: SymbolKind::Var {
                        ty: type_id,
                        param_mode: None,
                    },
                    span: v.span,
                    declaration_id,
                    binding_id,
                    provenance: SymbolProvenance::Declared {
                        module: ctx.current_module,
                        module_name: ctx.current_module_name.clone(),
                    },
                    exported: v.exported,
                });
            }
        }
        ast::Decl::Procedure(p) => {
            // Placeholder: signature resolved in pass 2.
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: p.name.clone(),
                kind: SymbolKind::Proc(ProcSig {
                    params: vec![],
                    return_ty: None,
                    calling_conv: CallingConv::Default,
                    attrs: vec![],
                    external_linkage: None,
                }),
                span: p.span,
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Declared {
                    module: ctx.current_module,
                    module_name: ctx.current_module_name.clone(),
                },
                exported: p.exported,
            });
        }
        ast::Decl::Class(cd) => {
            let type_id = ctx.types.alloc_unresolved();
            let cid = ctx.classes.alloc(cd.name.clone(), cd.is_abstract, type_id, cd.span);
            // Patch the TypeId to Class kind.
            ctx.types.set(type_id, TypeKind::Class { symbol: cid.0 });
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: cd.name.clone(),
                kind: SymbolKind::Class(cid),
                span: cd.span,
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Declared {
                    module: ctx.current_module,
                    module_name: ctx.current_module_name.clone(),
                },
                exported: cd.exported,
            });
        }
        ast::Decl::LocalModule(m) => {
            let local_scope = ctx.scopes.push(ScopeKind::LocalModule, Some(scope));
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(scope).insert(Symbol {
                name: m.name.clone(),
                kind: SymbolKind::Module(ctx.current_module, local_scope),
                span: m.span,
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Declared {
                    module: ctx.current_module,
                    module_name: ctx.current_module_name.clone(),
                },
                exported: false,
            });
            for decl in &m.decls {
                pass1_decl(ctx, decl, local_scope);
            }
        }
        ast::Decl::Pragma(_) | ast::Decl::Export { .. } => {
            // Pragmas and exports are processed in pass 2 or not at all.
        }
    }
}

// ---- Pass 2: resolve types, evaluate constants, form signatures ----------

fn pass2_decl(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    decl: &ast::Decl,
    scope: ScopeId,
    analyse_bodies: bool,
) {
    match decl {
        ast::Decl::Const(c) => {
            let (ty, value) = eval_const_decl(ctx, scope, &c.value, c.span);
            // Keep the per-scope const cache current so a later CONST in this
            // scope that references this one sees its real value (the symbol
            // count is unchanged, so the cache is otherwise reused as-is).
            if let Some((_, map)) = ctx.const_cache.get_mut(&scope) {
                map.insert(c.name.clone(), value.clone());
            }
            if let Some(sym) = ctx.scopes.get_mut(scope).get_mut(&c.name) {
                sym.kind = SymbolKind::Const { ty, value };
            }
        }
        ast::Decl::Type(t) => {
            let type_id = match ctx.scopes.get(scope).get(&t.name) {
                Some(sym) => match sym.kind {
                    SymbolKind::Type(id) => id,
                    _ => return,
                },
                None => return,
            };
            match &t.def {
                None => {
                    // Opaque type (DEF-only `TYPE T;`): leave as Unresolved.
                    // This is legal in a DEFINITION MODULE.
                }
                Some(te) => {
                    let resolved = form_type_expr(ctx, graph, mid, te, scope);
                    ctx.types.set(type_id, ctx.types.get(resolved).clone());
                }
            }
            // Register enumeration members into scope if it resolved to an Enum.
            if let TypeKind::Enum { names, values, .. } = ctx.types.get(type_id).clone() {
                for (i, member_name) in names.iter().enumerate() {
                    let declaration_id = ctx.fresh_declaration_id();
                    let binding_id = ctx.fresh_binding_id();
                    ctx.scopes.get_mut(scope).insert(Symbol {
                        name: member_name.clone(),
                        kind: SymbolKind::EnumMember {
                            ty: type_id,
                            ord: values[i],
                        },
                        span: t.span,
                        declaration_id,
                        binding_id,
                        provenance: SymbolProvenance::Declared {
                            module: ctx.current_module,
                            module_name: ctx.current_module_name.clone(),
                        },
                        exported: t.exported,
                    });
                }
            }
        }
        ast::Decl::Var(v) => {
            let resolved = form_type_expr(ctx, graph, mid, &v.ty, scope);
            // Back-patch all the var symbols with the resolved type.
            for name in &v.names {
                if let Some(sym) = ctx.scopes.get_mut(scope).get_mut(name) {
                    sym.kind = SymbolKind::Var {
                        ty: resolved,
                        param_mode: None,
                    };
                }
            }
        }
        ast::Decl::Procedure(p) => {
            let sig = form_proc_sig(ctx, graph, mid, p, scope);
            // A FORWARD declaration's signature must match its later definition.
            if p.is_forward {
                ctx.forward_proc_sigs
                    .insert((scope, p.name.clone()), sig.clone());
            } else if let Some(fwd) =
                ctx.forward_proc_sigs.get(&(scope, p.name.clone())).cloned()
                && !proc_sigs_match(&fwd, &sig)
            {
                ctx.error(
                    p.span,
                    "procedure definition does not match its FORWARD declaration",
                );
            }
            if let Some(sym) = ctx.scopes.get_mut(scope).get_mut(&p.name) {
                sym.kind = SymbolKind::Proc(sig.clone());
            }

            // Analyse the procedure body (if present) in its own scope — only
            // in the body phase, so that all module interfaces are registered
            // first (lets mutually-importing modules resolve each other).
            if analyse_bodies && let Some(body) = &p.body {
                analyse_proc_body(ctx, graph, mid, p, body, scope, &sig);
            }
        }
        ast::Decl::Class(cd) => {
            resolve_class_decl(ctx, graph, mid, cd, scope);
        }
        ast::Decl::Pragma(pr) => {
            check_pragma_known(ctx, pr);
        }
        ast::Decl::LocalModule(m) => {
            let local_scope = match ctx.scopes.get(scope).get(&m.name) {
                Some(sym) => match sym.kind {
                    SymbolKind::Module(_, sid) => sid,
                    _ => return,
                },
                None => return,
            };
            bring_in_imports(ctx, graph, mid, &m.imports, local_scope, Some(scope));
            for decl in &m.decls {
                pass2_decl(ctx, graph, mid, decl, local_scope, analyse_bodies);
            }
            resolve_classes_in_scope(ctx, local_scope);
            // EXPORT: a local module's exported names become visible in the
            // enclosing scope (ISO local module). Qualified access `Inner.name`
            // works via the module symbol regardless; unqualified EXPORT also
            // injects the name directly.
            for decl in &m.decls {
                if let ast::Decl::Export { names, .. } = decl {
                    for name in names {
                        // If the exported name is an enumeration type, mark its
                        // members exported in the local module's OWN scope, so a
                        // qualified `Inner.member` folds to its ordinal in a
                        // constant expression (collect_scope_consts surfaces only
                        // exported enum members of a module). A top-level module's
                        // exports already do this via apply_def_exports; a local
                        // module's EXPORT statement did not.
                        mark_enum_members_exported(ctx, local_scope, name);
                        if let Some(sym) = ctx.scopes.get(local_scope).get(name).cloned() {
                            ctx.scopes.get_mut(scope).insert(sym);
                        }
                    }
                }
            }
            if analyse_bodies && let Some(body) = &m.body {
                analyse_block(ctx, graph, mid, body, local_scope, None);
            }
        }
        ast::Decl::Export { .. } => {
            // Export handling is applied from the owning DEF/MOD pair.
        }
    }
}

// ---- Constant declaration evaluation -------------------------------------

/// Read-only, diagnostic-free resolution of a designator that names a type
/// (possibly module-qualified). Used while pre-computing type-builtins for
/// constant folding, where the normal `resolve_*` helpers' error reporting
/// and resolution notes would duplicate the main analysis pass.
/// Read-only resolution of a designator that names a *value* (a variable,
/// constant or enumeration member), returning its type. Used so `MIN(v)` /
/// `MAX(v)` / `SIZE(v)` can be pre-folded from the operand's type.
fn quiet_value_type(ctx: &Ctx, arg: &ast::Expr, scope: ScopeId) -> Option<TypeId> {
    let ast::Expr::Designator(d) = arg else {
        return None;
    };
    if !d.selectors.is_empty() || d.base.segments.len() != 1 {
        return None;
    }
    match ctx.scopes.lookup(scope, &d.base.segments[0])?.kind {
        SymbolKind::Var { ty, .. }
        | SymbolKind::Const { ty, .. }
        | SymbolKind::EnumMember { ty, .. } => Some(ty),
        _ => None,
    }
}

fn quiet_type_arg(ctx: &Ctx, arg: &ast::Expr, scope: ScopeId) -> Option<TypeId> {
    let ast::Expr::Designator(d) = arg else {
        return None;
    };
    let mut sym = ctx.scopes.lookup(scope, d.base.segments.first()?).cloned()?;
    let descend = |sym: &mut Symbol, seg: &str| -> Option<()> {
        let SymbolKind::Module(_, ms) = sym.kind else {
            return None;
        };
        *sym = ctx.scopes.get(ms).get(seg).cloned()?;
        Some(())
    };
    for seg in d.base.segments.iter().skip(1) {
        descend(&mut sym, seg)?;
    }
    for sel in &d.selectors {
        let ast::Selector::Field(name, _) = sel else {
            return None;
        };
        descend(&mut sym, name)?;
    }
    match sym.kind {
        SymbolKind::Type(ty) => Some(ty),
        SymbolKind::Class(cid) => Some(ctx.classes.get(cid).type_id),
        _ => None,
    }
}

/// Bytes occupied by a value of `ty` (matching codegen's layout choices).
/// `None` for kinds whose size is alignment-sensitive or unsupported here
/// (records), so the caller falls back to the 0 placeholder.
fn type_size_bytes(ctx: &Ctx, ty: TypeId) -> Option<i128> {
    match ctx.types.get(ty) {
        TypeKind::Builtin(b) => builtin_size_bytes(*b),
        TypeKind::Subrange { host, .. } => type_size_bytes(ctx, *host),
        TypeKind::Enum { .. } => Some(4), // enums lower to i32 in codegen
        TypeKind::Pointer { .. } | TypeKind::Proc { .. } => Some(8),
        TypeKind::Set { .. } => Some(32), // 256-bit set representation
        TypeKind::Array { indices, base } => {
            let base_sz = type_size_bytes(ctx, *base)?;
            let mut count: i128 = 1;
            for idx in indices {
                count = count.checked_mul(ordinal_count(ctx, *idx)?)?;
            }
            count.checked_mul(base_sz)
        }
        TypeKind::Vector { lanes, base } => {
            type_size_bytes(ctx, *base)?.checked_mul(*lanes as i128)
        }
        _ => None,
    }
}

/// Number of distinct values of an ordinal index/host type.
fn ordinal_count(ctx: &Ctx, ty: TypeId) -> Option<i128> {
    ctx.types.ordinal_cardinality(ty)
}

/// Inclusive `(MIN, MAX)` ordinal bounds of `ty`, or `None` for non-ordinals.
/// Delegates to the shared `TypeArena` helper (the single source of truth).
fn type_ordinal_bounds(ctx: &Ctx, ty: TypeId) -> Option<(i128, i128)> {
    ctx.types.ordinal_bounds(ty)
}

/// Byte size for a built-in scalar, matching codegen's `builtin_type`.
fn builtin_size_bytes(b: Builtin) -> Option<i128> {
    use Builtin::*;
    Some(match b {
        Boolean | Byte | SysByte | SysLoc | Achar | Integer8 | Cardinal8 => 1,
        Char | Uchar | Integer16 | Cardinal16 | Word | Real16 => 2,
        Integer32 | Cardinal32 | Dword | Real32 => 4,
        Integer | Cardinal | Integer64 | Cardinal64 | Qword | LongInt | LongCard | Real
        | LongReal | SysWord | Address | SysAddress | Adrint | Adrcard | Nil | Proc => 8,
        Complex | LongComplex => 16,
        Bitset | SysBitset => 32,
    })
}

/// Compute `MAX`/`MIN`/`SIZE`/`TSIZE` of a resolved type, for constant folding.
fn type_builtin_value(ctx: &Ctx, op: &str, ty: TypeId) -> Option<i128> {
    match op {
        "MAX" => type_ordinal_bounds(ctx, ty).map(|(_, hi)| hi),
        "MIN" => type_ordinal_bounds(ctx, ty).map(|(lo, _)| lo),
        "SIZE" | "TSIZE" => type_size_bytes(ctx, ty),
        "TBITSIZE" => type_size_bytes(ctx, ty).map(|b| b * 8),
        _ => None,
    }
}

/// Walk a constant expression and pre-compute every `MAX`/`MIN`/`SIZE`/`TSIZE`
/// applied to a named type, inserting the result into `consts` under the
/// synthetic key the constant evaluator looks up. This is how the type system
/// (only available here) reaches `constant.rs`, which has none.
fn prefill_type_builtins(
    ctx: &Ctx,
    scope: ScopeId,
    expr: &ast::Expr,
    consts: &mut HashMap<String, ConstValue>,
) {
    match expr {
        ast::Expr::Call(func, args, _) => {
            if let ast::Expr::Designator(d) = func.as_ref() {
                if d.selectors.is_empty() && d.base.segments.len() == 1 {
                    let op = d.base.segments[0].as_str();
                    if matches!(op, "MAX" | "MIN" | "SIZE" | "TSIZE" | "TBITSIZE") && args.len() == 1 {
                        if let Some(key) = crate::constant::type_builtin_key(op, &args[0]) {
                            // `MIN(v)` / `MAX(v)` / `SIZE(v)` accept a variable —
                            // fall back to the operand's type when the argument
                            // does not name a type directly.
                            if let Some(ty) = quiet_type_arg(ctx, &args[0], scope)
                                .or_else(|| quiet_value_type(ctx, &args[0], scope))
                            {
                                // MAX/MIN of a real type is a real extreme, not
                                // an ordinal bound; narrow reals have narrower
                                // extremes (f32, and f16's ~65504).
                                if matches!(op, "MAX" | "MIN")
                                    && is_real_type(ctx, ty)
                                {
                                    let v = match (op, ctx.types.get(ty)) {
                                        ("MAX", TypeKind::Builtin(Builtin::Real32)) => f32::MAX as f64,
                                        ("MIN", TypeKind::Builtin(Builtin::Real32)) => f32::MIN as f64,
                                        ("MAX", TypeKind::Builtin(Builtin::Real16)) => 65504.0,
                                        ("MIN", TypeKind::Builtin(Builtin::Real16)) => -65504.0,
                                        ("MAX", _) => f64::MAX,
                                        _ => f64::MIN,
                                    };
                                    consts.entry(key).or_insert(ConstValue::Real(v));
                                } else if let Some(v) = type_builtin_value(ctx, op, ty) {
                                    consts.entry(key).or_insert(ConstValue::Int(v));
                                }
                            }
                        }
                    } else if args.len() == 1
                        && let Some(ty) = quiet_type_arg(ctx, func.as_ref(), scope)
                        && matches!(
                            ctx.types.get(ty),
                            TypeKind::Subrange { .. } | TypeKind::Enum { .. }
                        )
                        && let Some((lo, hi)) = type_ordinal_bounds(ctx, ty)
                    {
                        // `T(x)` where T is a *resolved* user ordinal type
                        // (subrange/enumeration) is a value conversion: mark T
                        // as a type so the evaluator folds it to x, and supply
                        // T's range so the evaluator can reject an out-of-range
                        // constant conversion. We restrict to types whose bounds
                        // are resolved here — a forward-referenced type has none
                        // yet, so its conversion stays "not constant" (rejected)
                        // rather than folding unchecked. Builtin conversions
                        // (e.g. `CARDINAL(x)`) are left alone to avoid masking
                        // later type-compatibility checks.
                        consts
                            .entry(crate::constant::type_conv_key(op))
                            .or_insert(ConstValue::Int(1));
                        consts
                            .entry(crate::constant::type_conv_lo_key(op))
                            .or_insert(ConstValue::Int(lo));
                        consts
                            .entry(crate::constant::type_conv_hi_key(op))
                            .or_insert(ConstValue::Int(hi));
                    }
                }
            }
            prefill_type_builtins(ctx, scope, func, consts);
            for a in args {
                prefill_type_builtins(ctx, scope, a, consts);
            }
        }
        ast::Expr::Binary(_, l, r, _) => {
            prefill_type_builtins(ctx, scope, l, consts);
            prefill_type_builtins(ctx, scope, r, consts);
        }
        ast::Expr::Unary(_, e, _) => prefill_type_builtins(ctx, scope, e, consts),
        ast::Expr::Set { elements, .. } => {
            for el in elements {
                match el {
                    ast::SetElem::Single(e) => prefill_type_builtins(ctx, scope, e, consts),
                    ast::SetElem::Range(a, b) => {
                        prefill_type_builtins(ctx, scope, a, consts);
                        prefill_type_builtins(ctx, scope, b, consts);
                    }
                }
            }
        }
        _ => {}
    }
}

/// Compute each enumeration member's ordinal. A member with an explicit value
/// `(name = expr)` takes that constant; otherwise it takes the previous
/// ordinal + 1 (dense/C/ADW semantics). Earlier members are visible to later
/// explicit values (`(a = 1, b = a + 4)`). A value that cannot be folded
/// degrades gracefully to the sequential ordinal.
fn enum_member_ordinals(
    ctx: &Ctx,
    scope: ScopeId,
    names: &[String],
    values: &[Option<ast::Expr>],
) -> Vec<i128> {
    let mut consts = collect_scope_consts(ctx, scope);
    let mut ords = Vec::with_capacity(names.len());
    let mut next: i128 = 0;
    for (i, name) in names.iter().enumerate() {
        let ord = match values.get(i).and_then(|v| v.as_ref()) {
            Some(e) => {
                prefill_type_builtins(ctx, scope, e, &mut consts);
                let lookup = |n: &str| consts.get(n).cloned();
                eval_const(e, &lookup).ok().and_then(|v| v.as_int()).unwrap_or(next)
            }
            None => next,
        };
        ords.push(ord);
        // Make this member visible to later members' explicit value exprs.
        consts.insert(name.clone(), ConstValue::Int(ord));
        next = ord.saturating_add(1);
    }
    ords
}

/// Re-fold CONST aggregate constructors (`c = T{...}` for a RECORD/ARRAY `T`)
/// after every TYPE in the block is resolved. A constant that references a type
/// declared *later* in the same block cannot fold during the source-order
/// pass-2 (its target type is still unresolved, so it falls through to the set
/// path and gets the wrong type); this re-runs the evaluation now that the type
/// is available. Idempotent for constants that already folded correctly.
fn reeval_aggregate_consts(ctx: &mut Ctx, decls: &[ast::Decl], scope: ScopeId) {
    // A constant whose value is anything other than a plain literal may
    // reference a constant declared *later* in the same scope (a forward const
    // reference, which the ISO spec allows). Its first evaluation in pass 2 saw a
    // placeholder for that constant. Re-evaluate the non-literal constants to a
    // fixpoint so a *chain* of forward references (`a = b; b = c; c = 1`)
    // resolves, not just a single hop. Plain literals never change, so they are
    // skipped.
    let targets: Vec<(String, &ast::Expr, Span)> = decls
        .iter()
        .filter_map(|d| match d {
            ast::Decl::Const(c)
                if !matches!(
                    &c.value,
                    ast::Expr::Integer(..)
                        | ast::Expr::Real(..)
                        | ast::Expr::Char(..)
                        | ast::Expr::String(..)
                        | ast::Expr::Nil(..)
                ) =>
            {
                Some((c.name.clone(), &c.value, c.span))
            }
            _ => None,
        })
        .collect();
    if targets.is_empty() {
        return;
    }
    // A value can advance at most one hop per pass, so `len + 1` passes suffice
    // to resolve any acyclic chain; a cyclic reference simply converges to its
    // placeholder (no hang). Errors are suppressed here — any genuine const
    // error was already reported once in pass 2, and re-evaluation only ever
    // improves a value, so re-reporting would just duplicate diagnostics.
    let cap = targets.len() + 1;
    for _ in 0..cap {
        let mut changed = false;
        for (name, expr, span) in &targets {
            let diag_mark = ctx.diagnostics.len();
            let (ty, value) = eval_const_decl(ctx, scope, expr, *span);
            ctx.diagnostics.truncate(diag_mark);
            let current = ctx.scopes.get(scope).get(name).and_then(|s| match &s.kind {
                SymbolKind::Const { value, .. } => Some(value.clone()),
                _ => None,
            });
            if current.as_ref() != Some(&value) {
                changed = true;
                if let Some((_, map)) = ctx.const_cache.get_mut(&scope) {
                    map.insert(name.clone(), value.clone());
                }
                if let Some(sym) = ctx.scopes.get_mut(scope).get_mut(name) {
                    sym.kind = SymbolKind::Const { ty, value };
                }
            }
        }
        if !changed {
            break;
        }
    }
}

/// Is `func` the callee of a bit/value transfer cast — `CAST`, `VAL`, or the
/// qualified `SYSTEM.CAST` / `SYSTEM.VAL` — whose first argument names the
/// result type? Used so a CONST initialised by such a cast carries the cast's
/// target type rather than the value-derived type.
fn is_transfer_cast_callee(func: &ast::Expr) -> bool {
    let ast::Expr::Designator(d) = func else {
        return false;
    };
    if !d.selectors.is_empty() {
        return false;
    }
    match d.base.segments.as_slice() {
        [name] => name.eq_ignore_ascii_case("CAST") || name.eq_ignore_ascii_case("VAL"),
        [module, name] => {
            module.eq_ignore_ascii_case("SYSTEM")
                && (name.eq_ignore_ascii_case("CAST") || name.eq_ignore_ascii_case("VAL"))
        }
        _ => false,
    }
}

fn eval_const_decl(
    ctx: &mut Ctx,
    scope: ScopeId,
    expr: &ast::Expr,
    _span: Span,
) -> (TypeId, ConstValue) {
    // Build a lookup map from the current scope chain. Rebuilding it for every
    // CONST is O(n²) on large modules (Win32 namespaces have 10k+ consts), so
    // reuse a per-scope cache while the symbol set is unchanged. The caller
    // (pass2 CONST) patches the just-evaluated constant's value back into the
    // cache so later consts in the same scope see it.
    let cur_count = ctx.scopes.get(scope).symbol_count();
    let mut consts = match ctx.const_cache.remove(&scope) {
        Some((count, map)) if count == cur_count => map,
        _ => collect_scope_consts(ctx, scope),
    };
    // Resolve type-dependent builtins (MAX/MIN/SIZE/TSIZE) up front, since the
    // constant evaluator has no access to the type system.
    prefill_type_builtins(ctx, scope, expr, &mut consts);

    // `T{...}` where T is a RECORD or ARRAY is a structured constructor, not a
    // set: evaluate it as an aggregate constant typed as T. (A set type `T`
    // falls through to the ordinary set-constructor path below.)
    let out: (TypeId, ConstValue) = 'compute: {
        if let ast::Expr::Set { type_name: Some(qn), .. } = expr {
            let target = resolve_type_name(ctx, qn, scope);
            if matches!(ctx.types.get(target), TypeKind::Record(_) | TypeKind::Array { .. })
                && let Some(val) = eval_aggregate_const(ctx, scope, expr, target, &consts)
            {
                break 'compute (target, val);
            }
        }

        let lookup = |name: &str| consts.get(name).cloned();
        match eval_const(expr, &lookup) {
            Ok(val) => {
                let ty = match expr {
                    ast::Expr::Set { type_name, .. } => {
                        // `T{...}` where T is a named SET type IS that type (e.g.
                        // `CONST write = FlagSet{...}` has type FlagSet) — mirror
                        // analyse_expr; only wrap a non-set element type.
                        match type_name.as_ref().map(|name| resolve_type_name(ctx, name, scope)) {
                            Some(t) if matches!(ctx.types.get(t), TypeKind::Set { .. }) => t,
                            Some(base) => ctx.types.alloc(TypeKind::Set { packed: false, base }),
                            None => {
                                let base = ctx.types.builtin(Builtin::Integer);
                                ctx.types.alloc(TypeKind::Set { packed: false, base })
                            }
                        }
                    }
                    // `c2 = c1` — a constant that aliases another constant inherits
                    // its declared type, so an aggregate (array/record) alias stays
                    // that type instead of the value-derived placeholder.
                    ast::Expr::Designator(d)
                        if d.selectors.is_empty()
                            && d.base.segments.len() == 1
                            && matches!(val, ConstValue::Aggregate(_)) =>
                    {
                        match ctx.scopes.lookup(scope, &d.base.segments[0]).map(|s| &s.kind) {
                            Some(SymbolKind::Const { ty, .. }) => *ty,
                            _ => const_type(ctx, &val),
                        }
                    }
                    // `CAST(T, x)` / `VAL(T, x)` / `SYSTEM.CAST(T, x)` in a CONST
                    // initializer: the constant's type is the TARGET type T, not
                    // the value-derived type. The folder returns x's value/bits
                    // (an Int for a hex bit-pattern), so without this a
                    // `CONST Inf = CAST(REAL, 07FF0000000000000H)` would be typed
                    // INTEGER and fail to assign to a REAL. Mirrors the non-const
                    // path (analyse builtin VAL/CAST → `Some(target_ty)`).
                    ast::Expr::Call(func, call_args, _)
                        if call_args.len() == 2 && is_transfer_cast_callee(func) =>
                    {
                        resolve_builtin_type_arg(ctx, &call_args[0], scope, false)
                            .unwrap_or_else(|| const_type(ctx, &val))
                    }
                    _ => const_type(ctx, &val),
                };
                (ty, val)
            }
            Err(e) => {
                // MAX/MIN/SIZE are type-system-dependent; evaluate them as
                // Unknown and skip the error for now.
                if e.message.contains("requires type-system context") {
                    break 'compute (ctx.types.builtin(Builtin::Integer), ConstValue::Int(0));
                }
                // If the error involves a set/ordinal context and the root
                // cause is a deferred constant, silence the secondary error.
                if e.message.contains("type mismatch in arithmetic")
                    || e.message.contains("set element must be an ordinal")
                    || e.message.contains("set range must be ordinal")
                {
                    break 'compute (ctx.types.builtin(Builtin::Bitset), ConstValue::Set(vec![]));
                }
                ctx.eval_error(e);
                (ctx.types.builtin(Builtin::Integer), ConstValue::Int(0))
            }
        }
    };
    // Restore the (possibly prefill-augmented) lookup map for the next CONST in
    // this scope; the caller patches in this constant's freshly-computed value.
    ctx.const_cache.insert(scope, (cur_count, consts));
    out
}

/// Evaluate a structured (RECORD or ARRAY) constructor `T{e0, e1, …}` into a
/// `ConstValue::Aggregate`, recursing into nested constructors. `expected` is
/// the type the constructor must produce (the resolved `type_name`, or the
/// element/field type when nested). Returns `None` if `expected` is not an
/// aggregate type or an element cannot be folded.
fn eval_aggregate_const(
    ctx: &mut Ctx,
    scope: ScopeId,
    expr: &ast::Expr,
    expected: TypeId,
    consts: &HashMap<String, ConstValue>,
) -> Option<ConstValue> {
    let ast::Expr::Set { type_name, elements, .. } = expr else {
        return None;
    };
    // The target aggregate type: an explicit `type_name`, else the expected
    // (field/element) type from the enclosing constructor.
    let target = match type_name {
        Some(qn) => resolve_type_name(ctx, qn, scope),
        None => expected,
    };
    // Per-element expected types: a record's fields in order, or an array's
    // element type repeated.
    let elem_types: Vec<TypeId> = match ctx.types.get(target) {
        TypeKind::Record(layout) => {
            layout.flatten_fields().into_iter().map(|(_, t)| t).collect()
        }
        TypeKind::Array { base, .. } => {
            let base = *base;
            elements.iter().map(|_| base).collect()
        }
        _ => return None,
    };

    // An ARRAY OF CHAR may be filled by a string element: each character
    // occupies a consecutive cell rather than the whole string occupying one.
    let char_array_base = match ctx.types.get(target) {
        TypeKind::Array { base, .. } => matches!(
            ctx.types.get(*base),
            TypeKind::Builtin(Builtin::Char | Builtin::Uchar | Builtin::Achar)
        ),
        _ => false,
    };

    let mut vals = Vec::with_capacity(elements.len());
    for (i, elem) in elements.iter().enumerate() {
        let ety = elem_types.get(i).copied().unwrap_or(target);
        let inner = match elem {
            ast::SetElem::Single(e) => e,
            // `{x BY n}` repetition in a constructor is not yet supported.
            ast::SetElem::Range(..) => return None,
        };
        // A nested aggregate (`rec{green, position{…}}`) recurses; a scalar
        // element folds through the ordinary constant evaluator.
        let v = if let Some(agg) = eval_aggregate_const(ctx, scope, inner, ety, consts) {
            agg
        } else {
            let lookup = |n: &str| consts.get(n).cloned();
            eval_const(inner, &lookup).ok()?
        };
        // Spread a (multi-character) string across consecutive CHAR cells.
        if char_array_base && let ConstValue::Str(s) = &v {
            for ch in s.chars() {
                vals.push(ConstValue::Char(ch));
            }
            continue;
        }
        vals.push(v);
    }
    Some(ConstValue::Aggregate(vals))
}

/// Collect all constant names reachable from `scope` into a HashMap
/// for use in the closure passed to `eval_const`.
/// Also inserts procedure names as FuncRef constants (for proc-alias CONSTs)
/// and qualified `Module.Name` entries for imported symbols.
/// Total element count of a *fixed* array type (product of its dimension
/// cardinalities), or `None` for an open array / non-array.
fn array_element_count(ctx: &Ctx, ty: TypeId) -> Option<i128> {
    let TypeKind::Array { indices, .. } = ctx.types.get(ty) else {
        return None;
    };
    let mut total: i128 = 1;
    for &idx in indices {
        let (lo, hi) = type_ordinal_bounds(ctx, idx)?;
        total = total.checked_mul(hi - lo + 1)?;
    }
    Some(total)
}

/// Fold `expr` to a constant ordinal value in `scope`, or `None` if it is not a
/// (foldable) compile-time constant. Used for compile-time range / label checks.
fn const_int_of(ctx: &Ctx, expr: &ast::Expr, scope: ScopeId) -> Option<i128> {
    let mut consts = collect_scope_consts(ctx, scope);
    // Pre-fold `MIN(v)`/`MAX(v)`/`SIZE(T)` etc. so they resolve to their real
    // value rather than the evaluator's 0 fallback.
    prefill_type_builtins(ctx, scope, expr, &mut consts);
    let lookup = |n: &str| consts.get(n).cloned();
    eval_const(expr, &lookup).ok().and_then(|v| v.as_int())
}

/// If `expr` folds to a constant string or character, its character data — used
/// to recognise a *constant* `+` concatenation (`"W" + "o"`, `015C + 012C`).
/// Returns `None` for any runtime operand, so a runtime char/string `+` is not
/// mistaken for concatenation (which the IR cannot lower and which sema must
/// therefore reject rather than mis-type).
fn const_string_of(ctx: &Ctx, expr: &ast::Expr, scope: ScopeId) -> Option<String> {
    let mut consts = collect_scope_consts(ctx, scope);
    prefill_type_builtins(ctx, scope, expr, &mut consts);
    let lookup = |n: &str| consts.get(n).cloned();
    match eval_const(expr, &lookup).ok()? {
        ConstValue::Str(s) => Some(s),
        ConstValue::Char(c) => Some(c.to_string()),
        _ => None,
    }
}

fn collect_scope_consts(ctx: &Ctx, scope: ScopeId) -> HashMap<String, ConstValue> {
    let mut map = HashMap::new();
    let mut cur = Some(scope);
    while let Some(sid) = cur {
        let s = ctx.scopes.get(sid);
        for sym in s.iter() {
            match &sym.kind {
                SymbolKind::Const { value, .. } => {
                    map.entry(sym.name.clone()).or_insert_with(|| value.clone());
                }
                // Enum members are ordinal constants.
                SymbolKind::EnumMember { ord, .. } => {
                    map.entry(sym.name.clone())
                        .or_insert_with(|| ConstValue::Int(*ord as i128));
                }
                // Allow procedure names to appear in CONST expressions as
                // procedure-value constants (e.g. `GetRounding = GetRoundingSSE`).
                SymbolKind::Proc(_) => {
                    map.entry(sym.name.clone())
                        .or_insert_with(|| ConstValue::FuncRef(sym.name.clone()));
                }
                // For imported module symbols, also add qualified `Module.Name` entries.
                SymbolKind::Module(_, mod_scope) => {
                    let ms = ctx.scopes.get(*mod_scope);
                    for msym in ms.iter() {
                        if msym.exported {
                            match &msym.kind {
                                SymbolKind::Const { value, .. } => {
                                    let key = format!("{}.{}", sym.name, msym.name);
                                    map.entry(key).or_insert_with(|| value.clone());
                                }
                                SymbolKind::Proc(_) => {
                                    let key = format!("{}.{}", sym.name, msym.name);
                                    map.entry(key).or_insert_with(|| ConstValue::FuncRef(msym.name.clone()));
                                }
                                SymbolKind::EnumMember { ord, .. } => {
                                    let key = format!("{}.{}", sym.name, msym.name);
                                    map.entry(key).or_insert_with(|| ConstValue::Int(*ord as i128));
                                }
                                _ => {}
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        cur = s.parent;
    }
    map
}

fn const_type(ctx: &Ctx, val: &ConstValue) -> TypeId {
    match val {
        ConstValue::Int(_) => ctx.types.builtin(Builtin::Integer),
        ConstValue::Real(_) => ctx.types.builtin(Builtin::Real),
        ConstValue::Bool(_) => ctx.types.builtin(Builtin::Boolean),
        ConstValue::Char(_) => ctx.types.builtin(Builtin::Char),
        ConstValue::Str(_) => ctx.types.builtin(Builtin::Achar),
        ConstValue::Set(_) => ctx.types.builtin(Builtin::Bitset),
        ConstValue::Nil => ctx.types.builtin(Builtin::Nil),
        ConstValue::FuncRef(_) => ctx.types.builtin(Builtin::Proc),
        ConstValue::Complex(..) => ctx.types.builtin(Builtin::Complex),
        // An aggregate's type is the record/array it constructs; that is carried
        // alongside the value (see `eval_const_decl`), so this fallback is only a
        // placeholder for the rare path that asks for a type from value alone.
        ConstValue::Aggregate(_) => ctx.types.builtin(Builtin::Integer),
    }
}

// ---- Type expression formation -------------------------------------------

/// Convert an AST `TypeExpr` into a `TypeId` in the arena.
fn form_type_expr(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    te: &ast::TypeExpr,
    scope: ScopeId,
) -> TypeId {
    match te {
        ast::TypeExpr::Named(qn) => resolve_type_name(ctx, qn, scope),
        ast::TypeExpr::Subrange(lo, hi, span) => {
            let mut consts = collect_scope_consts(ctx, scope);
            // Subrange bounds may use MAX/MIN/SIZE/TSIZE of a type, e.g.
            // `ARRAY [0..MAX(INTEGER8)] OF CHAR`; resolve those first.
            prefill_type_builtins(ctx, scope, lo, &mut consts);
            prefill_type_builtins(ctx, scope, hi, &mut consts);
            let lookup = |n: &str| consts.get(n).cloned();
            let lo_v = eval_const(lo, &lookup)
                .and_then(|v| v.as_int().ok_or(EvalError { message: "expected ordinal".into(), span: *span }));
            let hi_v = eval_const(hi, &lookup)
                .and_then(|v| v.as_int().ok_or(EvalError { message: "expected ordinal".into(), span: *span }));
            // Host type = the base type of the bounds: CHAR for `['A'..'Z']`,
            // the enumeration for `[red..blue]`, INTEGER otherwise — so the
            // subrange is laid out at the right width (i16/i32) not always i64.
            let host = {
                let bound_ty = analyse_expr(ctx, lo, scope);
                let ordinal_base = bound_ty.is_some_and(|t| {
                    matches!(
                        ctx.types.get(t),
                        TypeKind::Builtin(Builtin::Char | Builtin::Achar | Builtin::Uchar)
                            | TypeKind::Enum { .. }
                    )
                });
                if ordinal_base {
                    bound_ty.unwrap()
                } else {
                    ctx.types.builtin(Builtin::Integer)
                }
            };
            match (lo_v, hi_v) {
                (Ok(lo), Ok(hi)) => ctx.types.alloc(TypeKind::Subrange { host, lo, hi }),
                (Err(e), _) | (_, Err(e)) => {
                    // During interface construction a cross-module qualified
                    // bound (e.g. `[IOChan.notAvailable .. ...]`) may not be
                    // resolvable yet; defer the error to the re-resolve phase.
                    if !ctx.defer_const_errors {
                        ctx.eval_error(e);
                    }
                    ctx.types.builtin(Builtin::Integer) // fallback
                }
            }
        }
        ast::TypeExpr::Enum(names, values, span) => {
            let ords = enum_member_ordinals(ctx, scope, names, values);
            let enum_ty = ctx
                .types
                .alloc(TypeKind::Enum { name: None, names: names.clone(), values: ords.clone() });
            // Register the members as ordinal constants in the enclosing scope.
            // For a *named* `TYPE T = (a, b, c)` the Type-decl pass re-registers
            // them (with the correct exported flag); doing it here additionally
            // covers an anonymous/inline enumeration used directly as a VAR
            // type, array element or set element — e.g. `ARRAY [1..5] OF
            // (one, two, three)` (array6, sets5).
            for (i, member) in names.iter().enumerate() {
                if ctx.scopes.get(scope).get(member).is_none() {
                    let declaration_id = ctx.fresh_declaration_id();
                    let binding_id = ctx.fresh_binding_id();
                    ctx.scopes.get_mut(scope).insert(Symbol {
                        name: member.clone(),
                        kind: SymbolKind::EnumMember { ty: enum_ty, ord: ords[i] },
                        span: *span,
                        declaration_id,
                        binding_id,
                        provenance: SymbolProvenance::Declared {
                            module: ctx.current_module,
                            module_name: ctx.current_module_name.clone(),
                        },
                        exported: false,
                    });
                }
            }
            enum_ty
        }
        ast::TypeExpr::Array(indices, base, span) => {
            let idx_types: Vec<TypeId> = indices
                .iter()
                .map(|i| form_type_expr(ctx, graph, mid, i, scope))
                .collect();
            let base_ty = form_type_expr(ctx, graph, mid, base, scope);
            // Reject a fixed array too large to represent *as storage*: a bare
            // full-width built-in index (`ARRAY CARDINAL OF …`, `ARRAY INTEGER
            // OF …` = 2^64) or a dimension product past LLVM's u32 array arity
            // (`ARRAY CHAR, CHAR OF …` = 2^32) would otherwise allocate
            // zero-sized/overflowing storage.
            //
            // Two guards keep this from firing on legitimate code:
            //   * `!defer_const_errors` — during interface construction a
            //     forward/cross-module subrange bound (`[0..SIZE(r)+…]`,
            //     `[0..HIGH(s)]`) can't be evaluated yet and the Subrange arm
            //     falls back to the *full INTEGER* type; its 2^64 cardinality is
            //     a placeholder, not the real size, so the check would
            //     false-positive. Bodies and the re-resolve phase run with
            //     bounds resolved.
            //   * `!in_pointer_target` — `POINTER TO ARRAY [0..MAX(CARDINAL)-1]
            //     OF CHAR` is the standard flex-buffer view: only the pointer is
            //     stored, the array is never materialised.
            if !ctx.defer_const_errors && !ctx.in_pointer_target {
                let mut count: i128 = 1;
                let mut too_large = false;
                for &idx in &idx_types {
                    if let Some(c) = ctx.types.ordinal_cardinality(idx) {
                        count = count.saturating_mul(c.max(0));
                        if count > u32::MAX as i128 {
                            too_large = true;
                        }
                    }
                }
                if too_large {
                    ctx.error(
                        *span,
                        "fixed array type is too large to represent (index range exceeds 2^32 elements)",
                    );
                }
            }
            ctx.types.alloc(TypeKind::Array { indices: idx_types, base: base_ty })
        }
        ast::TypeExpr::OpenArray(base, _span) => {
            let base_ty = form_type_expr(ctx, graph, mid, base, scope);
            ctx.types.alloc(TypeKind::OpenArray { base: base_ty })
        }
        ast::TypeExpr::Record(rt) => form_record_type(ctx, graph, mid, rt, scope),
        ast::TypeExpr::Pointer(inner, _span) => {
            // Allocate a pointer with Unresolved base first so that
            // POINTER TO forward-declared types work.
            let ptr_id = ctx.types.alloc_unresolved();
            // Everything behind a pointer is virtual storage: a huge fixed array
            // here is a flex-buffer view, not an allocation, so suppress the
            // array-too-large check for the whole target type.
            let saved = ctx.in_pointer_target;
            ctx.in_pointer_target = true;
            let base_ty = form_type_expr(ctx, graph, mid, inner, scope);
            ctx.in_pointer_target = saved;
            ctx.types.set(ptr_id, TypeKind::Pointer { base: base_ty });
            ptr_id
        }
        ast::TypeExpr::Proc(pt) => {
            let params: Vec<crate::types::ProcParam> = pt
                .params
                .iter()
                .map(|p| {
                    let ty = form_type_expr(ctx, graph, mid, &p.ty, scope);
                    let mode = match p.mode {
                        ast::ParamMode::Var => ParamMode::Var,
                        ast::ParamMode::Const => ParamMode::Const,
                        ast::ParamMode::Value => ParamMode::Value,
                    };
                    crate::types::ProcParam { mode, ty }
                })
                .collect();
            let return_ty = pt
                .return_ty
                .as_deref()
                .map(|ret| form_type_expr(ctx, graph, mid, ret, scope));
            ctx.types.alloc(TypeKind::Proc { params, return_ty })
        }
        ast::TypeExpr::Set { packed, element, span: _ } => {
            let base_ty = form_type_expr(ctx, graph, mid, element, scope);
            ctx.types.alloc(TypeKind::Set { packed: *packed, base: base_ty })
        }
    }
}

fn resolve_type_name(ctx: &mut Ctx, qn: &ast::QualName, scope: ScopeId) -> TypeId {
    match qn.segments.as_slice() {
        [name] => {
            if let Some(sym) = ctx.scopes.lookup(scope, name).cloned() {
                match sym.kind.clone() {
                    SymbolKind::Type(id) => {
                        ctx.note_name_resolution(qn.span, &sym);
                        return id;
                    }
                    SymbolKind::Class(cid) => {
                        ctx.note_name_resolution(qn.span, &sym);
                        return ctx.classes.get(cid).type_id;
                    }
                    _ => {
                        ctx.error(
                            qn.span,
                            format!("'{name}' is not a type"),
                        );
                    }
                }
            } else {
                ctx.error(qn.span, format!("unknown type '{name}'"));
            }
        }
        [module_name, type_name] => {
            // Qualified `M.T` form.
            if let Some(sym) = ctx.scopes.lookup(scope, module_name).cloned() {
                if let SymbolKind::Module(_, mod_scope) = sym.kind {
                    if let Some(sym2) = ctx.scopes.lookup(mod_scope, type_name).cloned() {
                        match sym2.kind.clone() {
                            SymbolKind::Type(id) => {
                                ctx.note_name_resolution(qn.span, &sym2);
                                return id;
                            }
                            SymbolKind::Class(cid) => {
                                ctx.note_name_resolution(qn.span, &sym2);
                                return ctx.classes.get(cid).type_id;
                            }
                            _ => {
                                ctx.error(
                                    qn.span,
                                    format!("'{module_name}.{type_name}' is not a type"),
                                );
                            }
                        }
                    } else {
                        ctx.error(
                            qn.span,
                            format!("'{type_name}' not found in module '{module_name}'"),
                        );
                    }
                } else {
                    ctx.error(
                        qn.span,
                        format!("'{module_name}' is not a module"),
                    );
                }
            } else {
                ctx.error(qn.span, format!("unknown module '{module_name}'"));
            }
        }
        _ => {
            ctx.error(qn.span, "type name has too many segments");
        }
    }
    // Fallback on error.
    ctx.types.builtin(Builtin::Integer)
}

fn form_record_type(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    rt: &ast::RecordType,
    scope: ScopeId,
) -> TypeId {
    let mut fields = Vec::new();
    for rf in &rt.fields {
        let ty = form_type_expr(ctx, graph, mid, &rf.ty, scope);
        for name in &rf.names {
            fields.push(RecordFieldSlot { name: name.clone(), ty });
        }
    }
    let variant = rt.variant.as_ref().map(|vp| form_variant_part(ctx, graph, mid, vp, scope));
    ctx.types.alloc(TypeKind::Record(RecordLayout { name: None, fields, variant }))
}

fn form_variant_part(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    vp: &ast::VariantPart,
    scope: ScopeId,
) -> VariantLayout {
    let tag_type = vp
        .tag_type
        .as_ref()
        .map(|qn| resolve_type_name(ctx, qn, scope))
        .unwrap_or_else(|| ctx.types.builtin(Builtin::Cardinal));

    let arms: Vec<VariantArmLayout> = vp
        .arms
        .iter()
        .map(|arm| {
            let labels: Vec<VariantLabel> = arm
                .labels
                .iter()
                .map(|l| match l {
                    ast::CaseLabel::Single(e) => {
                        let mut consts = collect_scope_consts(ctx, scope);
                        prefill_type_builtins(ctx, scope, e, &mut consts);
                        let lookup = |n: &str| consts.get(n).cloned();
                        let v = eval_const(e, &lookup).unwrap_or(crate::constant::ConstValue::Int(0));
                        VariantLabel::Single(v.as_int().unwrap_or(0))
                    }
                    ast::CaseLabel::Range(lo, hi) => {
                        let mut consts = collect_scope_consts(ctx, scope);
                        prefill_type_builtins(ctx, scope, lo, &mut consts);
                        prefill_type_builtins(ctx, scope, hi, &mut consts);
                        let lookup = |n: &str| consts.get(n).cloned();
                        let l = eval_const(lo, &lookup).ok().and_then(|v| v.as_int()).unwrap_or(0);
                        let h = eval_const(hi, &lookup).ok().and_then(|v| v.as_int()).unwrap_or(0);
                        VariantLabel::Range(l, h)
                    }
                })
                .collect();
            let mut arm_fields = Vec::new();
            for rf in &arm.fields {
                let ty = form_type_expr(ctx, graph, mid, &rf.ty, scope);
                for name in &rf.names {
                    arm_fields.push(RecordFieldSlot { name: name.clone(), ty });
                }
            }
            VariantArmLayout { labels, fields: arm_fields }
        })
        .collect();

    let mut else_fields = Vec::new();
    if let Some(else_arm) = &vp.else_arm {
        for rf in else_arm {
            let ty = form_type_expr(ctx, graph, mid, &rf.ty, scope);
            for name in &rf.names {
                else_fields.push(RecordFieldSlot { name: name.clone(), ty });
            }
        }
    }

    VariantLayout {
        tag_field: vp.tag_name.clone(),
        tag_type,
        arms,
        else_fields,
    }
}

// ---- Procedure signature formation ----------------------------------------

/// Do two procedure signatures agree (parameter count, each parameter's type
/// and mode, and the result type)? Used to check a definition against its
/// FORWARD declaration. Types are compared nominally by `TypeId`.
fn proc_sigs_match(a: &ProcSig, b: &ProcSig) -> bool {
    a.return_ty == b.return_ty
        && a.params.len() == b.params.len()
        && a.params
            .iter()
            .zip(&b.params)
            .all(|(x, y)| x.ty == y.ty && x.mode == y.mode)
}

/// Like [`proc_sigs_match`] but compares parameter / result *types* structurally
/// (via `types_compatible`) rather than by `TypeId` identity. Two signatures
/// formed independently — e.g. a procedure's DEFINITION and IMPLEMENTATION
/// headers — allocate distinct ids for anonymous types (open arrays, subranges)
/// even when equivalent, so id equality is too strict. Count and VAR mode must
/// still match exactly.
fn proc_sigs_compatible(ctx: &Ctx, a: &ProcSig, b: &ProcSig) -> bool {
    a.params.len() == b.params.len()
        && match (a.return_ty, b.return_ty) {
            (None, None) => true,
            (Some(x), Some(y)) => types_compatible(ctx, x, y),
            _ => false,
        }
        && a.params
            .iter()
            .zip(&b.params)
            .all(|(x, y)| x.mode == y.mode && types_compatible(ctx, x.ty, y.ty))
}

fn form_proc_sig(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    p: &ast::ProcDecl,
    scope: ScopeId,
) -> ProcSig {
    let params: Vec<NamedParam> = p
        .params
        .iter()
        .flat_map(|param| {
            let ty = form_type_expr(ctx, graph, mid, &param.ty, scope);
            let mode = match param.mode {
                ast::ParamMode::Var => ParamMode::Var,
                ast::ParamMode::Const => ParamMode::Const,
                ast::ParamMode::Value => ParamMode::Value,
            };
            param.names.iter().map(move |name| NamedParam {
                name: Some(name.clone()),
                mode,
                ty,
            })
        })
        .collect();

    let return_ty = p
        .return_ty
        .as_ref()
        .map(|te| form_type_expr(ctx, graph, mid, te, scope));

    let calling_conv = parse_calling_conv(&p.attrs, &p.pragmas);
    let attrs = parse_proc_attrs(&p.attrs, &p.pragmas);
    let external_linkage = p.external_linkage.as_ref().map(|linkage| crate::scope::ProcExternalLinkage {
        link_name: linkage.link_name.value.clone(),
        dll_name: linkage.dll_name.as_ref().map(|name| name.value.clone()),
        is_external: linkage.is_external,
    });

    ProcSig { params, return_ty, calling_conv, attrs, external_linkage }
}

fn parse_calling_conv(attrs: &[ast::ProcAttr], pragmas: &[ast::Pragma]) -> CallingConv {
    for a in attrs {
        match a.name.as_str() {
            "Pass" | "Alters" => {} // register hints, not CC
            _ => {}
        }
    }
    for p in pragmas {
        let body = p.body.trim();
        if body.starts_with("PROCATTR") {
            let rest = body["PROCATTR".len()..].trim();
            match rest {
                "Windows" => return CallingConv::Windows,
                "CDECL" => return CallingConv::Cdecl,
                "Asm" => return CallingConv::Asm,
                _ => {}
            }
        }
    }
    CallingConv::Default
}

fn parse_proc_attrs(attrs: &[ast::ProcAttr], pragmas: &[ast::Pragma]) -> Vec<ProcAttrKind> {
    let mut out = Vec::new();
    for a in attrs {
        if a.name == "VARARGS" {
            out.push(ProcAttrKind::Varargs);
        }
    }
    for p in pragmas {
        let body = p.body.trim();
        match body {
            "INLINE" => out.push(ProcAttrKind::Inline),
            "NOOPTIMIZE" => out.push(ProcAttrKind::NoOptimize),
            _ => {}
        }
    }
    out
}

fn resolve_symbol(ctx: &mut Ctx, qn: &ast::QualName, scope: ScopeId) -> Option<Symbol> {
    let mut current = match qn.segments.first() {
        Some(name) => match ctx.scopes.lookup(scope, name).cloned() {
            Some(sym) => sym,
            None => {
                ctx.error(qn.span, format!("unknown identifier '{}'", name));
                return None;
            }
        },
        None => return None,
    };

    for seg in qn.segments.iter().skip(1) {
        match current.kind {
            SymbolKind::Module(_, module_scope) => {
                current = match ctx.scopes.get(module_scope).get(seg).cloned() {
                    Some(sym) => sym,
                    None => {
                        ctx.error(qn.span, format!("module-qualified name has no member '{}'", seg));
                        return None;
                    }
                };
            }
            _ => {
                ctx.error(qn.span, format!("'{}' is not a module", current.name));
                return None;
            }
        }
    }

    ctx.note_name_resolution(qn.span, &current);
    Some(current)
}

fn resolve_designator_head(
    ctx: &mut Ctx,
    designator: &ast::Designator,
    scope: ScopeId,
) -> Option<(Symbol, usize)> {
    let mut current = resolve_symbol(ctx, &designator.base, scope)?;
    let mut consumed = 0;

    while let SymbolKind::Module(_, module_scope) = current.kind {
        let Some(ast::Selector::Field(name, span)) = designator.selectors.get(consumed) else {
            break;
        };
        let Some(next) = ctx.scopes.get(module_scope).get(name).cloned() else {
            ctx.error(*span, format!("module-qualified name has no member '{}'", name));
            return None;
        };
        ctx.note_name_resolution(*span, &next);
        current = next;
        consumed += 1;
    }

    Some((current, consumed))
}

fn note_designator_base(ctx: &mut Ctx, designator: &ast::Designator, sym: &Symbol) {
    ctx.note_name_resolution(designator.base.span, sym);
}

fn find_record_field_binding(layout: &RecordLayout, name: &str) -> Option<SelectorBinding> {
    // Search the flattened struct order (fixed fields, tag, arm fields, else
    // fields) so a variant field resolves to its real struct index, not 0.
    layout
        .flatten_fields()
        .iter()
        .enumerate()
        .find(|(_, (n, _))| n == name)
        .map(|(index, (_, ty))| SelectorBinding::Field { ty: *ty, index: Some(index as u32) })
}

fn find_class_field_binding(ctx: &Ctx, cid: ClassSymbolId, name: &str) -> Option<SelectorBinding> {
    ctx.classes
        .get(cid)
        .all_fields
        .iter()
        .enumerate()
        .find(|(_, field)| field.name == name)
        .map(|(index, field)| SelectorBinding::Field {
            ty: field.ty,
            // +1: the object record reserves slot 0 for the vtable pointer.
            index: Some(index as u32 + 1),
        })
}

/// Resolve a method selector `obj.M` to a `Method` binding (carrying the vtable
/// slot for virtual dispatch) plus the method's return type (a `PROC`
/// placeholder for a void method, used only for designator typing).
fn find_class_method_binding(
    ctx: &mut Ctx,
    cid: ClassSymbolId,
    name: &str,
) -> Option<(SelectorBinding, TypeId)> {
    let (idx, return_ty) = {
        let cls = ctx.classes.get(cid);
        let (i, slot) = cls.vtable.iter().enumerate().find(|(_, s)| s.name == name)?;
        (i as u32, slot.sig.return_ty)
    };
    let ret = return_ty.unwrap_or_else(|| ctx.types.builtin(Builtin::Proc));
    Some((
        SelectorBinding::Method { ty: ret, vtable_index: idx, class: cid },
        ret,
    ))
}

/// If `d`'s last selector resolved to a class method, return that method's full
/// signature (for argument checking at the call site).
fn method_sig_from_designator(ctx: &Ctx, d: &ast::Designator) -> Option<ProcSig> {
    let ast::Selector::Field(_, span) = d.selectors.last()? else {
        return None;
    };
    let binding = ctx
        .selector_bindings
        .get(&SpanKey::new(ctx.current_module, *span))
        .copied()?;
    let SelectorBinding::Method { class, vtable_index, .. } = binding else {
        return None;
    };
    Some(ctx.classes.get(class).vtable[vtable_index as usize].sig.clone())
}

fn designator_type_from_symbol(ctx: &Ctx, sym: &SymbolKind) -> Option<TypeId> {
    match sym {
        SymbolKind::Const { ty, .. }
        | SymbolKind::Type(ty)
        | SymbolKind::Var { ty, .. }
        | SymbolKind::EnumMember { ty, .. } => Some(*ty),
        SymbolKind::Class(cid) => Some(ctx.classes.get(*cid).type_id),
        SymbolKind::Proc(_) | SymbolKind::Module(..) => None,
    }
}

fn resolve_designator_proc_sig(
    ctx: &mut Ctx,
    designator: &ast::Designator,
    scope: ScopeId,
) -> Option<ProcSig> {
    let (sym, consumed) = resolve_designator_head(ctx, designator, scope)?;
    if consumed != designator.selectors.len() {
        return None;
    }
    match sym.kind {
        SymbolKind::Proc(sig) => Some(sig),
        SymbolKind::Var { ty, .. } => match ctx.types.get(ty) {
            TypeKind::Proc { params, return_ty } => Some(ProcSig {
                params: params
                    .iter()
                    .map(|param| NamedParam {
                        name: None,
                        mode: param.mode,
                        ty: param.ty,
                    })
                    .collect(),
                return_ty: *return_ty,
                calling_conv: CallingConv::Default,
                attrs: Vec::new(),
                    external_linkage: None,
            }),
            _ => None,
        },
        _ => None,
    }
}

fn is_boolean_type(ctx: &Ctx, ty: TypeId) -> bool {
    matches!(ctx.types.get(ty), TypeKind::Builtin(Builtin::Boolean))
}

/// True for any ordinal type usable as a FOR control variable: the integer
/// family (incl. enums/subranges) plus CHAR/ACHAR/UCHAR and BOOLEAN. Kept
/// separate from `is_integer_family_type` so CHAR/BOOLEAN don't leak into
/// arithmetic / array-index contexts that genuinely want integers.
fn is_ordinal_type(ctx: &Ctx, ty: TypeId) -> bool {
    is_integer_family_type(ctx, ty)
        || matches!(
            ctx.types.get(ty),
            TypeKind::Builtin(
                Builtin::Char | Builtin::Achar | Builtin::Uchar | Builtin::Boolean
            )
        )
}

/// Can `T(x)` be a value conversion to `T` — i.e. is `T` a scalar (ordinal,
/// real/complex, or pointer/ADDRESS) type? Excludes records, arrays, and sets,
/// for which a `T(x)` call is not a conversion.
fn is_scalar_convertible_type(ctx: &Ctx, ty: TypeId) -> bool {
    is_ordinal_type(ctx, ty)
        || is_numeric_type(ctx, ty)
        || matches!(
            ctx.types.get(ty),
            TypeKind::Pointer { .. }
                | TypeKind::Builtin(Builtin::Real | Builtin::LongReal)
        )
}

fn is_integer_family_type(ctx: &Ctx, ty: TypeId) -> bool {
    match ctx.types.get(ty) {
        TypeKind::Builtin(b) => matches!(
            b,
            Builtin::Integer
                | Builtin::LongInt
                | Builtin::Integer8
                | Builtin::Integer16
                | Builtin::Integer32
                | Builtin::Integer64
                | Builtin::Cardinal
                | Builtin::LongCard
                | Builtin::Cardinal8
                | Builtin::Cardinal16
                | Builtin::Cardinal32
                | Builtin::Cardinal64
                | Builtin::Byte
                | Builtin::Word
                | Builtin::Dword
                | Builtin::Qword
                // SYSTEM storage types are word/byte-sized integers.
                | Builtin::SysWord
                | Builtin::SysByte
                | Builtin::SysLoc
                | Builtin::Adrint
                | Builtin::Adrcard
                | Builtin::Address
                | Builtin::SysAddress
        ),
        TypeKind::Enum { .. } | TypeKind::Subrange { .. } => true,
        _ => false,
    }
}

/// True when the expression is a bare integer literal (`42`, `0FFH`, …),
/// which is compatible with any integer-family type.
fn is_integer_literal(expr: &ast::Expr) -> bool {
    matches!(expr, ast::Expr::Integer(_, _))
}

fn is_numeric_type(ctx: &Ctx, ty: TypeId) -> bool {
    match ctx.types.get(ty) {
        TypeKind::Builtin(b) => matches!(
            b,
            Builtin::Integer
                | Builtin::LongInt
                | Builtin::Integer8
                | Builtin::Integer16
                | Builtin::Integer32
                | Builtin::Integer64
                | Builtin::Cardinal
                | Builtin::LongCard
                | Builtin::Cardinal8
                | Builtin::Cardinal16
                | Builtin::Cardinal32
                | Builtin::Cardinal64
                | Builtin::Byte
                | Builtin::Word
                | Builtin::Dword
                | Builtin::Qword
                // SYSTEM.ADDRESS and the address-as-integer types support
                // arithmetic (pointer arithmetic) like an unsigned word.
                | Builtin::Address
                | Builtin::SysAddress
                | Builtin::Adrint
                | Builtin::Adrcard
                | Builtin::Real
                | Builtin::LongReal
                | Builtin::Real32
                | Builtin::Real16
                | Builtin::Complex
                | Builtin::LongComplex
        ),
        // A SIMD lane vector supports element-wise arithmetic.
        TypeKind::Vector { .. } => true,
        TypeKind::Enum { .. } | TypeKind::Subrange { .. } => true,
        _ => false,
    }
}

/// A SIMD lane vector (`REAL32X4`, `REAL64X2`, …).
fn is_vector_type(ctx: &Ctx, ty: TypeId) -> bool {
    matches!(ctx.types.get(ty), TypeKind::Vector { .. })
}

/// Any IEEE floating-point builtin (REAL/LONGREAL/REAL32/REAL16).
fn is_real_type(ctx: &Ctx, ty: TypeId) -> bool {
    matches!(
        ctx.types.get(ty),
        TypeKind::Builtin(
            Builtin::Real | Builtin::LongReal | Builtin::Real32 | Builtin::Real16
        )
    )
}

fn is_set_type(ctx: &Ctx, ty: TypeId) -> bool {
    matches!(
        ctx.types.get(ty),
        TypeKind::Set { .. } | TypeKind::Builtin(Builtin::Bitset | Builtin::SysBitset)
    )
}

/// A CHAR, or a string (`ARRAY OF CHAR`) — the operands of `+` concatenation.
fn is_char_or_string_type(ctx: &Ctx, ty: TypeId) -> bool {
    match ctx.types.get(ty) {
        TypeKind::Builtin(Builtin::Char | Builtin::Uchar | Builtin::Achar) => true,
        TypeKind::Array { base, .. } | TypeKind::OpenArray { base } => matches!(
            ctx.types.get(*base),
            TypeKind::Builtin(Builtin::Char | Builtin::Uchar | Builtin::Achar)
        ),
        _ => false,
    }
}

/// A *scalar* CHAR target (CHAR/UCHAR, or a subrange of one) — distinct from an
/// `ARRAY OF CHAR`. The string-element type `Achar` shares a family with `Char`
/// (so a length-1 literal `'x'` / `"x"` and a folded length-1 concat are CHAR
/// values), but a multi-character constant string is not assignable here.
fn is_scalar_char_type(ctx: &Ctx, ty: TypeId) -> bool {
    match ctx.types.get(ty) {
        TypeKind::Builtin(Builtin::Char | Builtin::Uchar | Builtin::Achar) => true,
        TypeKind::Subrange { host, .. } => is_scalar_char_type(ctx, *host),
        _ => false,
    }
}

fn types_compatible(ctx: &Ctx, lhs: TypeId, rhs: TypeId) -> bool {
    if lhs == rhs {
        return true;
    }

    match (ctx.types.get(lhs), ctx.types.get(rhs)) {
        (TypeKind::Builtin(a), TypeKind::Builtin(b)) => a.is_same_family(*b),
        (TypeKind::Set { base: a, .. }, TypeKind::Set { base: b, .. }) => {
            types_compatible(ctx, *a, *b)
        }
        // BITSET is the generic set type: compatible with any set value
        // (e.g. `s := BITSET{}` / a `{..}` constructor assigned to a BITSET).
        (TypeKind::Builtin(Builtin::Bitset | Builtin::SysBitset), TypeKind::Set { .. })
        | (TypeKind::Set { .. }, TypeKind::Builtin(Builtin::Bitset | Builtin::SysBitset)) => true,
        // Enumerations with identical members are the same type — covers
        // cross-module enum aliases like `SeqFile.OpenResults =
        // ChanConsts.OpenResults` (distinct cloned TypeIds, same members).
        (TypeKind::Enum { names: a, .. }, TypeKind::Enum { names: b, .. }) => a == b,
        (TypeKind::Pointer { .. }, TypeKind::Builtin(Builtin::Nil))
        | (TypeKind::Builtin(Builtin::Nil), TypeKind::Pointer { .. }) => true,
        // Two pointer types are compatible when their pointees are — covers
        // alias types like `StdChans.ChanId = IOChan.ChanId` (distinct TypeIds,
        // same `POINTER TO DeviceTable` base). Same-base ids short-circuit via
        // the `lhs == rhs` check above, so this only recurses for distinct ids.
        (TypeKind::Pointer { base: a }, TypeKind::Pointer { base: b }) => {
            types_compatible(ctx, *a, *b)
        }
        // ADDRESS / SYSTEM.ADDRESS interconvert with any typed pointer.
        (TypeKind::Pointer { .. }, TypeKind::Builtin(Builtin::Address | Builtin::SysAddress))
        | (TypeKind::Builtin(Builtin::Address | Builtin::SysAddress), TypeKind::Pointer { .. }) => {
            true
        }
        (
            TypeKind::Proc { params: a_params, return_ty: a_ret },
            TypeKind::Proc { params: b_params, return_ty: b_ret },
        ) => {
            if a_ret != b_ret || a_params.len() != b_params.len() {
                return false;
            }
            a_params
                .iter()
                .zip(b_params)
                .all(|(a, b)| a.mode == b.mode && a.ty == b.ty)
        }
        // A procedure referenced as a value has the generic `PROC` type; it is
        // assignable to / from any specific PROCEDURE type (procedure-pointer
        // assignment, e.g. ScanState state machines).
        (TypeKind::Proc { .. }, TypeKind::Builtin(Builtin::Proc))
        | (TypeKind::Builtin(Builtin::Proc), TypeKind::Proc { .. }) => true,
        // An open-array parameter (`ARRAY OF T`) accepts any array with a
        // compatible element type: another open array, or a fixed
        // `ARRAY [lo..hi] OF T`.
        (TypeKind::OpenArray { base: e }, TypeKind::OpenArray { base: a })
        | (TypeKind::OpenArray { base: e }, TypeKind::Array { base: a, .. }) => {
            types_compatible(ctx, *e, *a)
        }
        // Class subtyping: a value of class `R` is assignable to a variable of
        // class `L` when `R` is `L` or a subclass of it (Derived → Base). The
        // object carries its own vtable, so virtual dispatch stays correct.
        (TypeKind::Class { symbol: l }, TypeKind::Class { symbol: r }) => {
            class_is_subclass(ctx, ClassSymbolId(*r), ClassSymbolId(*l))
        }
        // A class reference is NIL-able and ADDRESS-compatible.
        (TypeKind::Class { .. }, TypeKind::Builtin(Builtin::Nil))
        | (TypeKind::Builtin(Builtin::Nil), TypeKind::Class { .. })
        | (TypeKind::Class { .. }, TypeKind::Builtin(Builtin::Address | Builtin::SysAddress))
        | (TypeKind::Builtin(Builtin::Address | Builtin::SysAddress), TypeKind::Class { .. }) => true,
        (TypeKind::Subrange { host, .. }, _) => types_compatible(ctx, *host, rhs),
        (_, TypeKind::Subrange { host, .. }) => types_compatible(ctx, lhs, *host),
        _ => false,
    }
}

/// True when `sub` is `sup` or a (transitive) subclass of it.
fn class_is_subclass(ctx: &Ctx, sub: ClassSymbolId, sup: ClassSymbolId) -> bool {
    let mut cur = Some(sub);
    while let Some(c) = cur {
        if c == sup {
            return true;
        }
        cur = ctx.classes.get(c).base;
    }
    false
}

fn expr_compatible_with_type(ctx: &Ctx, expected: TypeId, expr: &ast::Expr, actual: TypeId) -> bool {
    if types_compatible(ctx, expected, actual) {
        return true;
    }

    // ADW-style assignment leniency: any whole-number value assigns to any
    // integer-family target (INTEGER ↔ CARDINAL ↔ sized variants). Range is
    // a runtime concern, not a static type error — this matches the ADW
    // dialect NewM2 targets. Arithmetic result typing stays strict.
    if is_integer_family_type(ctx, expected) && is_integer_family_type(ctx, actual) {
        return true;
    }

    // Array-of-CHAR parameter compatibility: a fixed/open `ARRAY OF T`, or a
    // CHAR-valued expression / string CONST (typed as its char element), may be
    // passed where `ARRAY [..] OF CHAR` is expected — e.g. a CONST string or a
    // single CHAR passed to an `ARRAY OF CHAR` param.
    if let TypeKind::OpenArray { base: eb } | TypeKind::Array { base: eb, .. } =
        ctx.types.get(expected)
    {
        let is_char = |t: &TypeKind| {
            matches!(t, TypeKind::Builtin(Builtin::Char | Builtin::Achar | Builtin::Uchar))
        };
        match ctx.types.get(actual) {
            TypeKind::Array { base, .. } | TypeKind::OpenArray { base } => {
                if types_compatible(ctx, *eb, *base) {
                    return true;
                }
            }
            other => {
                if is_char(ctx.types.get(*eb)) && is_char(other) {
                    return true;
                }
            }
        }
    }

    match expr {
        ast::Expr::Integer(_, _) => is_integer_family_type(ctx, expected),
        // A real literal is width-polymorphic: it adopts the target real type
        // (REAL/LONGREAL/REAL32/REAL16), narrowing at codegen. So `r32 := 3.14`
        // is fine even though REAL32 is a distinct family from REAL. A
        // unary-signed real literal (`-5.0`, `+1.5`) is still a literal.
        ast::Expr::Real(_, _) => is_real_type(ctx, expected),
        ast::Expr::Unary(ast::UnaryOp::Neg | ast::UnaryOp::Pos, inner, _)
            if matches!(inner.as_ref(), ast::Expr::Real(_, _)) =>
        {
            is_real_type(ctx, expected)
        }
        ast::Expr::String(lit, _) => match ctx.types.get(expected) {
            TypeKind::OpenArray { base } | TypeKind::Array { base, .. } => {
                matches!(
                    (lit.flavor, ctx.types.get(*base)),
                    (LiteralFlavor::Default, TypeKind::Builtin(Builtin::Char | Builtin::Achar | Builtin::Uchar))
                        | (LiteralFlavor::Achar, TypeKind::Builtin(Builtin::Char | Builtin::Achar))
                        | (LiteralFlavor::Uchar, TypeKind::Builtin(Builtin::Uchar))
                )
            }
            _ => false,
        },
        // A single-character literal (`"x"` / `'x'`) is dual-typed in ISO M2:
        // a CHAR, but also a length-1 string compatible with ARRAY OF CHAR.
        ast::Expr::Char(c, _) => match ctx.types.get(expected) {
            TypeKind::OpenArray { base } | TypeKind::Array { base, .. } => {
                matches!(
                    (c.flavor, ctx.types.get(*base)),
                    (LiteralFlavor::Default, TypeKind::Builtin(Builtin::Char | Builtin::Achar | Builtin::Uchar))
                        | (LiteralFlavor::Achar, TypeKind::Builtin(Builtin::Char | Builtin::Achar))
                        | (LiteralFlavor::Uchar, TypeKind::Builtin(Builtin::Uchar))
                )
            }
            _ => false,
        },
        _ => {
            let _ = actual;
            false
        }
    }
}

/// True when `target`'s base name is a `CONST` parameter — assigning to it (or
/// to any field/element of it) is forbidden.
fn is_const_param_target(ctx: &Ctx, target: &ast::Designator, scope: ScopeId) -> bool {
    let [name] = target.base.segments.as_slice() else {
        return false;
    };
    matches!(
        ctx.scopes.lookup(scope, name).map(|s| &s.kind),
        Some(SymbolKind::Var { param_mode: Some(ParamMode::Const), .. })
    )
}

/// Is the assignment target read-only — a named constant (or a component of
/// one), or a field reached through a read-only `WITH constRec DO …`? Modula-2
/// forbids assigning to a constant.
fn is_readonly_target(ctx: &Ctx, target: &ast::Designator, scope: ScopeId) -> bool {
    let Some(name) = target.base.segments.first() else {
        return false;
    };
    // A named constant or enumeration member (also a constant), possibly with
    // `[i]`/`.field` selectors applied.
    if matches!(
        ctx.scopes.lookup(scope, name).map(|s| &s.kind),
        Some(SymbolKind::Const { .. } | SymbolKind::EnumMember { .. })
    ) {
        return true;
    }
    // A bare field name resolving against a read-only WITH record.
    if target.base.segments.len() == 1 && ctx.scopes.lookup(scope, name).is_none() {
        return ctx
            .with_stack
            .iter()
            .rev()
            .find(|(rec, _)| record_field_lookup(ctx, *rec, name).is_some())
            .map(|(_, ro)| *ro)
            .unwrap_or(false);
    }
    false
}

/// If `ty` is a RECORD (or POINTER TO RECORD), return the record's `TypeId`.
fn record_type_of(ctx: &Ctx, ty: TypeId) -> Option<TypeId> {
    match ctx.types.get(ty) {
        TypeKind::Record(_) => Some(ty),
        TypeKind::Pointer { base } if matches!(ctx.types.get(*base), TypeKind::Record(_)) => {
            Some(*base)
        }
        _ => None,
    }
}

/// Flattened `(index, field_type)` of a record field by name.
fn record_field_lookup(ctx: &Ctx, record_ty: TypeId, name: &str) -> Option<(u32, TypeId)> {
    let TypeKind::Record(layout) = ctx.types.get(record_ty) else {
        return None;
    };
    layout
        .flatten_fields()
        .iter()
        .enumerate()
        .find(|(_, (n, _))| n == name)
        .map(|(i, (_, ty))| (i as u32, *ty))
}

/// Resolve a bare designator whose head names a field of an active `WITH`
/// record. Returns `Some(result)` when it was a WITH field (with the analysed
/// type), or `None` to let normal resolution proceed.
fn analyse_with_field(
    ctx: &mut Ctx,
    designator: &ast::Designator,
    scope: ScopeId,
) -> Option<Option<TypeId>> {
    let name = &designator.base.segments[0];
    // Innermost WITH record that has this field.
    let (record_ty, index, field_ty) = ctx
        .with_stack
        .iter()
        .rev()
        .copied()
        .find_map(|(rec, _ro)| record_field_lookup(ctx, rec, name).map(|(i, t)| (rec, i, t)))?;
    // Annotate the head as a field access so lowering GEPs it off the WITH base.
    ctx.note_selector_binding(
        designator.base.span,
        SelectorBinding::Field { ty: field_ty, index: Some(index) },
    );
    let _ = record_ty;
    let result_ty = analyse_selector_chain(ctx, field_ty, &designator.selectors, scope);
    if let Some(t) = result_ty {
        ctx.note_designator_type(designator.span, t);
    }
    Some(result_ty)
}

fn analyse_designator(
    ctx: &mut Ctx,
    designator: &ast::Designator,
    scope: ScopeId,
) -> Option<TypeId> {
    // WITH: a bare name that does not resolve normally but names a field of an
    // active WITH record is that field of the record. (Checked only when the
    // name is otherwise unresolved, so an outer variable of the same name keeps
    // its meaning — a small, non-breaking divergence from strict shadowing.)
    if designator.base.segments.len() == 1
        && !ctx.with_stack.is_empty()
        && ctx.scopes.lookup(scope, &designator.base.segments[0]).is_none()
    {
        if let Some(result) = analyse_with_field(ctx, designator, scope) {
            return result;
        }
    }

    let base_sym = resolve_symbol(ctx, &designator.base, scope)?;
    note_designator_base(ctx, designator, &base_sym);
    let (sym, consumed) = resolve_designator_head(ctx, designator, scope)?;

    let current_ty = match &sym.kind {
        SymbolKind::Proc(_) => ctx.types.builtin(Builtin::Proc),
        SymbolKind::Module(..) => {
            ctx.error(designator.span, format!("module '{}' is not a value", sym.name));
            return None;
        }
        other => designator_type_from_symbol(ctx, other)?,
    };

    if consumed == designator.selectors.len() {
        ctx.note_name_resolution(designator.span, &sym);
    }

    let current_ty =
        analyse_selector_chain(ctx, current_ty, &designator.selectors[consumed..], scope)?;
    ctx.note_designator_type(designator.span, current_ty);
    Some(current_ty)
}

/// Walk a chain of selectors (field / index / deref / type-guard) from
/// `current_ty`, annotating each selector and returning the resulting type.
/// Shared by normal designator analysis and `WITH`-field resolution.
fn analyse_selector_chain(
    ctx: &mut Ctx,
    mut current_ty: TypeId,
    selectors: &[ast::Selector],
    scope: ScopeId,
) -> Option<TypeId> {
    for selector in selectors {
        current_ty = match selector {
            ast::Selector::Field(name, span) => match ctx.types.get(current_ty) {
                TypeKind::Record(layout) => match find_record_field_binding(layout, name) {
                    Some(binding @ SelectorBinding::Field { ty, .. }) => {
                        ctx.note_selector_binding(*span, binding);
                        ty
                    }
                    Some(SelectorBinding::Method { .. }) => {
                        unreachable!("field lookup never yields a method binding")
                    }
                    None => {
                        ctx.error(*span, format!("record has no field '{}'", name));
                        return None;
                    }
                },
                TypeKind::Pointer { base } => match ctx.types.get(*base) {
                    TypeKind::Record(layout) => match find_record_field_binding(layout, name) {
                        Some(binding @ SelectorBinding::Field { ty, .. }) => {
                            ctx.note_selector_binding(*span, binding);
                            ty
                        }
                        Some(SelectorBinding::Method { .. }) => {
                            unreachable!("field lookup never yields a method binding")
                        }
                        None => {
                            ctx.error(*span, format!("record has no field '{}'", name));
                            return None;
                        }
                    },
                    TypeKind::Class { symbol } => match find_class_field_binding(ctx, ClassSymbolId(*symbol), name) {
                        Some(binding @ SelectorBinding::Field { ty, .. }) => {
                            ctx.note_selector_binding(*span, binding);
                            ty
                        }
                        Some(SelectorBinding::Method { .. }) => {
                            unreachable!("field lookup never yields a method binding")
                        }
                        None => {
                            ctx.error(*span, format!("class has no field '{}'", name));
                            return None;
                        }
                    },
                    _ => {
                        ctx.error(*span, "field selection requires RECORD or POINTER TO RECORD");
                        return None;
                    }
                },
                TypeKind::Class { symbol } => {
                    let cid = ClassSymbolId(*symbol);
                    if let Some(binding @ SelectorBinding::Field { ty, .. }) =
                        find_class_field_binding(ctx, cid, name)
                    {
                        ctx.note_selector_binding(*span, binding);
                        ty
                    } else if let Some((binding, ret)) = find_class_method_binding(ctx, cid, name) {
                        ctx.note_selector_binding(*span, binding);
                        ret
                    } else {
                        ctx.error(*span, format!("class has no field or method '{}'", name));
                        return None;
                    }
                }
                _ => {
                    ctx.error(*span, "field selection requires RECORD or class type");
                    return None;
                }
            },
            ast::Selector::Index(indices, span) if matches!(ctx.types.get(current_ty), TypeKind::Vector { .. }) => {
                // `v[i]` — SIMD lane access. A single ordinal index yields the
                // lane (element) type; the lane number is 0..lanes-1.
                let TypeKind::Vector { base, lanes } = ctx.types.get(current_ty) else {
                    unreachable!()
                };
                let (base, lanes) = (*base, *lanes);
                if indices.len() != 1 {
                    ctx.error(*span, "a vector takes exactly one lane index");
                }
                for index in indices {
                    if let Some(index_ty) = analyse_expr(ctx, index, scope)
                        && !is_ordinal_type(ctx, index_ty)
                    {
                        ctx.error(expr_span(index), "vector lane index must be ordinal");
                    }
                    // A compile-time-constant lane index must be in 0..lanes-1.
                    if let Some(n) = const_int_of(ctx, index, scope)
                        && (n < 0 || n >= lanes as i128)
                    {
                        ctx.error(
                            expr_span(index),
                            format!("vector lane index {n} is out of range 0..{}", lanes - 1),
                        );
                    }
                }
                base
            }
            ast::Selector::Index(indices, span) => {
                // `a[i, j]` indexes successive array dimensions. A single ARRAY
                // node may carry several dimensions (`ARRAY x, y OF T`) and
                // arrays may also nest (`ARRAY x OF ARRAY y OF T`), so consume
                // one dimension per index, crossing node boundaries as needed.
                let mut elem_ty = current_ty;
                let mut pending = &indices[..];
                while !pending.is_empty() {
                    // Extract the current node's dimensions, dropping the type
                    // borrow before analysing index expressions / allocating.
                    let node = match ctx.types.get(elem_ty) {
                        TypeKind::Array { indices: dims, base } if !dims.is_empty() => {
                            Some((dims.clone(), *base, false))
                        }
                        TypeKind::OpenArray { base } => Some((Vec::new(), *base, true)),
                        _ => None,
                    };
                    let Some((dims, base, is_open)) = node else {
                        ctx.error(*span, "indexing requires ARRAY or open ARRAY");
                        return None;
                    };
                    // Open arrays carry exactly one dimension.
                    let ndims = if is_open { 1 } else { dims.len() };
                    let take = pending.len().min(ndims);
                    for (dim_i, index) in pending[..take].iter().enumerate() {
                        if let Some(index_ty) = analyse_expr(ctx, index, scope) {
                            // An array index may be any ordinal value — INTEGER /
                            // CARDINAL, CHAR, BOOLEAN, an enumeration, or a
                            // subrange of these (`ARRAY BOOLEAN OF …`,
                            // `ARRAY ['a'..'c'] …`).
                            if !is_ordinal_type(ctx, index_ty) {
                                ctx.error(expr_span(index), "array index must be ordinal");
                            } else if !is_open && ctx.strict {
                                // Pedantic (`--strict`) only: a compile-time-constant
                                // index into a fixed array proven outside the declared
                                // dimension is a static error. Lenient builds (the
                                // default) still trap it at run time (indexException).
                                if let Some(k) = const_int_of(ctx, index, scope)
                                    && let Some((lo, hi)) =
                                        dims.get(dim_i).and_then(|d| type_ordinal_bounds(ctx, *d))
                                    && (k < lo || k > hi)
                                {
                                    ctx.error(
                                        expr_span(index),
                                        format!("array index {k} out of bounds [{lo}..{hi}]"),
                                    );
                                }
                            }
                        }
                    }
                    pending = &pending[take..];
                    if take < ndims {
                        // Fewer indices than this node's dimensions yields a
                        // lower-rank sub-array of the remaining dimensions
                        // (`row := matrix[i]`). Codegen computes the sub-array's
                        // address from the row-major strides; the type here is an
                        // array of the not-yet-indexed dimensions.
                        let remaining = dims[take..].to_vec();
                        elem_ty = ctx.types.alloc(TypeKind::Array { indices: remaining, base });
                    } else {
                        elem_ty = base;
                    }
                }
                elem_ty
            }
            ast::Selector::Deref(span) => match ctx.types.get(current_ty) {
                TypeKind::Pointer { base } => *base,
                _ => {
                    ctx.error(*span, "'^' requires POINTER");
                    return None;
                }
            },
            ast::Selector::TypeGuard(target, span) => {
                let target_ty = resolve_type_name(ctx, target, scope);
                if !types_compatible(ctx, current_ty, target_ty) {
                    ctx.error(*span, "type guard target is incompatible with designator type");
                }
                target_ty
            }
        };
    }
    Some(current_ty)
}

fn expr_span(expr: &ast::Expr) -> Span {
    match expr {
        ast::Expr::Integer(_, span)
        | ast::Expr::Real(_, span)
        | ast::Expr::Char(_, span)
        | ast::Expr::String(_, span)
        | ast::Expr::Nil(span)
        | ast::Expr::Call(_, _, span)
        | ast::Expr::Binary(_, _, _, span)
        | ast::Expr::Unary(_, _, span)
        | ast::Expr::Set { span, .. } => *span,
        ast::Expr::Designator(designator) => designator.span,
    }
}

fn annotate_expr(ctx: &mut Ctx, expr: &ast::Expr, ty: TypeId) {
    ctx.note_expr_type(expr_span(expr), ty);
}

/// Is `ty` an open-array parameter of `SYSTEM.LOC`/`BYTE`/`WORD` — a raw
/// storage view that, per ISO 10514-1, accepts an actual parameter of any type?
fn is_loc_view_param(ctx: &Ctx, ty: TypeId) -> bool {
    let TypeKind::OpenArray { base } = ctx.types.get(ty) else {
        return false;
    };
    matches!(
        ctx.types.get(*base),
        TypeKind::Builtin(
            Builtin::Byte
                | Builtin::SysByte
                | Builtin::Word
                | Builtin::SysWord
                | Builtin::SysLoc
        )
    )
}

fn analyse_call_args(
    ctx: &mut Ctx,
    args: &[ast::Expr],
    sig: &ProcSig,
    span: Span,
    scope: ScopeId,
) {
    // A variadic procedure (e.g. printf) requires at least its fixed
    // parameters; any further arguments are the variadic tail.
    let is_varargs = sig.attrs.contains(&ProcAttrKind::Varargs);
    let count_ok = if is_varargs {
        args.len() >= sig.params.len()
    } else {
        args.len() == sig.params.len()
    };
    if !count_ok {
        ctx.error(
            span,
            format!(
                "call expects {}{} argument(s) but got {}",
                if is_varargs { "at least " } else { "" },
                sig.params.len(),
                args.len()
            ),
        );
    }

    for (arg, param) in args.iter().zip(sig.params.iter()) {
        let arg_ty = analyse_expr(ctx, arg, scope);
        if let Some(arg_ty) = arg_ty {
            // ISO 10514-1: a formal parameter of type `ARRAY OF SYSTEM.LOC`
            // (or BYTE/WORD, which are LOC-based) is compatible with an actual
            // of *any* type — it is a raw storage view of the actual.
            if !is_loc_view_param(ctx, param.ty)
                && !expr_compatible_with_type(ctx, param.ty, arg, arg_ty)
            {
                ctx.error(
                    expr_span(arg),
                    "argument type is not assignment-compatible with parameter",
                );
            }
        }
        if param.mode == ParamMode::Var && !matches!(arg, ast::Expr::Designator(_)) {
            ctx.error(expr_span(arg), "VAR parameter requires a designator argument");
        }
    }

    for extra in args.iter().skip(sig.params.len()) {
        let _ = analyse_expr(ctx, extra, scope);
    }
}

fn resolve_builtin_type_arg(
    ctx: &mut Ctx,
    arg: &ast::Expr,
    scope: ScopeId,
    allow_value: bool,
) -> Option<TypeId> {
    let ast::Expr::Designator(designator) = arg else {
        // `MIN`/`MAX` accept a variable or any typed operand; use its type.
        if allow_value && let Some(ty) = analyse_expr(ctx, arg, scope) {
            return Some(ty);
        }
        let _ = analyse_expr(ctx, arg, scope);
        ctx.error(expr_span(arg), "builtin type argument must name a type");
        return None;
    };
    if !designator.selectors.is_empty() {
        // Qualified type name (e.g. `SYSTEM.ADDRESS`, `EXCEPTIONS.ExceptionNumber`):
        // rebuild the QualName and resolve it like any `Mod.Type` reference.
        let mut segments = designator.base.segments.clone();
        for sel in &designator.selectors {
            let ast::Selector::Field(name, _) = sel else {
                ctx.error(expr_span(arg), "builtin type argument must name a type");
                return None;
            };
            segments.push(name.clone());
        }
        let qn = ast::QualName { segments, span: designator.span };
        return Some(resolve_type_name(ctx, &qn, scope));
    }

    match resolve_symbol(ctx, &designator.base, scope).map(|sym| sym.kind) {
        Some(SymbolKind::Type(ty)) => Some(ty),
        Some(SymbolKind::Class(cid)) => Some(ctx.classes.get(cid).type_id),
        Some(_) if allow_value => {
            // `MIN(v)` / `MAX(v)` — the operand is a variable (or other typed
            // value); its bounds come from the operand's type.
            analyse_expr(ctx, arg, scope)
        }
        Some(_) => {
            ctx.error(expr_span(arg), "builtin type argument must name a type");
            None
        }
        None => None,
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ValScalarClass {
    Whole,
    Real,
    Char,
    Boolean,
    Enumeration,
}

fn val_scalar_class(ctx: &Ctx, ty: TypeId) -> Option<ValScalarClass> {
    match ctx.types.get(ty) {
        TypeKind::Subrange { host, .. } => val_scalar_class(ctx, *host),
        TypeKind::Enum { .. } => Some(ValScalarClass::Enumeration),
        // A set/BITSET converts to/from a whole number as its underlying
        // bit-pattern word (PIM `VAL(CARDINAL, someSet)`).
        TypeKind::Set { .. } => Some(ValScalarClass::Whole),
        TypeKind::Builtin(b) => match b {
            Builtin::Integer
            | Builtin::LongInt
            | Builtin::Integer8
            | Builtin::Integer16
            | Builtin::Integer32
            | Builtin::Integer64
            | Builtin::Cardinal
            | Builtin::LongCard
            | Builtin::Cardinal8
            | Builtin::Cardinal16
            | Builtin::Cardinal32
            | Builtin::Cardinal64
            | Builtin::Byte
            | Builtin::Word
            | Builtin::Dword
            | Builtin::Qword
            | Builtin::SysWord
            | Builtin::SysByte
            | Builtin::SysLoc
            | Builtin::Bitset
            | Builtin::SysBitset => Some(ValScalarClass::Whole),
            Builtin::Real | Builtin::LongReal | Builtin::Real32 | Builtin::Real16 => {
                Some(ValScalarClass::Real)
            }
            Builtin::Char | Builtin::Achar | Builtin::Uchar => Some(ValScalarClass::Char),
            Builtin::Boolean => Some(ValScalarClass::Boolean),
            _ => None,
        },
        _ => None,
    }
}

/// A pointer/procedure/ADDRESS-family type — the operands of an address-width
/// transfer. Mirrors the IR's `is_pointer_like` (classify_transfer_cast), which
/// already lowers these conversions to BitCast / IntToPtr / PtrToInt.
fn is_val_pointer_like(ctx: &Ctx, ty: TypeId) -> bool {
    match ctx.types.get(ty) {
        TypeKind::Pointer { .. } | TypeKind::Proc { .. } => true,
        // `Proc` is the generic PROCEDURE type a bare procedure reference takes
        // (e.g. `VAL(ADDRESS, foo)`); it is a code address like any pointer.
        TypeKind::Builtin(b) => matches!(
            b,
            Builtin::Proc
                | Builtin::Address
                | Builtin::SysAddress
                | Builtin::Adrint
                | Builtin::Adrcard
                | Builtin::Nil
        ),
        _ => false,
    }
}

fn val_conversion_allowed(ctx: &Ctx, target_ty: TypeId, source_ty: TypeId) -> bool {
    // Pointer-family transfer (PIM/ISO): VAL(ADDRESS, proc), VAL(procType,
    // procValue), VAL(PtrToX, intValue). A pointer/proc/ADDRESS on either side
    // transfers to/from another pointer-like type, or to/from a whole-number
    // value (address arithmetic) — never to/from Real/Char/Boolean/Enumeration.
    let target_ptr = is_val_pointer_like(ctx, target_ty);
    let source_ptr = is_val_pointer_like(ctx, source_ty);
    if target_ptr && source_ptr {
        return true;
    }
    if target_ptr {
        return matches!(val_scalar_class(ctx, source_ty), Some(ValScalarClass::Whole));
    }
    if source_ptr {
        return matches!(val_scalar_class(ctx, target_ty), Some(ValScalarClass::Whole));
    }

    let Some(target_class) = val_scalar_class(ctx, target_ty) else {
        return false;
    };
    let Some(source_class) = val_scalar_class(ctx, source_ty) else {
        return false;
    };

    match target_class {
        ValScalarClass::Whole => matches!(
            source_class,
            ValScalarClass::Whole
                | ValScalarClass::Real
                | ValScalarClass::Char
                | ValScalarClass::Boolean
                | ValScalarClass::Enumeration
        ),
        ValScalarClass::Real => matches!(source_class, ValScalarClass::Whole | ValScalarClass::Real),
        ValScalarClass::Char => matches!(source_class, ValScalarClass::Whole | ValScalarClass::Char),
        ValScalarClass::Boolean => matches!(source_class, ValScalarClass::Whole | ValScalarClass::Boolean),
        ValScalarClass::Enumeration => {
            matches!(source_class, ValScalarClass::Whole | ValScalarClass::Enumeration)
        }
    }
}

fn analyse_builtin_call(
    ctx: &mut Ctx,
    callee: &ast::Expr,
    args: &[ast::Expr],
    span: Span,
    scope: ScopeId,
) -> Option<Option<TypeId>> {
    let ast::Expr::Designator(designator) = callee else {
        return None;
    };

    let is_intrinsic_module = |m: &str| m == "SYSTEM" || m == "COROUTINES";
    let builtin_name = match designator.base.segments.as_slice() {
        [name] if designator.selectors.is_empty() => name.as_str(),
        [module, name] if designator.selectors.is_empty() && is_intrinsic_module(module) => {
            name.as_str()
        }
        [module]
            if is_intrinsic_module(module)
                && matches!(designator.selectors.as_slice(), [ast::Selector::Field(_, _)]) =>
        {
            match &designator.selectors[0] {
                ast::Selector::Field(name, _) => name.as_str(),
                _ => unreachable!(),
            }
        }
        _ => return None,
    };

    match builtin_name {
        "VAL" | "CAST" => {
            if args.len() != 2 {
                ctx.error(
                    span,
                    format!("{} requires two arguments", builtin_name),
                );
                for arg in args {
                    let _ = analyse_expr(ctx, arg, scope);
                }
                return Some(None);
            }

            let target_ty = resolve_builtin_type_arg(ctx, &args[0], scope, false);
            let source_ty = analyse_expr(ctx, &args[1], scope);
            // A SIMD vector is not (yet) VAL/CAST-convertible — reject before the
            // transfer-cast machinery (which has no vector path) reaches codegen.
            if target_ty.is_some_and(|t| is_vector_type(ctx, t))
                || source_ty.is_some_and(|t| is_vector_type(ctx, t))
            {
                ctx.error(
                    span,
                    format!("{builtin_name} does not support SIMD vector operands"),
                );
            } else if builtin_name == "VAL"
                && let (Some(target_ty), Some(source_ty)) = (target_ty, source_ty)
                && !val_conversion_allowed(ctx, target_ty, source_ty)
            {
                ctx.error(
                    expr_span(&args[1]),
                    "VAL requires an ISO-compatible scalar conversion",
                );
            }
            Some(target_ty)
        }

        // ---- Allocation / mutation pseudo-procedures (no result) -------------
        "NEW" | "DISPOSE" | "DESTROY" => {
            if args.is_empty() {
                ctx.error(span, format!("{builtin_name} requires a pointer argument"));
                return Some(None);
            }
            let first_ty = analyse_expr(ctx, &args[0], scope);
            if !matches!(args[0], ast::Expr::Designator(_)) {
                ctx.error(
                    expr_span(&args[0]),
                    format!("{builtin_name} requires a variable designator"),
                );
            } else if let Some(ty) = first_ty
                && !matches!(
                    ctx.types.get(ty),
                    TypeKind::Pointer { .. } | TypeKind::Class { .. }
                )
            {
                // A class variable is a reference, so NEW(obj) / DISPOSE(obj)
                // on a class type is valid (allocates / frees the instance).
                ctx.error(
                    expr_span(&args[0]),
                    format!("{builtin_name} requires a POINTER or class argument"),
                );
            }
            // Extra args (ISO variant-tag / open-array bound forms) are
            // analysed but not otherwise constrained here.
            for arg in &args[1..] {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(None)
        }
        // SYSTEM.THROW(n) — raise an exception with number `n`; no result.
        "THROW" => {
            if args.len() != 1 {
                ctx.error(span, "THROW requires one argument");
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(None)
        }
        "INC" | "DEC" => {
            if args.is_empty() || args.len() > 2 {
                ctx.error(span, format!("{builtin_name} expects 1 or 2 arguments"));
            }
            if let Some(first) = args.first()
                && !matches!(first, ast::Expr::Designator(_))
            {
                ctx.error(expr_span(first), format!("{builtin_name} requires a variable designator"));
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(None)
        }
        "INCL" | "EXCL" => {
            if args.len() != 2 {
                ctx.error(span, format!("{builtin_name} expects 2 arguments"));
            }
            if let Some(first) = args.first()
                && !matches!(first, ast::Expr::Designator(_))
            {
                ctx.error(expr_span(first), format!("{builtin_name} requires a SET variable designator"));
            }
            let set_ty = args.first().and_then(|a| analyse_expr(ctx, a, scope));
            let elem_ty = args.get(1).and_then(|a| analyse_expr(ctx, a, scope));
            // The added/removed element must be compatible with the set's base
            // (element) type — `INCL(charSet, 1)` etc. is a type error.
            if let (Some(set_ty), Some(elem_ty)) = (set_ty, elem_ty) {
                let base = match ctx.types.get(set_ty) {
                    TypeKind::Set { base, .. } => Some(*base),
                    TypeKind::Builtin(Builtin::Bitset | Builtin::SysBitset) => {
                        Some(ctx.types.builtin(Builtin::Integer))
                    }
                    _ => None,
                };
                if let Some(base) = base
                    && !expr_compatible_with_type(ctx, base, &args[1], elem_ty)
                {
                    ctx.error(
                        expr_span(&args[1]),
                        format!("{builtin_name} element type is incompatible with the set's base type"),
                    );
                }
            }
            Some(None)
        }
        "HALT" => {
            if args.len() > 1 {
                ctx.error(span, "HALT expects 0 or 1 arguments");
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(None)
        }
        "ASSERT" => {
            if args.is_empty() || args.len() > 2 {
                ctx.error(span, "ASSERT expects 1 or 2 arguments");
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(None)
        }

        // SYSTEM.NEWPROCESS(P, workspace, size, VAR cor) — create a coroutine
        // running P. SYSTEM.TRANSFER(VAR from, to) — switch coroutines. Both
        // return no value.
        "NEWPROCESS" => {
            if args.len() != 4 {
                ctx.error(span, "NEWPROCESS expects 4 arguments (proc, workspace, size, VAR cor)");
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(None)
        }
        "TRANSFER" => {
            if args.len() != 2 {
                ctx.error(span, "TRANSFER expects 2 arguments (VAR from, to)");
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(None)
        }
        // ISO COROUTINES.NEWCOROUTINE(body, ws, size, VAR cor [, protection]).
        "NEWCOROUTINE" => {
            if args.len() != 4 && args.len() != 5 {
                ctx.error(span, "NEWCOROUTINE expects 4 or 5 arguments");
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(None)
        }
        // ISO COROUTINES.CURRENT() -> COROUTINE.
        "CURRENT" => {
            if !args.is_empty() {
                ctx.error(span, "CURRENT expects no arguments");
            }
            Some(Some(ctx.types.builtin(Builtin::SysAddress)))
        }

        // SHIFT(v, n) / ROTATE(v, n) — bit shift / rotation of `v`; result has
        // the type of `v`.
        "SHIFT" | "ROTATE" => {
            if args.len() != 2 {
                ctx.error(span, format!("{builtin_name} expects 2 arguments"));
            }
            let val_ty = args.first().and_then(|a| analyse_expr(ctx, a, scope));
            if let Some(count) = args.get(1) {
                let _ = analyse_expr(ctx, count, scope);
            }
            Some(Some(val_ty.unwrap_or_else(|| ctx.types.builtin(Builtin::Word))))
        }

        // ---- SYSTEM address pseudo-functions --------------------------------
        "ADR" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Address))),
        // ADDADR(a,n) / SUBADR(a,n) take an address + a displacement -> ADDRESS.
        "ADDADR" | "SUBADR" => {
            if args.len() != 2 {
                ctx.error(span, "ADDADR/SUBADR expect 2 arguments");
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(Some(ctx.types.builtin(Builtin::Address)))
        }
        // DIFADR(a,b) is the signed byte difference of two addresses -> ADRINT.
        "DIFADR" => {
            if args.len() != 2 {
                ctx.error(span, "DIFADR expects 2 arguments");
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(Some(ctx.types.builtin(Builtin::Adrint)))
        }
        // MAKEADR(v, …) builds an ADDRESS from one or more values.
        "MAKEADR" => {
            if args.is_empty() {
                ctx.error(span, "MAKEADR expects at least 1 argument");
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(Some(ctx.types.builtin(Builtin::Address)))
        }
        // ---- Value-returning ordinal / arithmetic pseudo-functions ----------
        "ORD" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Cardinal))),
        "CHR" | "CAP" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Char))),
        "ODD" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Boolean))),
        // COM HRESULT severity test: FAILED(h) = (h AND 80000000H) # 0, SUCCEEDED
        // its negation. One canonical helper retires the hand-written hr<0 (direct
        // call) vs (hr BAND 80000000H)#0 (virtual call) split.
        "SUCCEEDED" | "FAILED" => {
            Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Boolean)))
        }
        "FLOAT" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Real))),
        "LFLOAT" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::LongReal))),
        "TRUNC" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Cardinal))),
        "INT" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Integer))),
        "ENTIER" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::LongInt))),
        "HIGH" | "LEN" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Cardinal))),
        "LENGTH" => Some(Some(simple_builtin_call(ctx, args, span, scope, Builtin::Cardinal))),
        // ---- COMPLEX pseudo-functions ---------------------------------------
        // RE/IM extract the (LONG)REAL parts; CMPLX builds a (LONG)COMPLEX.
        // COMPLEX and LONGCOMPLEX share the {f64,f64} representation, so RE/IM
        // yield REAL and CMPLX yields COMPLEX; the families are interchangeable.
        "RE" | "IM" => {
            let comp = args.first().and_then(|a| analyse_expr(ctx, a, scope));
            let result = match comp.map(|t| ctx.types.get(t)) {
                Some(TypeKind::Builtin(Builtin::LongComplex)) => Builtin::LongReal,
                _ => Builtin::Real,
            };
            if args.len() != 1 {
                ctx.error(span, "RE/IM expects 1 argument");
            }
            Some(Some(ctx.types.builtin(result)))
        }
        "CMPLX" => {
            let first = args.first().and_then(|a| analyse_expr(ctx, a, scope));
            for arg in args.iter().skip(1) {
                let _ = analyse_expr(ctx, arg, scope);
            }
            let result = match first.map(|t| ctx.types.get(t)) {
                Some(TypeKind::Builtin(Builtin::LongReal)) => Builtin::LongComplex,
                _ => Builtin::Complex,
            };
            if args.len() != 2 {
                ctx.error(span, "CMPLX expects 2 arguments");
            }
            Some(Some(ctx.types.builtin(result)))
        }
        "ABS" => {
            // ABS preserves a numeric argument's type; fall back to INTEGER.
            let arg_ty = args
                .first()
                .and_then(|arg| analyse_expr(ctx, arg, scope))
                .unwrap_or_else(|| ctx.types.builtin(Builtin::Integer));
            if args.len() != 1 {
                ctx.error(span, "ABS expects 1 argument");
            }
            for arg in args.iter().skip(1) {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(Some(arg_ty))
        }
        "SIZE" | "TSIZE" | "TBITSIZE" => {
            // The argument must name a type or a variable (a designator), not a
            // literal or computed value — `SIZE(1)` is a type error.
            if let Some(arg) = args.first()
                && !matches!(arg, ast::Expr::Designator(_))
            {
                ctx.error(
                    expr_span(arg),
                    format!("{builtin_name} requires a type name or a variable"),
                );
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            Some(Some(ctx.types.builtin(Builtin::Cardinal)))
        }
        "MIN" | "MAX" => {
            // MIN(T) / MAX(T): result has the element type T. For a SET type
            // the result ranges over the set's element (base) type, e.g.
            // `MAX(SET OF [0..127])` is `127`, typed as `[0..127]`.
            let mut ty = args
                .first()
                .and_then(|arg| resolve_builtin_type_arg(ctx, arg, scope, true))
                .unwrap_or_else(|| ctx.types.builtin(Builtin::Integer));
            ty = match ctx.types.get(ty) {
                TypeKind::Set { base, .. } => *base,
                TypeKind::Builtin(Builtin::Bitset | Builtin::SysBitset) => {
                    ctx.types.builtin(Builtin::Cardinal)
                }
                _ => ty,
            };
            if args.len() != 1 {
                ctx.error(span, format!("{builtin_name} expects 1 argument"));
            }
            Some(Some(ty))
        }
        "SUM" => {
            // SUM(v) — horizontal add of a vector's lanes → the lane scalar type.
            let arg_ty = args.first().and_then(|a| analyse_expr(ctx, a, scope));
            if args.len() != 1 {
                ctx.error(span, "SUM expects 1 argument");
            }
            for a in args.iter().skip(1) {
                let _ = analyse_expr(ctx, a, scope);
            }
            let base = arg_ty.and_then(|t| match ctx.types.get(t) {
                TypeKind::Vector { base, .. } => Some(*base),
                _ => None,
            });
            match base {
                Some(b) => Some(Some(b)),
                None => {
                    ctx.error(span, "SUM requires a SIMD vector argument");
                    Some(Some(ctx.types.builtin(Builtin::Real)))
                }
            }
        }
        "DOT" => {
            // DOT(a, b) — dot product of two same-typed vectors → lane scalar.
            let a_ty = args.first().and_then(|a| analyse_expr(ctx, a, scope));
            let b_ty = args.get(1).and_then(|a| analyse_expr(ctx, a, scope));
            if args.len() != 2 {
                ctx.error(span, "DOT expects 2 arguments");
            }
            for a in args.iter().skip(2) {
                let _ = analyse_expr(ctx, a, scope);
            }
            let base = a_ty.and_then(|t| match ctx.types.get(t) {
                TypeKind::Vector { base, .. } => Some(*base),
                _ => None,
            });
            match base {
                Some(b) => {
                    if a_ty != b_ty {
                        ctx.error(span, "DOT requires two vectors of the same type");
                    }
                    Some(Some(b))
                }
                None => {
                    ctx.error(span, "DOT requires two SIMD vector arguments");
                    Some(Some(ctx.types.builtin(Builtin::Real)))
                }
            }
        }
        "FMA" => {
            // FMA(a, b, c) — fused lane-wise a*b + c → the vector type.
            let tys: Vec<Option<TypeId>> =
                args.iter().map(|a| analyse_expr(ctx, a, scope)).collect();
            if args.len() != 3 {
                ctx.error(span, "FMA expects 3 arguments");
            }
            let vty = tys.first().copied().flatten();
            if vty.is_some_and(|t| is_vector_type(ctx, t)) {
                let mismatch = tys.iter().skip(1).any(|t| *t != vty);
                if mismatch {
                    ctx.error(span, "FMA requires three vectors of the same type");
                }
                Some(Some(vty.unwrap()))
            } else {
                ctx.error(span, "FMA requires SIMD vector arguments");
                Some(Some(ctx.types.builtin(Builtin::Real)))
            }
        }
        _ => None,
    }
}

/// Analyse the arguments of a single-argument value-returning builtin and
/// return the fixed `result` type. Emits an arity error when the call does
/// not have exactly one argument, but still analyses every argument so
/// nested diagnostics surface.
fn simple_builtin_call(
    ctx: &mut Ctx,
    args: &[ast::Expr],
    span: Span,
    scope: ScopeId,
    result: Builtin,
) -> TypeId {
    if args.len() != 1 {
        ctx.error(span, "builtin expects 1 argument");
    }
    for arg in args {
        let _ = analyse_expr(ctx, arg, scope);
    }
    ctx.types.builtin(result)
}

fn analyse_expr(ctx: &mut Ctx, expr: &ast::Expr, scope: ScopeId) -> Option<TypeId> {
    match expr {
        ast::Expr::Integer(_, _) => {
            let ty = ctx.types.builtin(Builtin::Integer);
            annotate_expr(ctx, expr, ty);
            Some(ty)
        }
        ast::Expr::Real(_, _) => {
            let ty = ctx.types.builtin(Builtin::Real);
            annotate_expr(ctx, expr, ty);
            Some(ty)
        }
        ast::Expr::Char(lit, _) => {
            let ty = match lit.flavor {
                LiteralFlavor::Default => ctx.types.builtin(Builtin::Char),
                LiteralFlavor::Achar => ctx.types.builtin(Builtin::Achar),
                LiteralFlavor::Uchar => ctx.types.builtin(Builtin::Uchar),
            };
            annotate_expr(ctx, expr, ty);
            Some(ty)
        }
        ast::Expr::String(lit, _) => {
            // Windows-wide default: plain "..." is ARRAY OF CHAR (wide / UTF-16);
            // explicit ACHAR stays narrow.
            let ty = match lit.flavor {
                LiteralFlavor::Default => ctx.types.builtin(Builtin::Char),
                LiteralFlavor::Achar => ctx.types.builtin(Builtin::Achar),
                LiteralFlavor::Uchar => ctx.types.builtin(Builtin::Uchar),
            };
            annotate_expr(ctx, expr, ty);
            Some(ty)
        }
        ast::Expr::Nil(_) => {
            let ty = ctx.types.builtin(Builtin::Nil);
            annotate_expr(ctx, expr, ty);
            Some(ty)
        }
        ast::Expr::Designator(designator) => analyse_designator(ctx, designator, scope),
        ast::Expr::Call(callee, args, span) => {
            if let Some(result_ty) = analyse_unimplemented_intrinsic_call(ctx, callee, args, *span, scope) {
                return result_ty;
            }
            if let Some(result_ty) = analyse_builtin_call(ctx, callee, args, *span, scope) {
                if let Some(ty) = result_ty {
                    ctx.note_expr_type(*span, ty);
                }
                return result_ty;
            }

            // `T(x)` where T names a scalar type is a value conversion
            // (equivalent to `VAL(T, x)`): the result has type T. Without this
            // the call falls through to the generic path and is lowered as a
            // call to a non-existent function `@T`.
            if args.len() == 1
                && let ast::Expr::Designator(_) = callee.as_ref()
                && let Some(target) = quiet_type_arg(ctx, callee.as_ref(), scope)
                && is_scalar_convertible_type(ctx, target)
            {
                let _ = analyse_expr(ctx, &args[0], scope);
                ctx.note_expr_type(*span, target);
                return Some(target);
            }

            let callee_sig = match callee.as_ref() {
                ast::Expr::Designator(designator) => resolve_designator_proc_sig(ctx, designator, scope),
                _ => None,
            };
            let callee_ty = analyse_expr(ctx, callee, scope);
            // Virtual method call: `obj.M(args)` — `analyse_expr(callee)` tagged
            // the method selector with a Method binding; pull the method's
            // signature from the class vtable to check the arguments.
            if callee_sig.is_none() {
                if let ast::Expr::Designator(d) = callee.as_ref() {
                    if let Some(msig) = method_sig_from_designator(ctx, d) {
                        analyse_call_args(ctx, args, &msig, *span, scope);
                        if let Some(return_ty) = msig.return_ty {
                            ctx.note_expr_type(*span, return_ty);
                            return Some(return_ty);
                        }
                        return None;
                    }
                }
            }
            if let Some(sig) = callee_sig {
                analyse_call_args(ctx, args, &sig, *span, scope);
                if let Some(return_ty) = sig.return_ty {
                    ctx.note_expr_type(*span, return_ty);
                    return Some(return_ty);
                }
                return None;
            }
            for arg in args {
                let _ = analyse_expr(ctx, arg, scope);
            }
            if let Some(callee_ty) = callee_ty {
                if let TypeKind::Proc { return_ty, .. } = ctx.types.get(callee_ty) {
                    if let Some(return_ty) = *return_ty {
                        ctx.note_expr_type(*span, return_ty);
                        return Some(return_ty);
                    }
                } else if matches!(ctx.types.get(callee_ty), TypeKind::Builtin(Builtin::Nil)) {
                    // `NIL` is a constant, not a procedure: `NIL(x)` is not a call.
                    ctx.error(*span, "NIL is not a procedure and cannot be called");
                }
            }
            None
        }
        ast::Expr::Unary(op, inner, _) => {
            let inner_ty = analyse_expr(ctx, inner, scope)?;
            let result_ty = match op {
                ast::UnaryOp::Pos | ast::UnaryOp::Neg => {
                    if !is_numeric_type(ctx, inner_ty) {
                        ctx.error(expr_span(inner), "unary +/- requires a numeric operand");
                    }
                    inner_ty
                }
                ast::UnaryOp::Not => {
                    if !is_boolean_type(ctx, inner_ty) {
                        ctx.error(expr_span(inner), "NOT requires a BOOLEAN operand");
                    }
                    ctx.types.builtin(Builtin::Boolean)
                }
            };
            annotate_expr(ctx, expr, result_ty);
            Some(result_ty)
        }
        ast::Expr::Binary(op, lhs, rhs, _) => {
            let lhs_ty = analyse_expr(ctx, lhs, scope)?;
            let rhs_ty = analyse_expr(ctx, rhs, scope)?;
            let result_ty = match op {
                ast::BinaryOp::Eq
                | ast::BinaryOp::Ne
                | ast::BinaryOp::Lt
                | ast::BinaryOp::Le
                | ast::BinaryOp::Gt
                | ast::BinaryOp::Ge => {
                    // A set may only be compared with another set; comparing a
                    // set with a non-set operand is a type error per the ISO
                    // spec. Numeric and other comparisons keep the dialect's
                    // existing leniency.
                    if is_set_type(ctx, lhs_ty) != is_set_type(ctx, rhs_ty) {
                        ctx.error(
                            expr_span(expr),
                            "cannot compare a set with a non-set value",
                        );
                    }
                    // SIMD vectors have no scalar ordering/equality (a lane-wise
                    // compare would need a mask type) — reject before codegen.
                    if is_vector_type(ctx, lhs_ty) || is_vector_type(ctx, rhs_ty) {
                        ctx.error(
                            expr_span(expr),
                            "SIMD vectors cannot be compared with a relational operator",
                        );
                    }
                    // A procedure value may only be compared with another
                    // procedure value or NIL — `x = 0` for a PROCEDURE x is a
                    // type error (badxproc).
                    let is_proc = |t| matches!(ctx.types.get(t), TypeKind::Proc { .. });
                    let is_nil = |t| matches!(ctx.types.get(t), TypeKind::Builtin(Builtin::Nil));
                    if is_proc(lhs_ty) != is_proc(rhs_ty) && !is_nil(lhs_ty) && !is_nil(rhs_ty) {
                        ctx.error(
                            expr_span(expr),
                            "cannot compare a procedure value with a non-procedure value",
                        );
                    }
                    ctx.types.builtin(Builtin::Boolean)
                }
                ast::BinaryOp::In => {
                    // `e IN s`: the left operand is the element tested for
                    // membership and must not itself be a set (badifin).
                    if is_set_type(ctx, lhs_ty) {
                        ctx.error(
                            expr_span(lhs),
                            "the left operand of IN must be an element, not a set",
                        );
                    }
                    ctx.types.builtin(Builtin::Boolean)
                }
                ast::BinaryOp::And | ast::BinaryOp::Or => {
                    if !is_boolean_type(ctx, lhs_ty) || !is_boolean_type(ctx, rhs_ty) {
                        ctx.error(expr_span(expr), "logical operators require BOOLEAN operands");
                    }
                    ctx.types.builtin(Builtin::Boolean)
                }
                ast::BinaryOp::Bor
                | ast::BinaryOp::Band
                | ast::BinaryOp::Bxor
                | ast::BinaryOp::Shl
                | ast::BinaryOp::Shr => {
                    if !is_integer_family_type(ctx, lhs_ty) || !is_integer_family_type(ctx, rhs_ty) {
                        ctx.error(expr_span(expr), "bitwise operators require integer-family operands");
                    }
                    lhs_ty
                }
                ast::BinaryOp::Add
                | ast::BinaryOp::Sub
                | ast::BinaryOp::Mul
                | ast::BinaryOp::Div
                | ast::BinaryOp::DivKw
                | ast::BinaryOp::Mod
                | ast::BinaryOp::Rem => {
                    if matches!(op, ast::BinaryOp::Add)
                        && is_char_or_string_type(ctx, lhs_ty)
                        && is_char_or_string_type(ctx, rhs_ty)
                        && const_string_of(ctx, lhs, scope).is_some()
                        && const_string_of(ctx, rhs, scope).is_some()
                    {
                        // *Constant* string/char concatenation: `'a' + 'b'`,
                        // `"ab" + 'c'`. `+` is never arithmetic on characters in
                        // Modula-2, so two char/string constants concatenate,
                        // yielding a string (the constant folder builds the
                        // value; the IR fast path expands the same set). A
                        // runtime char/string `+` is NOT concatenation here — it
                        // falls through to the numeric check below and is
                        // rejected, rather than being mis-typed and then
                        // miscompiled/crashed by the lowering.
                        ctx.types.builtin(Builtin::Achar)
                    } else if matches!(
                        op,
                        ast::BinaryOp::Add | ast::BinaryOp::Sub | ast::BinaryOp::Mul | ast::BinaryOp::Div
                    ) && is_set_type(ctx, lhs_ty)
                        && is_set_type(ctx, rhs_ty)
                    {
                        if !types_compatible(ctx, lhs_ty, rhs_ty) {
                            ctx.error(expr_span(expr), "set operators require compatible set operands");
                        }
                        lhs_ty
                    } else if matches!(
                        op,
                        ast::BinaryOp::Add | ast::BinaryOp::Sub | ast::BinaryOp::Mul | ast::BinaryOp::Div
                    ) && (is_vector_type(ctx, lhs_ty) || is_vector_type(ctx, rhs_ty))
                    {
                        // SIMD lane arithmetic. vec⊕vec needs identical vector
                        // types; vec⊕scalar broadcasts a real scalar to every lane.
                        let lhs_vec = is_vector_type(ctx, lhs_ty);
                        let rhs_vec = is_vector_type(ctx, rhs_ty);
                        let vec_ty = if lhs_vec { lhs_ty } else { rhs_ty };
                        if lhs_vec && rhs_vec {
                            if lhs_ty != rhs_ty {
                                ctx.error(expr_span(expr), "SIMD vector operands must have the same type");
                            }
                        } else {
                            let scalar = if lhs_vec { rhs_ty } else { lhs_ty };
                            if !is_real_type(ctx, scalar) {
                                ctx.error(
                                    expr_span(expr),
                                    "a vector combines only with the same vector type or a real scalar (broadcast)",
                                );
                            }
                        }
                        vec_ty
                    } else {
                        if !is_numeric_type(ctx, lhs_ty) || !is_numeric_type(ctx, rhs_ty) {
                            ctx.error(expr_span(expr), "arithmetic operators require numeric operands");
                        }
                        if types_compatible(ctx, lhs_ty, rhs_ty) {
                            lhs_ty
                        } else if is_integer_family_type(ctx, lhs_ty)
                            && is_integer_family_type(ctx, rhs_ty)
                        {
                            // Mixed integer families (e.g. `CARDINAL64 + INTEGER`,
                            // `n + 9`) stay integer-family in this ADW-lenient
                            // dialect — never promote to REAL. Prefer the
                            // non-literal operand's type so a sized variable keeps
                            // its width.
                            if is_integer_literal(lhs) { rhs_ty } else { lhs_ty }
                        } else {
                            ctx.types.builtin(Builtin::Real)
                        }
                    }
                }
            };
            annotate_expr(ctx, expr, result_ty);
            Some(result_ty)
        }
        ast::Expr::Set {
            type_name,
            elements,
            span,
        } => {
            // `type_name` (e.g. `CharSet` in `CharSet{...}`) names the SET
            // type; elements are checked against its *element* type, not the
            // set type itself.
            let declared = type_name
                .as_ref()
                .map(|name| resolve_type_name(ctx, name, scope));

            // `T{...}` where T is a RECORD or ARRAY is a *structured aggregate*
            // constructor (positional field / element values), not a set
            // constructor: check each value against the corresponding field or
            // element type and yield T.
            let structured = declared.and_then(|ty| match ctx.types.get(ty) {
                TypeKind::Record(_)
                | TypeKind::Array { .. }
                | TypeKind::OpenArray { .. }
                | TypeKind::Vector { .. } => Some(ty),
                _ => None,
            });
            if let Some(ty) = structured {
                let field_tys: Vec<TypeId> = match ctx.types.get(ty) {
                    TypeKind::Record(layout) => {
                        layout.flatten_fields().into_iter().map(|(_, t)| t).collect()
                    }
                    _ => Vec::new(),
                };
                let elem_ty = match ctx.types.get(ty) {
                    TypeKind::Array { base, .. } | TypeKind::OpenArray { base } => Some(*base),
                    TypeKind::Vector { base, .. } => Some(*base),
                    _ => None,
                };
                // A `REAL32X4{…}` constructor takes either 1 element (broadcast to
                // every lane) or exactly `lanes` elements (one per lane).
                if let TypeKind::Vector { lanes, .. } = ctx.types.get(ty) {
                    let lanes = *lanes as usize;
                    if elements.len() != 1 && elements.len() != lanes {
                        ctx.error(
                            *span,
                            format!(
                                "vector constructor needs 1 (broadcast) or {lanes} elements, got {}",
                                elements.len()
                            ),
                        );
                    }
                }
                for (i, elem) in elements.iter().enumerate() {
                    match elem {
                        ast::SetElem::Single(value) => {
                            if let Some(value_ty) = analyse_expr(ctx, value, scope) {
                                let expect = elem_ty.or_else(|| field_tys.get(i).copied());
                                if let Some(expect) = expect {
                                    if !expr_compatible_with_type(ctx, expect, value, value_ty) {
                                        ctx.error(
                                            expr_span(value),
                                            "aggregate constructor element type is incompatible",
                                        );
                                    }
                                }
                            }
                        }
                        ast::SetElem::Range(lo, hi) => {
                            // Not meaningful in a record/array constructor; type
                            // the operands but do not impose set-element rules.
                            analyse_expr(ctx, lo, scope);
                            analyse_expr(ctx, hi, scope);
                        }
                    }
                }
                ctx.note_expr_type(*span, ty);
                return Some(ty);
            }

            let base = match declared {
                Some(ty) => match ctx.types.get(ty) {
                    TypeKind::Set { base, .. } => *base,
                    // BITSET / SYSTEM.BITSET is a set of small whole numbers;
                    // its elements are integer-valued (e.g. `BITSET{3}`).
                    TypeKind::Builtin(Builtin::Bitset | Builtin::SysBitset) => {
                        ctx.types.builtin(Builtin::Integer)
                    }
                    _ => ty,
                },
                None => ctx.types.builtin(Builtin::Integer),
            };
            for elem in elements {
                match elem {
                    ast::SetElem::Single(value) => {
                        if let Some(value_ty) = analyse_expr(ctx, value, scope) {
                            if !expr_compatible_with_type(ctx, base, value, value_ty) {
                                ctx.error(expr_span(value), "set element type is incompatible with set base type");
                            }
                        }
                    }
                    ast::SetElem::Range(lo, hi) => {
                        let lo_ty = analyse_expr(ctx, lo, scope);
                        let hi_ty = analyse_expr(ctx, hi, scope);
                        if let Some(lo_ty) = lo_ty {
                            if !expr_compatible_with_type(ctx, base, lo, lo_ty) {
                                ctx.error(expr_span(lo), "set range lower bound has incompatible type");
                            }
                        }
                        if let Some(hi_ty) = hi_ty {
                            if !expr_compatible_with_type(ctx, base, hi, hi_ty) {
                                ctx.error(expr_span(hi), "set range upper bound has incompatible type");
                            }
                        }
                    }
                }
            }
            // The constructor's type is the declared SET type when named
            // (so `s := CharSet{...}` matches `s`'s type); otherwise a fresh
            // SET of the inferred element type.
            let ty = match declared {
                Some(ty) if matches!(ctx.types.get(ty), TypeKind::Set { .. }) => ty,
                _ => ctx.types.alloc(TypeKind::Set { packed: false, base }),
            };
            ctx.note_expr_type(*span, ty);
            Some(ty)
        }
    }
}

fn check_condition(ctx: &mut Ctx, expr: &ast::Expr, scope: ScopeId) {
    if let Some(ty) = analyse_expr(ctx, expr, scope) {
        if !is_boolean_type(ctx, ty) {
            ctx.error(expr_span(expr), "condition must have BOOLEAN type");
        }
    }
}

fn analyse_block(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    block: &ast::Block,
    scope: ScopeId,
    return_ty: Option<TypeId>,
) {
    analyse_stmts(ctx, graph, mid, &block.stmts, scope, return_ty);
    for arm in &block.except {
        analyse_stmts(ctx, graph, mid, &arm.body, scope, return_ty);
    }
    if let Some(finally_body) = &block.finally {
        analyse_stmts(ctx, graph, mid, finally_body, scope, return_ty);
    }
}

// ---- Procedure body analysis ---------------------------------------------

fn analyse_proc_body(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    p: &ast::ProcDecl,
    body: &ast::ProcBody,
    parent_scope: ScopeId,
    sig: &ProcSig,
) {
    let proc_scope = ctx.scopes.push(ScopeKind::Procedure, Some(parent_scope));
    ctx.proc_scopes.insert((mid, p.name.clone()), proc_scope);

    // Register parameters.
    for param in &p.params {
        let ty = form_type_expr(ctx, graph, mid, &param.ty, proc_scope);
        let mode = match param.mode {
            ast::ParamMode::Var => ParamMode::Var,
            ast::ParamMode::Const => ParamMode::Const,
            ast::ParamMode::Value => ParamMode::Value,
        };
        for name in &param.names {
            let declaration_id = ctx.fresh_declaration_id();
            let binding_id = ctx.fresh_binding_id();
            ctx.scopes.get_mut(proc_scope).insert(Symbol {
                name: name.clone(),
                kind: SymbolKind::Var {
                    ty,
                    param_mode: Some(mode),
                },
                span: param.span,
                declaration_id,
                binding_id,
                provenance: SymbolProvenance::Declared {
                    module: ctx.current_module,
                    module_name: ctx.current_module_name.clone(),
                },
                exported: false,
            });
        }
        let _ = mode;
    }

    // Declarations in the body. We are already in the body phase, so nested
    // procedures' bodies are analysed here too.
    for decl in &body.decls {
        pass1_decl(ctx, decl, proc_scope);
    }
    for decl in &body.decls {
        pass2_decl(ctx, graph, mid, decl, proc_scope, true);
    }

    analyse_block(ctx, graph, mid, &body.body, proc_scope, sig.return_ty);

    // Definite-return analysis: a function procedure (one with a result type)
    // must not be able to reach the end of its body without executing a
    // RETURN. If normal control flow can fall off the end, the returned value
    // is undefined — a static error in ISO 10514-1 and PIM 4.
    if sig.return_ty.is_some() && seq_completes(&body.body.stmts) {
        ctx.error(
            p.span,
            &format!(
                "function procedure '{}' can reach its end without executing a RETURN statement",
                p.name
            ),
        );
    }
}

/// Can normal control flow reach the end of this statement sequence (fall
/// through) without transferring control away first?
///
/// The sequence falls through iff *every* statement falls through — the first
/// statement that diverges (RETURN/HALT/exitless LOOP/…) stops control there.
/// Used for definite-return analysis; biased toward *not* reporting, so only
/// constructs known to divert control are treated as non-completing.
fn seq_completes(stmts: &[ast::Stmt]) -> bool {
    stmts.iter().all(stmt_completes)
}

fn stmt_completes(stmt: &ast::Stmt) -> bool {
    use ast::Stmt::*;
    match stmt {
        // Transfer control away — never fall through to the next statement.
        Return(..) | Raise(..) | Retry(..) | Exit(..) => false,
        // `HALT` never returns; any other call does.
        Call(expr, _) => !is_noreturn_call(expr),
        Empty(_) | Assign { .. } => true,
        // No ELSE: the condition-false path falls through. With an ELSE, the IF
        // falls through iff some arm or the ELSE body does.
        If { arms, else_arm, .. } => match else_arm {
            None => true,
            Some(else_body) => {
                arms.iter().any(|(_, body)| seq_completes(body)) || seq_completes(else_body)
            }
        },
        // A CASE with no ELSE raises on an unmatched selector (ISO §, it does
        // not fall through), so it completes only via an arm that completes.
        Case { arms, else_arm, .. } => {
            arms.iter().any(|a| seq_completes(&a.body))
                || else_arm.as_ref().is_some_and(|e| seq_completes(e))
        }
        // WHILE/FOR/REPEAT can always terminate normally and fall through.
        While(..) | Repeat(..) | For { .. } => true,
        // A LOOP completes only if it contains an EXIT bound to it; an exitless
        // LOOP runs forever.
        Loop(body, _) => loop_has_exit(body),
        With(_, body, _) => seq_completes(body),
        // Nested BEGIN…END block: completes iff its normal body does (EXCEPT/
        // FINALLY handlers are not treated as return paths here).
        Block(b) => seq_completes(&b.stmts),
    }
}

/// Does this statement sequence contain an `EXIT` that binds to the LOOP
/// enclosing it? `EXIT` targets the nearest enclosing `LOOP`, so descend
/// through every construct except an inner `LOOP` (whose `EXIT`s are its own).
fn loop_has_exit(stmts: &[ast::Stmt]) -> bool {
    stmts.iter().any(stmt_has_exit)
}

fn stmt_has_exit(stmt: &ast::Stmt) -> bool {
    use ast::Stmt::*;
    match stmt {
        Exit(_) => true,
        Loop(..) => false, // inner LOOP captures its own EXITs
        If { arms, else_arm, .. } => {
            arms.iter().any(|(_, b)| loop_has_exit(b))
                || else_arm.as_ref().is_some_and(|e| loop_has_exit(e))
        }
        Case { arms, else_arm, .. } => {
            arms.iter().any(|a| loop_has_exit(&a.body))
                || else_arm.as_ref().is_some_and(|e| loop_has_exit(e))
        }
        While(_, b, _) | Repeat(b, _, _) => loop_has_exit(b),
        For { body, .. } => loop_has_exit(body),
        With(_, b, _) => loop_has_exit(b),
        Block(b) => loop_has_exit(&b.stmts),
        _ => false,
    }
}

/// Is `expr` a call to a procedure that never returns? Two standard idioms
/// terminate a control-flow path without a RETURN: `HALT` and the ISO
/// exception raiser `EXCEPTIONS.RAISE` (the procedure form of the bare `RAISE`
/// statement). Handles the call with or without arguments/parentheses, and
/// whether the qualified name parsed as `EXCEPTIONS.RAISE` segments or as a
/// trailing `.RAISE` field selector.
fn is_noreturn_call(expr: &ast::Expr) -> bool {
    let des = match expr {
        ast::Expr::Call(callee, _, _) => match callee.as_ref() {
            ast::Expr::Designator(d) => d,
            _ => return false,
        },
        ast::Expr::Designator(d) => d, // bare `HALT` with no parentheses
        _ => return false,
    };
    // The called name is the last field selector, or the last qualified
    // segment when there are no selectors.
    let tail = match des.selectors.last() {
        Some(ast::Selector::Field(name, _)) => Some(name.as_str()),
        Some(_) => None, // call through an index/deref — not a known builtin
        None => des.base.segments.last().map(String::as_str),
    };
    matches!(tail, Some("HALT") | Some("RAISE"))
}

fn analyse_stmts(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    stmts: &[ast::Stmt],
    scope: ScopeId,
    return_ty: Option<TypeId>,
) {
    for stmt in stmts {
        analyse_stmt(ctx, graph, mid, stmt, scope, return_ty);
    }
}

fn analyse_stmt(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    stmt: &ast::Stmt,
    scope: ScopeId,
    return_ty: Option<TypeId>,
) {
    match stmt {
        ast::Stmt::Assign { target, value, span } => {
            if is_const_param_target(ctx, target, scope) {
                ctx.error(*span, "cannot assign to a CONST parameter");
            } else if is_readonly_target(ctx, target, scope) {
                ctx.error(*span, "cannot assign to a constant");
            }
            let lhs_ty = analyse_designator(ctx, target, scope);
            let rhs_ty = analyse_expr(ctx, value, scope);
            if let (Some(lhs_ty), Some(rhs_ty)) = (lhs_ty, rhs_ty) {
                // A constant string assigned to a scalar CHAR must be at most one
                // character. CHAR and the string-element type `Achar` share a
                // family (so `c := 'a'` and `c := CHR(65)` work), and the empty
                // string `''`/`""` is the NUL character (a Modula-2 idiom). But a
                // *multi*-character constant — a literal `"ab"` or a folded concat
                // `'a' + 'b'` — would be silently truncated into a single CHAR
                // cell, so it is rejected.
                if is_scalar_char_type(ctx, lhs_ty)
                    && let Some(s) = const_string_of(ctx, value, scope)
                    && s.chars().count() > 1
                {
                    ctx.error(*span, "a multi-character string cannot be assigned to a CHAR");
                } else if !expr_compatible_with_type(ctx, lhs_ty, value, rhs_ty) {
                    ctx.error(*span, "assignment types are not compatible");
                } else {
                    // Two fixed arrays are assignment-compatible only with the
                    // same element count. (A string r-value filling an array is
                    // handled separately and excluded.)
                    if !matches!(value, ast::Expr::String(_, _))
                        && let (Some(lc), Some(rc)) =
                            (array_element_count(ctx, lhs_ty), array_element_count(ctx, rhs_ty))
                        && lc != rc
                    {
                        ctx.error(*span, "array types are not compatible (different lengths)");
                    }
                    // A *constant* assigned to a subrange variable must lie
                    // within the subrange (compile-time range check). Only a
                    // genuine subrange is checked — a full builtin (CARDINAL, …)
                    // and a non-constant r-value are not.
                    if let TypeKind::Subrange { lo, hi, .. } = ctx.types.get(lhs_ty) {
                        let (lo, hi) = (*lo, *hi);
                        if let Some(n) = const_int_of(ctx, value, scope)
                            && (n < lo || n > hi)
                        {
                            ctx.error(
                                expr_span(value),
                                format!("value {n} is out of range {lo}..{hi} for the target type"),
                            );
                        }
                    }
                    // Assigning a procedure value to a *specifically*-typed
                    // procedure variable: the signatures must match. (A bare
                    // procedure reference is typed as the generic PROC, so this
                    // designator-level check is needed to catch the mismatch.)
                    if matches!(ctx.types.get(lhs_ty), TypeKind::Proc { .. })
                        && let ast::Expr::Designator(rhs_d) = value
                        && let Some(rhs_sig) = resolve_designator_proc_sig(ctx, rhs_d, scope)
                        && let Some(lhs_sig) = resolve_designator_proc_sig(ctx, target, scope)
                        && !proc_sigs_compatible(ctx, &lhs_sig, &rhs_sig)
                    {
                        ctx.error(
                            *span,
                            "procedure value does not match the target's procedure type",
                        );
                    }
                }
            }
        }
        ast::Stmt::Call(expr, _) => {
            let _ = analyse_expr(ctx, expr, scope);
        }
        ast::Stmt::If { arms, else_arm, .. } => {
            for (cond, body) in arms {
                check_condition(ctx, cond, scope);
                analyse_stmts(ctx, graph, mid, body, scope, return_ty);
            }
            if let Some(body) = else_arm {
                analyse_stmts(ctx, graph, mid, body, scope, return_ty);
            }
        }
        ast::Stmt::Case {
            scrutinee,
            arms,
            else_arm,
            ..
        } => {
            let scrutinee_ty = analyse_expr(ctx, scrutinee, scope);
            // Folded constant label ranges seen so far, for duplicate/overlap
            // detection (the ISO spec rejects a value selected by more than one arm).
            let mut seen_labels: Vec<(i128, i128)> = Vec::new();
            for arm in arms {
                for label in &arm.labels {
                    match label {
                        ast::CaseLabel::Single(expr) => {
                            if let (Some(scrutinee_ty), Some(label_ty)) =
                                (scrutinee_ty, analyse_expr(ctx, expr, scope))
                            {
                                if !expr_compatible_with_type(ctx, scrutinee_ty, expr, label_ty) {
                                    ctx.error(expr_span(expr), "CASE label type does not match scrutinee");
                                }
                            }
                        }
                        ast::CaseLabel::Range(lo, hi) => {
                            let lo_ty = analyse_expr(ctx, lo, scope);
                            let hi_ty = analyse_expr(ctx, hi, scope);
                            if let Some(scrutinee_ty) = scrutinee_ty {
                                if let Some(lo_ty) = lo_ty {
                                    if !expr_compatible_with_type(ctx, scrutinee_ty, lo, lo_ty) {
                                        ctx.error(expr_span(lo), "CASE range lower bound type does not match scrutinee");
                                    }
                                }
                                if let Some(hi_ty) = hi_ty {
                                    if !expr_compatible_with_type(ctx, scrutinee_ty, hi, hi_ty) {
                                        ctx.error(expr_span(hi), "CASE range upper bound type does not match scrutinee");
                                    }
                                }
                            }
                        }
                    }
                    // Duplicate / overlapping label check on folded constants.
                    let folded = match label {
                        ast::CaseLabel::Single(expr) => {
                            const_int_of(ctx, expr, scope).map(|v| (v, v, expr_span(expr)))
                        }
                        ast::CaseLabel::Range(lo, hi) => {
                            match (const_int_of(ctx, lo, scope), const_int_of(ctx, hi, scope)) {
                                (Some(l), Some(h)) => Some((l, h, expr_span(lo))),
                                _ => None,
                            }
                        }
                    };
                    if let Some((lo, hi, sp)) = folded {
                        if seen_labels.iter().any(|&(sl, sh)| lo <= sh && sl <= hi) {
                            ctx.error(sp, "duplicate or overlapping CASE label");
                        }
                        seen_labels.push((lo, hi));
                    }
                }
                analyse_stmts(ctx, graph, mid, &arm.body, scope, return_ty);
            }
            if let Some(body) = else_arm {
                analyse_stmts(ctx, graph, mid, body, scope, return_ty);
            }
        }
        ast::Stmt::While(cond, body, _) => {
            check_condition(ctx, cond, scope);
            analyse_stmts(ctx, graph, mid, body, scope, return_ty);
        }
        ast::Stmt::Repeat(body, cond, _) => {
            analyse_stmts(ctx, graph, mid, body, scope, return_ty);
            check_condition(ctx, cond, scope);
        }
        ast::Stmt::For {
            var,
            start,
            end,
            step,
            body,
            span,
        } => {
            let start_ty = analyse_expr(ctx, start, scope);
            let end_ty = analyse_expr(ctx, end, scope);
            let step_ty = step.as_ref().and_then(|expr| analyse_expr(ctx, expr, scope));
            if let Some(sym) = ctx.scopes.lookup(scope, var) {
                if let SymbolKind::Var { ty, .. } = sym.kind {
                    if !is_ordinal_type(ctx, ty) {
                        ctx.error(*span, "FOR control variable must have ordinal type");
                    }
                    if let Some(start_ty) = start_ty {
                        if !expr_compatible_with_type(ctx, ty, start, start_ty) {
                            ctx.error(expr_span(start), "FOR start expression type does not match control variable");
                        }
                    }
                    if let Some(end_ty) = end_ty {
                        if !expr_compatible_with_type(ctx, ty, end, end_ty) {
                            ctx.error(expr_span(end), "FOR end expression type does not match control variable");
                        }
                    }
                    if let Some(step_ty) = step_ty {
                        // The BY step is an ordinal count (how many positions to
                        // advance). It is usually an integer, but any ordinal
                        // constant is accepted and its ordinal value used
                        // — e.g. `FOR c := 'a' TO 'z' BY CHR(2)` steps by 2.
                        if !is_ordinal_type(ctx, step_ty) {
                            ctx.error(step.as_ref().map(expr_span).unwrap_or(*span), "FOR step must be an ordinal constant");
                        }
                    }
                    // The BY step must be a non-zero compile-time constant
                    // (PIM/ISO). `BY 0` is an infinite loop; `BY <variable>` is
                    // not constant. (A `None` fold result does *not* imply
                    // non-constant — e.g. a value conversion like `colour(2)`
                    // is constant but not folded here — so only a bare variable
                    // designator is flagged.)
                    if let Some(step_expr) = step.as_ref() {
                        if let Some(0) = const_int_of(ctx, step_expr, scope) {
                            ctx.error(expr_span(step_expr), "FOR loop step must be non-zero");
                        } else if let ast::Expr::Designator(d) = step_expr
                            && d.selectors.is_empty()
                            && matches!(
                                ctx.scopes
                                    .lookup(scope, d.base.segments.first().map(String::as_str).unwrap_or(""))
                                    .map(|s| &s.kind),
                                Some(SymbolKind::Var { .. })
                            )
                        {
                            ctx.error(expr_span(step_expr), "FOR loop step must be a constant");
                        }
                    }
                }
            } else {
                ctx.error(*span, format!("unknown FOR control variable '{}'", var));
            }
            analyse_stmts(ctx, graph, mid, body, scope, return_ty);
        }
        ast::Stmt::Loop(body, _) => analyse_stmts(ctx, graph, mid, body, scope, return_ty),
        ast::Stmt::With(designator, body, span) => {
            let with_scope = ctx.scopes.push(ScopeKind::Block, Some(scope));
            // The WITH designator must denote a record (or POINTER TO record);
            // its fields become visible unqualified inside the body.
            let record_ty = analyse_designator(ctx, designator, scope)
                .map(|ty| record_type_of(ctx, ty));
            // `WITH constRec DO …` makes the record's fields read-only.
            let readonly = is_readonly_target(ctx, designator, scope);
            match record_ty {
                Some(Some(rec)) => {
                    ctx.with_stack.push((rec, readonly));
                    analyse_stmts(ctx, graph, mid, body, with_scope, return_ty);
                    ctx.with_stack.pop();
                }
                Some(None) => {
                    ctx.error(*span, "WITH requires a record or POINTER TO record designator");
                    analyse_stmts(ctx, graph, mid, body, with_scope, return_ty);
                }
                None => {
                    // Designator already diagnosed; still analyse the body.
                    analyse_stmts(ctx, graph, mid, body, with_scope, return_ty);
                }
            }
        }
        ast::Stmt::Block(b) => {
            analyse_block(ctx, graph, mid, b, scope, return_ty);
        }
        ast::Stmt::Return(expr, span) => match (return_ty, expr) {
            (Some(expected), Some(expr)) => {
                if let Some(actual) = analyse_expr(ctx, expr, scope) {
                    if !expr_compatible_with_type(ctx, expected, expr, actual) {
                        ctx.error(*span, "RETURN expression type does not match procedure result type");
                    }
                }
            }
            (Some(_), None) => {
                ctx.error(*span, "RETURN requires a result expression");
            }
            (None, Some(expr)) => {
                let _ = analyse_expr(ctx, expr, scope);
                ctx.error(*span, "RETURN expression only allowed in procedures with a result type");
            }
            (None, None) => {}
        },
        ast::Stmt::Raise(expr, _) => {
            if let Some(expr) = expr {
                let _ = analyse_expr(ctx, expr, scope);
            }
        }
        ast::Stmt::Retry(_) | ast::Stmt::Exit(_) | ast::Stmt::Empty(_) => {}
    }
}

// ---- Class declaration analysis ------------------------------------------

/// Parse a `<* @N *>` vtable-ordinal annotation from a method's pragmas, if any.
/// winapi-gen emits these from the winmd so the compiler can machine-check that
/// each method's computed slot matches the metadata; they may also be written by
/// hand. Returns the declared slot ordinal N.
fn parse_ordinal_pragma(pragmas: &[ast::Pragma]) -> Option<usize> {
    for p in pragmas {
        let body = p.body.trim();
        if let Some(rest) = body.strip_prefix('@') {
            if let Ok(n) = rest.trim().parse::<usize>() {
                return Some(n);
            }
        }
    }
    None
}

fn resolve_class_decl(
    ctx: &mut Ctx,
    graph: &ModuleGraph,
    mid: ModuleId,
    cd: &ast::ClassDecl,
    scope: ScopeId,
) {
    let cid = match ctx.scopes.get(scope).get(&cd.name) {
        Some(sym) => match sym.kind {
            SymbolKind::Class(id) => id,
            _ => return,
        },
        None => return,
    };

    // Record the COM interface kind + IID (a vtable-only class).
    let is_interface = cd.kind == ast::ClassKind::Interface;
    {
        let cls = ctx.classes.get_mut(cid);
        cls.is_interface = is_interface;
        cls.iid = cd.iid.clone();
    }

    if cd.is_forward {
        // Forward declaration: nothing further to resolve now.
        return;
    }

    // Resolve INHERIT. A base may be qualified (`INHERIT Module.Base;`, as
    // winapi-gen emits for a cross-namespace COM base such as
    // `System_Com.IUnknown`) or unqualified (a sibling in this module). Walk the
    // qualified name through module scopes so an imported base resolves; fall
    // back to a bare last-segment lookup so a single-segment name still works.
    if let Some(base_qn) = &cd.inherit {
        let base_name = base_qn.segments.last().unwrap().clone();
        let resolved = if base_qn.segments.len() > 1 {
            resolve_symbol(ctx, base_qn, scope)
        } else {
            ctx.scopes.lookup(scope, &base_name).cloned()
        };
        match resolved {
            Some(sym) => match sym.kind {
                SymbolKind::Class(base_cid) => {
                    ctx.classes.get_mut(cid).base = Some(base_cid);
                }
                _ => {
                    ctx.error(base_qn.span, format!("'{base_name}' is not a class"));
                }
            },
            None => {
                // For a single-segment name, emit the diagnostic here; a
                // qualified miss already reported inside `resolve_symbol`.
                if base_qn.segments.len() == 1 {
                    ctx.error(base_qn.span, format!("unknown class '{base_name}'"));
                }
            }
        }
    }

    // Resolve REVEAL list.
    ctx.classes.get_mut(cid).revealed = cd.reveal.clone();

    // Resolve class members.
    let mut own_fields: Vec<FieldSlot> = Vec::new();
    let mut own_methods: Vec<MethodSlot> = Vec::new();

    for member in &cd.members {
        match member {
            ast::ClassMember::Field(vd) => {
                if is_interface {
                    ctx.error(cd.span, "an INTERFACE has no fields (it is vtable-only)".to_string());
                }
                let ty = form_type_expr(ctx, graph, mid, &vd.ty, scope);
                for name in &vd.names {
                    own_fields.push(FieldSlot { name: name.clone(), ty });
                }
            }
            ast::ClassMember::Method(m) => {
                let params: Vec<NamedParam> = m
                    .params
                    .iter()
                    .flat_map(|param| {
                        let ty = form_type_expr(ctx, graph, mid, &param.ty, scope);
                        let mode = match param.mode {
                            ast::ParamMode::Var => ParamMode::Var,
                            ast::ParamMode::Const => ParamMode::Const,
                            ast::ParamMode::Value => ParamMode::Value,
                        };
                        param.names.iter().map(move |name| NamedParam {
                            name: Some(name.clone()),
                            mode,
                            ty,
                        })
                    })
                    .collect();
                let return_ty = m
                    .return_ty
                    .as_ref()
                    .map(|te| form_type_expr(ctx, graph, mid, te, scope));
                let calling_conv = parse_calling_conv(&m.attrs, &m.pragmas);
                let attrs = parse_proc_attrs(&m.attrs, &m.pragmas);
                let sig = ProcSig {
                    params,
                    return_ty,
                    calling_conv,
                    attrs,
                    external_linkage: None,
                };
                if is_interface && m.body.is_some() {
                    ctx.error(m.span, "an INTERFACE method has no body".to_string());
                }
                own_methods.push(MethodSlot {
                    name: m.name.clone(),
                    sig,
                    // INTERFACE methods are implicitly abstract.
                    is_abstract: m.is_abstract || is_interface,
                    is_override: m.is_override,
                    vtable_index: 0, // filled by resolve_vtable
                    declared_slot: parse_ordinal_pragma(&m.pragmas),
                });
            }
            ast::ClassMember::Pragma(pr) => {
                check_pragma_known(ctx, pr);
            }
        }
    }

    let cls = ctx.classes.get_mut(cid);
    cls.own_fields = own_fields;
    cls.own_methods = own_methods;
    cls.body_resolved = true;
}

fn resolve_classes_in_scope(ctx: &mut Ctx, scope: ScopeId) {
    // Collect class IDs first to avoid borrow issues.
    let mut class_ids: Vec<ClassSymbolId> = ctx
        .scopes
        .get(scope)
        .iter()
        .filter_map(|sym| match sym.kind {
            SymbolKind::Class(cid) => Some(cid),
            _ => None,
        })
        .collect();

    // `resolve_vtable` clones the *base's* already-resolved vtable to compute a
    // derived class's slot offsets, so a base must be resolved before any class
    // that inherits it. Source order does not guarantee that — a generated COM
    // def lists interfaces alphabetically, so a derived `AsyncIAdviseSink` can
    // precede its base `IUnknown`. Sort by inheritance depth (a base is always
    // shallower than its descendants) so bases come first. Only `base` links
    // that point *inside this scope* matter; a cross-module base is resolved in
    // an earlier topo-ordered module. A cycle guard caps the walk.
    let in_scope: std::collections::HashSet<ClassSymbolId> = class_ids.iter().copied().collect();
    let depth_of = |start: ClassSymbolId, classes: &crate::class::ClassArena| -> usize {
        let mut depth = 0usize;
        let mut seen: std::collections::HashSet<ClassSymbolId> = std::collections::HashSet::new();
        let mut cur = classes.get(start).base;
        while let Some(b) = cur {
            if !in_scope.contains(&b) || !seen.insert(b) {
                break;
            }
            depth += 1;
            cur = classes.get(b).base;
        }
        depth
    };
    class_ids.sort_by_key(|&cid| depth_of(cid, &ctx.classes));

    for cid in class_ids {
        if !ctx.classes.get(cid).body_resolved {
            continue;
        }
        ctx.classes.resolve_fields(cid);
        ctx.classes.resolve_vtable(cid);
        synthesize_object_record(ctx, cid);
        synthesize_vtable_call_sigs(ctx, cid);
        let errs: Vec<_> = ctx.classes.validate(cid);
        for e in errs {
            ctx.class_error(e);
        }
    }
}

/// Build the heap-object layout for a class: a record whose first member is
/// the vtable pointer (`__vtable`) followed by the flattened `all_fields`. A
/// class variable is a pointer to this record; codegen reuses ordinary record
/// machinery for sizing, allocation, and field GEPs.
fn synthesize_object_record(ctx: &mut Ctx, cid: ClassSymbolId) {
    let addr = ctx.types.builtin(Builtin::Address);
    let mut fields = Vec::with_capacity(ctx.classes.get(cid).all_fields.len() + 1);
    fields.push(RecordFieldSlot { name: "__vtable".into(), ty: addr });
    for f in &ctx.classes.get(cid).all_fields {
        fields.push(RecordFieldSlot { name: f.name.clone(), ty: f.ty });
    }
    let name = format!("__obj_{}", ctx.classes.get(cid).name);
    let layout = RecordLayout { name: Some(name), fields, variant: None };
    let ty = ctx.types.alloc(TypeKind::Record(layout));
    ctx.classes.get_mut(cid).object_record = Some(ty);
}

/// Build, for each vtable slot, the `PROCEDURE` type used to type a virtual
/// call: a hidden `SELF` (a pointer) followed by the declared parameters.
fn synthesize_vtable_call_sigs(ctx: &mut Ctx, cid: ClassSymbolId) {
    let addr = ctx.types.builtin(Builtin::Address);
    let descs: Vec<(usize, Vec<ProcParam>, Option<TypeId>)> = ctx
        .classes
        .get(cid)
        .vtable
        .iter()
        .enumerate()
        .map(|(i, slot)| {
            let mut params = vec![ProcParam { mode: ParamMode::Value, ty: addr }];
            for p in &slot.sig.params {
                params.push(ProcParam { mode: p.mode, ty: p.ty });
            }
            (i, params, slot.sig.return_ty)
        })
        .collect();
    for (i, params, return_ty) in descs {
        let proc_ty = ctx.types.alloc(TypeKind::Proc { params, return_ty });
        ctx.classes.get_mut(cid).vtable[i].call_sig = Some(proc_ty);
    }
}

// ---- Pragma checking ------------------------------------------------------

fn check_pragma_known(ctx: &mut Ctx, pr: &ast::Pragma) {
    // Known pragmas (from the plan §3): PROCATTR, RESOURCE, CALLS,
    // INLINE, NOOPTIMIZE, NOCHECKS, GCPOLL, PINNED, IF/ELSIF/ELSE/END.
    let body = pr.body.trim();
    let known = [
        "PROCATTR", "RESOURCE", "CALLS", "INLINE", "NOOPTIMIZE",
        "NOCHECKS", "GCPOLL", "PINNED",
    ];
    let is_known = known.iter().any(|k| body.starts_with(k))
        || body.starts_with("IF")
        || body.starts_with("ELSIF")
        || body.starts_with("ELSE")
        || body.starts_with("END")
        || body.eq_ignore_ascii_case("GUI"); // <*GUI*> — link as a Windows GUI app (driver reads it)
    if !is_known {
        ctx.warning(pr.span, format!("unknown pragma: <*{body}*>"));
    }
}

// ---- Helpers --------------------------------------------------------------

fn dummy_span() -> Span {
    use newm2_lexer::SourcePosition;
    let pos = SourcePosition { line: 0, column: 0, offset: 0 };
    Span { start: pos, end: pos }
}

#[cfg(test)]
mod tests {
    use super::*;
    use newm2_loader::{SearchPath, build_module_graph};
    use std::fs;

    fn tmpdir(name: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("newm2-sema-analyze-{}", name));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn def_module_with_const_and_type() {
        let dir = tmpdir("const_type");
        fs::write(
            dir.join("Foo.def"),
            "DEFINITION MODULE Foo;\n\
             CONST max = 100;\n\
             TYPE Color = (red, green, blue);\n\
             END Foo.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Foo.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
    }

    #[test]
    fn import_resolution_across_modules() {
        let dir = tmpdir("import");
        fs::write(
            dir.join("Types.def"),
            "DEFINITION MODULE Types;\nTYPE T = INTEGER;\nEND Types.\n",
        )
        .unwrap();
        fs::write(
            dir.join("User.def"),
            "DEFINITION MODULE User;\nIMPORT Types;\nVAR x: Types.T;\nEND User.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("User.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("User").unwrap();
        let ast = graph.get(mid).def_ast.as_ref().unwrap();
        let named_ty = match &ast.decls[0] {
            ast::Decl::Var(var_decl) => match &var_decl.ty {
                ast::TypeExpr::Named(named) => named,
                other => panic!("expected named type, got {other:?}"),
            },
            other => panic!("expected var decl, got {other:?}"),
        };
        assert!(matches!(result.resolved_name(mid, named_ty.span), Some(SymbolKind::Type(_))));
        let binding = result.resolved_binding(mid, named_ty.span).expect("resolved binding");
        assert!(!binding.is_imported());
        let (decl_mid, decl_name) = binding.declaring_module().expect("declaring module");
        assert_eq!(graph.lookup("Types"), Some(decl_mid));
        assert_eq!(decl_name, "Types");
        assert_eq!(binding.root_name(), "T");
        let decl_scope = result.module_scopes[&decl_mid];
        let decl_sym = result.scopes.get(decl_scope).get("T").expect("type symbol");
        assert_eq!(binding.declaration_id(), decl_sym.declaration_id);
        assert_eq!(binding.binding_id(), decl_sym.binding_id);
        assert_eq!(result.resolved_declaration_id(mid, named_ty.span), Some(decl_sym.declaration_id));
        assert_eq!(result.resolved_binding_id(mid, named_ty.span), Some(decl_sym.binding_id));
        assert!(result.resolved_provenance(mid, named_ty.span).is_some());
    }

    #[test]
    fn imported_names_preserve_module_provenance() {
        let dir = tmpdir("import_provenance");
        fs::write(
            dir.join("Types.def"),
            "DEFINITION MODULE Types;\nTYPE T = INTEGER;\nEND Types.\n",
        )
        .unwrap();
        fs::write(
            dir.join("User.def"),
            "DEFINITION MODULE User;\nFROM Types IMPORT T;\nVAR x: T;\nEND User.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("User.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("User").unwrap();
        let ast = graph.get(mid).def_ast.as_ref().unwrap();
        let named_ty = match &ast.decls[0] {
            ast::Decl::Var(var_decl) => match &var_decl.ty {
                ast::TypeExpr::Named(named) => named,
                other => panic!("expected named type, got {other:?}"),
            },
            other => panic!("expected var decl, got {other:?}"),
        };

        let binding = result.resolved_binding(mid, named_ty.span).expect("resolved binding");
        assert_eq!(binding.name, "T");
        assert!(binding.exported);
        assert!(binding.is_imported());
        let (decl_mid, decl_name) = binding.declaring_module().expect("declaring module");
        assert_eq!(graph.lookup("Types"), Some(decl_mid));
        assert_eq!(decl_name, "Types");
        assert_eq!(binding.root_name(), "T");
        let decl_scope = result.module_scopes[&decl_mid];
        let decl_sym = result.scopes.get(decl_scope).get("T").expect("type symbol");
        assert_eq!(binding.declaration_id(), decl_sym.declaration_id);
        assert_ne!(binding.binding_id(), decl_sym.binding_id);
        assert_eq!(result.resolved_declaration_id(mid, named_ty.span), Some(decl_sym.declaration_id));
        assert_eq!(result.resolved_binding_id(mid, named_ty.span), Some(binding.binding_id()));
        assert_eq!(binding.import_chain().len(), 1);
        assert_eq!(binding.immediate_import().expect("import hop").from_module_name, "Types");
    }

    #[test]
    fn imported_names_preserve_full_import_chain() {
        let dir = tmpdir("import_provenance_chain");
        fs::write(
            dir.join("A.def"),
            "DEFINITION MODULE A;\nTYPE T = INTEGER;\nEND A.\n",
        )
        .unwrap();
        fs::write(
            dir.join("B.def"),
            "DEFINITION MODULE B;\nFROM A IMPORT T;\nEXPORT T;\nEND B.\n",
        )
        .unwrap();
        fs::write(
            dir.join("C.def"),
            "DEFINITION MODULE C;\nFROM B IMPORT T;\nVAR x: T;\nEND C.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("C.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("C").unwrap();
        let ast = graph.get(mid).def_ast.as_ref().unwrap();
        let named_ty = match &ast.decls[0] {
            ast::Decl::Var(var_decl) => match &var_decl.ty {
                ast::TypeExpr::Named(named) => named,
                other => panic!("expected named type, got {other:?}"),
            },
            other => panic!("expected var decl, got {other:?}"),
        };

        let binding = result.resolved_binding(mid, named_ty.span).expect("resolved binding");
        let (decl_mid, decl_name) = binding.declaring_module().expect("declaring module");
        assert_eq!(graph.lookup("A"), Some(decl_mid));
        assert_eq!(decl_name, "A");
        assert_eq!(binding.root_name(), "T");
        let decl_scope = result.module_scopes[&decl_mid];
        let decl_sym = result.scopes.get(decl_scope).get("T").expect("type symbol");
        assert_eq!(binding.declaration_id(), decl_sym.declaration_id);
        assert_ne!(binding.binding_id(), decl_sym.binding_id);
        assert_eq!(result.resolved_declaration_id(mid, named_ty.span), Some(decl_sym.declaration_id));
        assert_eq!(result.resolved_binding_id(mid, named_ty.span), Some(binding.binding_id()));
        let c_scope = result.module_scopes[&mid];
        let c_sym = result.scopes.get(c_scope).get("T").expect("imported type symbol");
        assert_eq!(binding.binding_id(), c_sym.binding_id);
        let b_mid = graph.lookup("B").expect("B module");
        let b_scope = result.module_scopes[&b_mid];
        let b_sym = result.scopes.get(b_scope).get("T").expect("re-exported type symbol");
        assert_ne!(binding.binding_id(), b_sym.binding_id);
        assert_eq!(binding.declaration_id(), b_sym.declaration_id);
        assert_eq!(binding.import_chain().len(), 2);
        assert_eq!(binding.immediate_import().expect("import hop").from_module_name, "B");
        assert_eq!(binding.import_chain()[1].from_module_name, "A");
    }

    #[test]
    fn imported_procedure_tracks_external_dll_metadata() {
        let dir = tmpdir("proc_dll_metadata");
        fs::write(
            dir.join("Win.def"),
            "DEFINITION MODULE Win;\n\
             PROCEDURE Beep[\"Beep\" EXTERNAL FROM \"kernel32.dll\"](dwFreq, dwDuration : CARDINAL) : BOOLEAN;\n\
             END Win.\n",
        )
        .unwrap();
        fs::write(
            dir.join("Hello.mod"),
            "MODULE Hello;\n\
             IMPORT Win;\n\
             BEGIN\n\
               Win.Beep(440, 1)\n\
             END Hello.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Hello.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("Hello").unwrap();
        let ast = graph.get(mid).impl_ast.as_ref().unwrap();
        let call_span = match &ast.body.as_ref().unwrap().stmts[0] {
            // `Win.Beep(440, 1)` is a call with arguments, so the statement
            // expression is Call(callee, args); the callee is the designator.
            ast::Stmt::Call(ast::Expr::Call(callee, _, _), _) => match callee.as_ref() {
                ast::Expr::Designator(designator) => designator.span,
                other => panic!("expected designator callee, got {other:?}"),
            },
            ast::Stmt::Call(ast::Expr::Designator(designator), _) => designator.span,
            other => panic!("expected call statement, got {other:?}"),
        };
        let SymbolKind::Proc(sig) = result.resolved_name(mid, call_span).expect("resolved proc") else {
            panic!("expected resolved proc symbol");
        };
        let linkage = sig.external_linkage.as_ref().expect("external linkage metadata");
        assert_eq!(linkage.link_name, "Beep");
        assert_eq!(linkage.dll_name.as_deref(), Some("kernel32.dll"));
        assert!(linkage.is_external);
    }

    #[test]
    fn const_can_reference_later_same_module_enum_member() {
        let dir = tmpdir("forward_enum_const");
        fs::write(
            dir.join("Forward.def"),
            "DEFINITION MODULE Forward;\nCONST Max = Blue;\nTYPE Color = (Red, Green, Blue);\nEND Forward.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Forward.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
    }

    #[test]
    fn const_set_can_reference_later_same_module_enum_members() {
        let dir = tmpdir("forward_enum_set_const");
        fs::write(
            dir.join("ForwardSet.def"),
            "DEFINITION MODULE ForwardSet;\nCONST Mask = Flags{A, C};\nTYPE Flags = (A, B, C);\nEND ForwardSet.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("ForwardSet.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
    }

    #[test]
    fn class_vtable_resolved_from_def() {
        let dir = tmpdir("class_vtable");
        fs::write(
            dir.join("COM.def"),
            "DEFINITION MODULE COM;\n\
             ABSTRACT CLASS IUnknown;\n\
               ABSTRACT PROCEDURE QueryInterface();\n\
               ABSTRACT PROCEDURE AddRef(): CARDINAL;\n\
               ABSTRACT PROCEDURE Release(): CARDINAL;\n\
             END IUnknown;\n\
             END COM.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("COM.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
        // IUnknown's vtable should have 3 slots.
        let iu = result.classes.lookup("IUnknown").expect("IUnknown not found");
        assert_eq!(result.classes.get(iu).vtable.len(), 3);
    }

    #[test]
    fn undefined_type_gives_error() {
        let dir = tmpdir("undef_type");
        fs::write(
            dir.join("Bad.def"),
            "DEFINITION MODULE Bad;\nVAR x: NonExistent;\nEND Bad.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Bad.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(result.has_errors());
        assert!(result.diagnostics[0].message.contains("NonExistent"));
    }

    #[test]
    fn function_falling_off_the_end_is_an_error() {
        // A function procedure that can reach its end without a RETURN —
        // both an empty body and an IF with a return on only one branch.
        let dir = tmpdir("noreturn");
        fs::write(
            dir.join("N.mod"),
            "MODULE N;\n\
             PROCEDURE empty(): CARDINAL;\n\
             BEGIN\n\
             END empty;\n\
             PROCEDURE halfIf(c: BOOLEAN): CARDINAL;\n\
             BEGIN\n\
               IF c THEN RETURN 1 END\n\
             END halfIf;\n\
             BEGIN\n\
             END N.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("N.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        let hits = result
            .diagnostics
            .iter()
            .filter(|d| d.message.contains("without executing a RETURN"))
            .count();
        assert_eq!(hits, 2, "both functions should be flagged: {:?}", result.diagnostics);
    }

    #[test]
    fn functions_that_always_return_are_accepted() {
        // Every terminating idiom that must NOT be flagged: ends-in-RETURN,
        // IF/ELSE both return, CASE/ELSE all return, exitless LOOP, HALT, and
        // a branch that raises via EXCEPTIONS.RAISE.
        let dir = tmpdir("alwaysreturn");
        fs::write(
            dir.join("Excs.def"),
            "DEFINITION MODULE Excs;\n\
             PROCEDURE RAISE;\n\
             END Excs.\n",
        )
        .unwrap();
        fs::write(
            dir.join("R.mod"),
            "MODULE R;\n\
             IMPORT Excs;\n\
             PROCEDURE endsReturn(): CARDINAL;\n\
             BEGIN RETURN 1 END endsReturn;\n\
             PROCEDURE ifElse(c: BOOLEAN): CARDINAL;\n\
             BEGIN IF c THEN RETURN 1 ELSE RETURN 2 END END ifElse;\n\
             PROCEDURE caseElse(n: CARDINAL): CARDINAL;\n\
             BEGIN CASE n OF 1: RETURN 10 | 2: RETURN 20 ELSE RETURN 0 END END caseElse;\n\
             PROCEDURE foreverLoop(): CARDINAL;\n\
             BEGIN LOOP END END foreverLoop;\n\
             PROCEDURE viaHalt(): CARDINAL;\n\
             BEGIN HALT END viaHalt;\n\
             PROCEDURE viaRaise(c: BOOLEAN): CARDINAL;\n\
             BEGIN IF c THEN RETURN 1 ELSE Excs.RAISE END END viaRaise;\n\
             BEGIN END R.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("R.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        let offenders: Vec<_> = result
            .diagnostics
            .iter()
            .filter(|d| d.message.contains("without executing a RETURN"))
            .collect();
        assert!(offenders.is_empty(), "false positives: {offenders:?}");
    }

    #[test]
    fn type_conversion_in_constant_expression_folds() {
        // `T(x)` where T is a (resolved) user ordinal type is a value
        // conversion and is constant — it folds to x and drives a bound.
        let dir = tmpdir("constconv");
        fs::write(
            dir.join("C.mod"),
            "MODULE C;\n\
             TYPE ind0 = [-100..100];\n\
             CONST low  = ind0(-100);\n\
             CONST high = ind0(100);\n\
             TYPE ind = [low..high];\n\
             VAR a: ARRAY ind OF CHAR;\n\
             BEGIN\n\
             END C.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("C.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        // The converted constant keeps its value.
        let mid = graph.lookup("C").unwrap();
        let scope = result.module_scopes[&mid];
        match &result.scopes.get(scope).get("low").unwrap().kind {
            SymbolKind::Const { value, .. } => {
                assert_eq!(value.as_int(), Some(-100));
            }
            other => panic!("expected const, got {other:?}"),
        }
    }

    #[test]
    fn out_of_range_constant_conversion_is_rejected() {
        // `T(x)` with x outside T's range is a compile-time error.
        let dir = tmpdir("constconv_oor");
        fs::write(
            dir.join("D.mod"),
            "MODULE D;\n\
             TYPE small = [60..100];\n\
             CONST bad = small(50);\n\
             VAR a: ARRAY [0..bad] OF CHAR;\n\
             BEGIN\n\
             END D.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("D.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(
            result.diagnostics.iter().any(|d| d.message.contains("out of range")),
            "expected out-of-range diagnostic: {:?}",
            result.diagnostics
        );
    }

    #[test]
    fn array_indexing_accepts_ordinal_indices_and_multiple_dimensions() {
        // BOOLEAN / CHAR-subrange index types, comma-declared multidimensional
        // arrays, and `a[i, j]` indexing across dimensions must all type-check.
        let dir = tmpdir("arridx");
        fs::write(
            dir.join("A.mod"),
            "MODULE A;\n\
             VAR b: ARRAY BOOLEAN OF ARRAY BOOLEAN OF BITSET;\n\
             VAR g: ARRAY ['a'..'c'] OF INTEGER;\n\
             VAR m: ARRAY [0..1], [0..1] OF CARDINAL;\n\
             BEGIN\n\
               b[FALSE, FALSE] := {0, 1};\n\
               g['b'] := 3;\n\
               m[0, 1] := 7\n\
             END A.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("A.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
    }

    #[test]
    fn partial_indexing_of_comma_array_yields_subarray() {
        // `m[i]` on `ARRAY x, y OF T` yields a lower-rank sub-array (the row),
        // assignable to a matching 1-D array — supported, not rejected.
        let dir = tmpdir("arrpartial");
        fs::write(
            dir.join("P.mod"),
            "MODULE P;\n\
             VAR m: ARRAY [0..1], [0..1] OF CARDINAL;\n\
             VAR row: ARRAY [0..1] OF CARDINAL;\n\
             BEGIN\n\
               row := m[0]\n\
             END P.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("P.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(
            !result.has_errors(),
            "partial indexing should type-check: {:?}",
            result.diagnostics
        );
    }

    #[test]
    fn cardinal_and_integer_are_distinct() {
        let dir = tmpdir("card_int");
        fs::write(
            dir.join("T.def"),
            "DEFINITION MODULE T;\n\
             TYPE C = CARDINAL;\n\
             TYPE I = INTEGER;\n\
             END T.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("T.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "{:?}", result.diagnostics);
        // The two TypeIds must differ.
        let mid = *result.module_scopes.keys().next().unwrap();
        let scope = result.module_scopes[&mid];
        let c_sym = result.scopes.get(scope).get("C").unwrap();
        let i_sym = result.scopes.get(scope).get("I").unwrap();
        if let (SymbolKind::Type(c_id), SymbolKind::Type(i_id)) = (&c_sym.kind, &i_sym.kind) {
            let ck = result.types.get(*c_id);
            let ik = result.types.get(*i_id);
            // Both resolve to Builtin but to different Builtin variants.
            assert_ne!(ck, ik, "CARDINAL and INTEGER should be distinct types");
        }
    }

    #[test]
    fn system_import_resolves() {
        let dir = tmpdir("sys_import");
        fs::write(
            dir.join("S.def"),
            "DEFINITION MODULE S;\nFROM SYSTEM IMPORT ADDRESS;\nVAR p: ADDRESS;\nEND S.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("S.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
    }

    #[test]
    fn implementation_tree_drives_proc_types_and_def_marks_exports() {
        let dir = tmpdir("impl_proc_types");
        fs::write(
            dir.join("M.def"),
            "DEFINITION MODULE M;\n\
             PROCEDURE Public(flag: BOOLEAN): CARDINAL;\n\
             END M.\n",
        )
        .unwrap();
        fs::write(
            dir.join("M.mod"),
            "IMPLEMENTATION MODULE M;\n\
             PROCEDURE Public(flag: BOOLEAN): CARDINAL;\n\
             BEGIN\n\
               RETURN 1\n\
             END Public;\n\
             PROCEDURE Private(ch: CHAR): INTEGER;\n\
             BEGIN\n\
               RETURN 0\n\
             END Private;\n\
             END M.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.def"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("M").unwrap();
        let scope = result.module_scopes[&mid];
        let public = result.scopes.get(scope).get("Public").unwrap();
        let private = result.scopes.get(scope).get("Private").unwrap();

        match &public.kind {
            SymbolKind::Proc(sig) => {
                assert_eq!(sig.params.len(), 1);
                assert_eq!(sig.params[0].ty, result.types.builtin(Builtin::Boolean));
                assert_eq!(sig.return_ty, Some(result.types.builtin(Builtin::Cardinal)));
            }
            other => panic!("expected proc symbol, got {other:?}"),
        }

        match &private.kind {
            SymbolKind::Proc(sig) => {
                assert_eq!(sig.params.len(), 1);
                assert_eq!(sig.params[0].ty, result.types.builtin(Builtin::Char));
                assert_eq!(sig.return_ty, Some(result.types.builtin(Builtin::Integer)));
            }
            other => panic!("expected proc symbol, got {other:?}"),
        }

        assert!(public.exported, "public DEF symbol should be exported");
        assert!(!private.exported, "implementation-only symbol should stay private");
    }

    #[test]
    fn executable_code_records_types_and_bindings() {
        let dir = tmpdir("expr_annotations");
        fs::write(
            dir.join("A.mod"),
            "MODULE A;\n\
             VAR x: INTEGER;\n\
             PROCEDURE Inc(v: INTEGER): INTEGER;\n\
             VAR y: INTEGER;\n\
             BEGIN\n\
               y := x + v;\n\
               RETURN y\n\
             END Inc;\n\
             BEGIN\n\
               x := Inc(1)\n\
             END A.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("A.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("A").unwrap();
        let ast = graph.get(mid).impl_ast.as_ref().unwrap();
        let int_ty = result.types.builtin(Builtin::Integer);

        let proc_decl = match &ast.decls[1] {
            ast::Decl::Procedure(proc_decl) => proc_decl,
            other => panic!("expected procedure decl, got {other:?}"),
        };

        let assign_stmt = match &proc_decl.body.as_ref().unwrap().body.stmts[0] {
            ast::Stmt::Assign { target, value, .. } => (target, value),
            other => panic!("expected assignment stmt, got {other:?}"),
        };

        assert_eq!(result.designator_type(mid, assign_stmt.0.span), Some(int_ty));
        assert_eq!(result.expr_type(mid, expr_span(assign_stmt.1)), Some(int_ty));

        let binary = match assign_stmt.1 {
            ast::Expr::Binary(_, lhs, rhs, span) => (lhs, rhs, *span),
            other => panic!("expected binary expr, got {other:?}"),
        };

        let lhs_designator = match binary.0.as_ref() {
            ast::Expr::Designator(designator) => designator,
            other => panic!("expected lhs designator, got {other:?}"),
        };
        let rhs_designator = match binary.1.as_ref() {
            ast::Expr::Designator(designator) => designator,
            other => panic!("expected rhs designator, got {other:?}"),
        };

        assert_eq!(result.designator_type(mid, lhs_designator.span), Some(int_ty));
        assert_eq!(result.designator_type(mid, rhs_designator.span), Some(int_ty));
        assert_eq!(result.expr_type(mid, binary.2), Some(int_ty));
        assert!(matches!(result.resolved_name(mid, lhs_designator.base.span), Some(SymbolKind::Var { .. })));
        assert!(matches!(result.resolved_name(mid, rhs_designator.base.span), Some(SymbolKind::Var { .. })));

        let module_assign = match &ast.body.as_ref().unwrap().stmts[0] {
            ast::Stmt::Assign { value, .. } => value,
            other => panic!("expected module assignment, got {other:?}"),
        };
        assert_eq!(result.expr_type(mid, expr_span(module_assign)), Some(int_ty));
    }

    #[test]
    fn val_builtin_accepts_type_and_value_arguments() {
        let dir = tmpdir("builtin_val");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             VAR x: LONGREAL; y: INTEGER64;\n\
             BEGIN\n\
               y := VAL(INTEGER64, x)\n\
             END M.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);

        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
    }

    #[test]
    fn coroutines_import_resolves() {
        let dir = tmpdir("coroutines_import");
        fs::write(
            dir.join("S.def"),
            "DEFINITION MODULE S;\nIMPORT COROUTINES;\nVAR p: COROUTINES.COROUTINE;\nEND S.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("S.def"), &sp).unwrap();
        let result = check_module_graph(&graph);

        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
    }

    #[test]
    fn qualified_system_cast_builtin_accepts_type_and_value_arguments() {
        let dir = tmpdir("builtin_system_cast");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             IMPORT SYSTEM;\n\
             VAR x: INTEGER; y: INTEGER64;\n\
             BEGIN\n\
               y := SYSTEM.CAST(INTEGER64, x)\n\
             END M.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);

        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
    }

    #[test]
    fn coroutines_calls_report_not_yet_implemented() {
        let dir = tmpdir("coroutines_not_impl");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             IMPORT COROUTINES;\n\
             VAR from, to: COROUTINES.COROUTINE; v: CARDINAL;\n\
             BEGIN\n\
               COROUTINES.IOTRANSFER(from, to, v)\n\
             END M.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);

        assert!(result.has_errors(), "expected coroutine diagnostics");
        assert!(result.diagnostics.iter().any(|diag| diag.message == "Not yet implemented"));
    }

    #[test]
    fn imported_coroutine_calls_report_not_yet_implemented() {
        let dir = tmpdir("coroutines_imported_not_impl");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             FROM COROUTINES IMPORT IOTRANSFER, COROUTINE;\n\
             VAR from, to: COROUTINE; v: CARDINAL;\n\
             BEGIN\n\
               IOTRANSFER(from, to, v)\n\
             END M.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);

        assert!(result.has_errors(), "expected imported coroutine diagnostics");
        assert!(result.diagnostics.iter().any(|diag| diag.message == "Not yet implemented"));
    }

    #[test]
    fn legacy_system_coroutine_calls_report_not_yet_implemented() {
        // NEWPROCESS/TRANSFER are implemented (fibers); IOTRANSFER is not.
        let dir = tmpdir("system_coroutines_not_impl");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             IMPORT SYSTEM;\n\
             VAR from, to: ADDRESS; v: CARDINAL;\n\
             BEGIN\n\
               SYSTEM.IOTRANSFER(from, to, v)\n\
             END M.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);

        assert!(result.has_errors(), "expected legacy coroutine diagnostics");
        assert!(result.diagnostics.iter().any(|diag| diag.message == "Not yet implemented"));
    }

    #[test]
    fn val_builtin_rejects_non_iso_scalar_conversions() {
        let dir = tmpdir("builtin_val_invalid");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             TYPE Days = (Mon, Tue, Wed);\n\
             VAR r: REAL; d: Days; b: BOOLEAN; ch: CHAR;\n\
             BEGIN\n\
               r := VAL(REAL, b);\n\
               d := VAL(Days, ch)\n\
             END M.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);

        assert!(result.has_errors(), "expected VAL conversion errors");
        assert!(result
            .diagnostics
            .iter()
            .any(|diag| diag.message.contains("VAL requires an ISO-compatible scalar conversion")));
    }

    #[test]
    fn iso_set_operators_and_packed_set_assignment_typecheck() {
        let dir = tmpdir("set_operators");
        fs::write(
            dir.join("S.mod"),
            "MODULE S;\n\
             TYPE Flags = (A, B, C);\n\
             TYPE Mask = PACKEDSET OF Flags;\n\
             CONST Empty = Flags{};\n\
             VAR x, y, z : Mask;\n\
             BEGIN\n\
               z := Empty;\n\
               z := Flags{A} + Flags{B};\n\
               z := Flags{A, B} - Flags{B};\n\
               z := Flags{A, B} * Flags{B};\n\
               z := Flags{A} / Flags{A, B};\n\
               z := x + y;\n\
               z := x * y\n\
             END S.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("S.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);

        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);
    }

    #[test]
    fn procedure_scope_parameters_preserve_param_mode() {
        let dir = tmpdir("param_mode_symbols");
        fs::write(
            dir.join("P.mod"),
            "MODULE P;\n\
             PROCEDURE F(VAR x: INTEGER; y: INTEGER);\n\
             BEGIN\n\
             END F;\n\
             END P.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("P.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("P").unwrap();
        let proc_scope = result.proc_scopes[&(mid, "F".to_string())];

        match &result.scopes.get(proc_scope).get("x").unwrap().kind {
            SymbolKind::Var {
                ty,
                param_mode: Some(ParamMode::Var),
            } => assert_eq!(*ty, result.types.builtin(Builtin::Integer)),
            other => panic!("expected VAR parameter binding, got {other:?}"),
        }

        match &result.scopes.get(proc_scope).get("y").unwrap().kind {
            SymbolKind::Var {
                ty,
                param_mode: Some(ParamMode::Value),
            } => assert_eq!(*ty, result.types.builtin(Builtin::Integer)),
            other => panic!("expected value parameter binding, got {other:?}"),
        }
    }

    #[test]
    fn selector_bindings_capture_class_field_slots() {
        let dir = tmpdir("selector_bindings");
        fs::write(
            dir.join("Fields.mod"),
            "MODULE Fields;\n\
                         CLASS T;\n\
                             VAR a, b: INTEGER;\n\
                         END T;\n\
                         VAR xs: ARRAY [0..0] OF T;\n\
             BEGIN\n\
                             xs[0].b := 1\n\
             END Fields.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Fields.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("Fields").unwrap();
        let ast = graph.get(mid).impl_ast.as_ref().unwrap();
        let selector_span = match &ast.body.as_ref().unwrap().stmts[0] {
            ast::Stmt::Assign { target, .. } => match &target.selectors[1] {
                ast::Selector::Field(_, span) => *span,
                other => panic!("expected field selector, got {other:?}"),
            },
            other => panic!("expected assignment stmt, got {other:?}"),
        };

        assert_eq!(
            result.selector_binding(mid, selector_span),
            Some(SelectorBinding::Field {
                ty: result.types.builtin(Builtin::Integer),
                // Slot 2: the class object record reserves slot 0 for the
                // vtable pointer (a=1, b=2).
                index: Some(2),
            })
        );
    }

    #[test]
    fn direct_field_selection_is_not_treated_as_module_qualification() {
        let dir = tmpdir("direct_field_selector");
        fs::write(
            dir.join("Fields.mod"),
            "MODULE Fields;\n\
             CLASS T;\n\
               VAR a, b: INTEGER;\n\
             END T;\n\
             VAR x: T;\n\
             BEGIN\n\
               x.b := 1\n\
             END Fields.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("Fields.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("Fields").unwrap();
        let ast = graph.get(mid).impl_ast.as_ref().unwrap();
        let (base_span, selector_span) = match &ast.body.as_ref().unwrap().stmts[0] {
            ast::Stmt::Assign { target, .. } => match &target.selectors[0] {
                ast::Selector::Field(_, span) => (target.base.span, *span),
                other => panic!("expected field selector, got {other:?}"),
            },
            other => panic!("expected assignment stmt, got {other:?}"),
        };

        assert!(matches!(result.resolved_name(mid, base_span), Some(SymbolKind::Var { .. })));
        assert_eq!(
            result.selector_binding(mid, selector_span),
            Some(SelectorBinding::Field {
                ty: result.types.builtin(Builtin::Integer),
                // Slot 2: the class object record reserves slot 0 for the
                // vtable pointer (a=1, b=2).
                index: Some(2),
            })
        );
    }

    #[test]
    fn module_member_resolution_is_recorded_on_selector_span() {
        let dir = tmpdir("module_member_resolution");
        fs::write(
            dir.join("M.def"),
            "DEFINITION MODULE M;\n\
             VAR x: INTEGER;\n\
             END M.\n",
        )
        .unwrap();
        fs::write(
            dir.join("User.mod"),
            "MODULE User;\n\
             IMPORT M;\n\
             BEGIN\n\
               M.x := 1\n\
             END User.\n",
        )
        .unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("User.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "errors: {:?}", result.diagnostics);

        let mid = graph.lookup("User").unwrap();
        let ast = graph.get(mid).impl_ast.as_ref().unwrap();
        let (base_span, selector_span, designator_span) = match &ast.body.as_ref().unwrap().stmts[0] {
            ast::Stmt::Assign { target, .. } => match &target.selectors[0] {
                ast::Selector::Field(_, span) => (target.base.span, *span, target.span),
                other => panic!("expected field selector, got {other:?}"),
            },
            other => panic!("expected assignment stmt, got {other:?}"),
        };

        assert!(matches!(result.resolved_name(mid, base_span), Some(SymbolKind::Module(..))));
        assert!(matches!(result.resolved_name(mid, selector_span), Some(SymbolKind::Var { .. })));
        assert_eq!(
            result.designator_type(mid, designator_span),
            Some(result.types.builtin(Builtin::Integer))
        );
    }

    #[test]
    fn oversized_fixed_array_type_is_rejected() {
        // `ARRAY CARDINAL OF CHAR` has 2^64 elements; sizing it would overflow
        // the LLVM array element count to 0 and segfault on the first index.
        // Sema rejects the type up front (here a procedure-local VAR, formed in
        // a non-deferred pass where the bare-builtin index cardinality is
        // reliable).
        let dir = tmpdir("oversized_array");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             PROCEDURE p;\n\
             VAR big: ARRAY CARDINAL OF CHAR;\n\
             BEGIN\n\
             END p;\n\
             BEGIN\n\
             END M.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(result.has_errors(), "expected oversized-array error");
        assert!(result
            .diagnostics
            .iter()
            .any(|d| d.message.contains("fixed array type is too large")));
    }

    #[test]
    fn pointer_to_huge_array_is_a_valid_flex_buffer() {
        // `POINTER TO ARRAY [0..MAX(CARDINAL)-1] OF CHAR` is the standard
        // flex-buffer view used throughout the ISO file devices: the array is
        // never materialised, only the pointer is stored, so the
        // array-too-large check must NOT fire behind a pointer. (guards A1)
        let dir = tmpdir("flex_buffer");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             IMPORT SYSTEM;\n\
             PROCEDURE read(a: SYSTEM.ADDRESS);\n\
             TYPE BufPtr = POINTER TO ARRAY [0..MAX(CARDINAL) - 1] OF CHAR;\n\
             VAR p: BufPtr;\n\
             BEGIN\n\
               p := SYSTEM.CAST(BufPtr, a);\n\
               p^[0] := 'x'\n\
             END read;\n\
             BEGIN\n\
             END M.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(
            !result.has_errors(),
            "flex-buffer pointer-to-huge-array should be accepted: {:?}",
            result.diagnostics
        );
    }

    #[test]
    fn runtime_char_array_concatenation_is_rejected_not_miscompiled() {
        // `s + t` for runtime ARRAY OF CHAR variables is not constant-foldable,
        // so the IR cannot lower it as concatenation. Sema must reject it as a
        // non-numeric `+` rather than mis-typing it as a string (mis-typing it
        // would reach codegen and cause an ICE).
        let dir = tmpdir("runtime_concat");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             VAR s, t: ARRAY [0..31] OF CHAR; u: ARRAY [0..63] OF CHAR;\n\
             BEGIN\n\
               u := s + t\n\
             END M.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(result.has_errors(), "runtime concat should be rejected");
        assert!(result
            .diagnostics
            .iter()
            .any(|d| d.message.contains("arithmetic operators require numeric operands")));
    }

    #[test]
    fn multichar_constant_string_is_not_assignable_to_char() {
        // `'a' + 'b'` folds to the 2-char string "ab". CHAR and the
        // string-element type share a family, so without an explicit length
        // check this would be silently truncated into a single CHAR cell.
        let dir = tmpdir("char_assign_multichar");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             VAR c: CHAR;\n\
             BEGIN\n\
               c := 'a' + 'b'\n\
             END M.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(result.has_errors(), "expected multi-char-to-CHAR error");
        assert!(result
            .diagnostics
            .iter()
            .any(|d| d.message.contains("multi-character string cannot be assigned to a CHAR")));
    }

    #[test]
    fn single_char_values_remain_assignable_to_char() {
        // The length check must not over-restrict: a length-1 literal, a folded
        // length-1 value, and the empty string `''` (the NUL character, a
        // Modula-2 idiom) are all valid CHAR r-values. (guards A3)
        let dir = tmpdir("char_assign_single");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             VAR c: CHAR;\n\
             BEGIN\n\
               c := 'x';\n\
               c := '';\n\
               c := CHR(65)\n\
             END M.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(!result.has_errors(), "single-char assignments should be valid: {:?}", result.diagnostics);
    }

    #[test]
    fn multi_hop_forward_const_resolves_to_fixpoint() {
        // `a` aliases `b` aliases `c` — a 3-hop forward chain. A single
        // re-evaluation pass leaves `a` at its placeholder 0; the fixpoint loop
        // resolves it to 22, so the subrange range-check below passes (a single
        // pass would fail with "out of range").
        let dir = tmpdir("multi_hop_const");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             CONST a = b; b = c; c = 22;\n\
             VAR x: [20..25];\n\
             BEGIN\n\
               x := a\n\
             END M.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        assert!(
            !result.has_errors(),
            "multi-hop forward const should resolve to 22: {:?}",
            result.diagnostics
        );
    }

    #[test]
    fn division_by_zero_const_is_reported_exactly_once() {
        // A non-literal CONST is evaluated in pass 2 and re-evaluated to a
        // fixpoint; a genuine error (1 DIV 0) must surface exactly once, not be
        // duplicated by the re-evaluation pass.
        let dir = tmpdir("const_div_zero");
        fs::write(
            dir.join("M.mod"),
            "MODULE M;\n\
             CONST bad = 1 DIV 0;\n\
             BEGIN\n\
             END M.\n",
        )
        .unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("M.mod"), &sp).unwrap();
        let result = check_module_graph(&graph);
        let hits = result
            .diagnostics
            .iter()
            .filter(|d| d.message.contains("division by zero"))
            .count();
        assert_eq!(
            hits, 1,
            "division by zero should be reported exactly once: {:?}",
            result.diagnostics
        );
    }
}
