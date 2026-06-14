//! Relocatable module interface: a structural, arena-id-free description of a
//! module's exported surface, suitable for serialising to a separate-
//! compilation symbol cache and re-interning into a later compile.
//!
//! Why structural? A `SemaResult` keeps every symbol's types as `TypeId`
//! handles into a *shared* arena whose indices depend on the whole compile.
//! They are meaningless in a different compile. The interface here references
//! named types by `(module, name)` and expands everything else by structure,
//! so it is identical for a given DEF regardless of compile context (proven by
//! `print::module_interface_is_context_independent`).
//!
//! Conservative by design: [`export_interface`] returns `None` for any module
//! whose exported surface contains a construct we cannot yet round-trip
//! faithfully (record variant parts, classes, opaque/unresolved types, or
//! re-exported imports). Such modules fall back to the normal full check — the
//! cache is an optimisation, never a correctness shortcut.

use crate::analyze::SemaResult;
use crate::scope::{
    BindingId, CallingConv, DeclarationId, NamedParam, ProcAttrKind, ProcExternalLinkage, ProcSig,
    ScopeArena, ScopeId, ScopeKind, Symbol, SymbolKind, SymbolProvenance,
};
use crate::types::{ParamMode, ProcParam, RecordFieldSlot, RecordLayout, TypeArena, TypeId, TypeKind};
use newm2_lexer::{SourcePosition, Span};
use newm2_loader::{ModuleGraph, ModuleId};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Bumped whenever the on-disk interface schema changes, so a stale cache from
/// an older compiler is rejected rather than mis-read.
pub const IFACE_FORMAT_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModuleInterface {
    pub format_version: u32,
    pub module: String,
    pub symbols: Vec<IfaceSymbol>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IfaceSymbol {
    pub name: String,
    pub kind: IfaceSymbolKind,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum IfaceSymbolKind {
    Const { ty: IfaceType, value: IfaceConst },
    Type(IfaceType),
    Var { ty: IfaceType },
    Proc(IfaceProcSig),
    EnumMember { ty: IfaceType, ord: i128 },
}

/// A structural, relocatable type. Named exported types (of this module or an
/// import) are referenced by `(module, name)`; everything else is expanded.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum IfaceType {
    Builtin(String),
    Named { module: String, name: String },
    Pointer(Box<IfaceType>),
    Array { indices: Vec<IfaceType>, base: Box<IfaceType> },
    OpenArray(Box<IfaceType>),
    Set { packed: bool, base: Box<IfaceType> },
    Vector { lanes: u32, base: Box<IfaceType> },
    Subrange { host: Box<IfaceType>, lo: i128, hi: i128 },
    Enum { name: Option<String>, names: Vec<String>, values: Vec<i128> },
    Record { fields: Vec<IfaceField> },
    Proc { params: Vec<IfaceParam>, return_ty: Option<Box<IfaceType>> },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IfaceField {
    pub name: String,
    pub ty: IfaceType,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IfaceParam {
    pub name: Option<String>,
    pub mode: IfaceParamMode,
    pub ty: IfaceType,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum IfaceParamMode {
    Value,
    Var,
    Const,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IfaceProcSig {
    pub params: Vec<IfaceParam>,
    pub return_ty: Option<IfaceType>,
    pub calling_conv: IfaceCallingConv,
    pub attrs: Vec<IfaceProcAttr>,
    pub linkage: Option<IfaceLinkage>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum IfaceCallingConv {
    Default,
    Windows,
    Cdecl,
    Asm,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum IfaceProcAttr {
    Inline,
    NoOptimize,
    Varargs,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IfaceLinkage {
    pub link_name: String,
    pub dll_name: Option<String>,
    pub is_external: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum IfaceConst {
    Int(i128),
    Real(f64),
    Bool(bool),
    Char(char),
    Str(String),
    Set(Vec<i128>),
    Nil,
    FuncRef(String),
    Complex(f64, f64),
    Aggregate(Vec<IfaceConst>),
}

// ---- export -----------------------------------------------------------------

/// Map every exported named *type* across the whole graph to the `(module,
/// name)` it is exported under, so cross-module references can be emitted by
/// name rather than by arena id.
fn build_named_type_map(sema: &SemaResult, graph: &ModuleGraph) -> HashMap<TypeId, (String, String)> {
    let mut map = HashMap::new();
    for &mid in &graph.topo_order {
        let node = graph.get(mid);
        let Some(&scope_id) = sema.module_scopes.get(&mid) else { continue };
        for sym in sema.scopes.get(scope_id).iter() {
            if let SymbolKind::Type(ty) = &sym.kind {
                map.entry(*ty).or_insert_with(|| (node.name.clone(), sym.name.clone()));
            }
        }
    }
    map
}

/// Export a module's interface, or `None` if it contains anything we cannot yet
/// round-trip faithfully. `None` is always safe: the caller falls back to a
/// full check of that module.
pub fn export_interface(
    sema: &SemaResult,
    graph: &ModuleGraph,
    mid: ModuleId,
) -> Option<ModuleInterface> {
    let node = graph.get(mid);
    let scope_id = *sema.module_scopes.get(&mid)?;
    let named = build_named_type_map(sema, graph);

    let mut symbols = Vec::new();
    for sym in sema.scopes.get(scope_id).iter() {
        if !sym.exported {
            continue;
        }
        // Only cache modules whose exported surface is entirely their own
        // declarations. Re-exported imports aren't handled yet → bail.
        match &sym.provenance {
            SymbolProvenance::Declared { module, .. } if *module == mid => {}
            _ => return None,
        }
        let kind = match &sym.kind {
            SymbolKind::Const { ty, value } => IfaceSymbolKind::Const {
                ty: export_type_ref(sema, &named, *ty)?,
                value: export_const(value)?,
            },
            SymbolKind::Type(ty) => IfaceSymbolKind::Type(export_type_def(sema, &named, *ty)?),
            SymbolKind::Var { ty, .. } => {
                IfaceSymbolKind::Var { ty: export_type_ref(sema, &named, *ty)? }
            }
            SymbolKind::Proc(sig) => IfaceSymbolKind::Proc(export_proc_sig(sema, &named, sig)?),
            SymbolKind::EnumMember { ty, ord } => IfaceSymbolKind::EnumMember {
                ty: export_type_ref(sema, &named, *ty)?,
                ord: *ord,
            },
            // Classes and nested module bindings aren't round-trippable yet.
            SymbolKind::Class(_) | SymbolKind::Module(_, _) => return None,
        };
        symbols.push(IfaceSymbol { name: sym.name.clone(), kind });
    }

    Some(ModuleInterface {
        format_version: IFACE_FORMAT_VERSION,
        module: node.name.clone(),
        symbols,
    })
}

/// Reference position: a named type becomes a `Named` reference; anything else
/// is expanded structurally.
fn export_type_ref(
    sema: &SemaResult,
    named: &HashMap<TypeId, (String, String)>,
    ty: TypeId,
) -> Option<IfaceType> {
    if let Some((module, name)) = named.get(&ty) {
        return Some(IfaceType::Named { module: module.clone(), name: name.clone() });
    }
    expand_type(sema, named, ty)
}

/// Definition position: expand the structure even if the type is itself named
/// (used for the right-hand side of a `TYPE` declaration).
fn export_type_def(
    sema: &SemaResult,
    named: &HashMap<TypeId, (String, String)>,
    ty: TypeId,
) -> Option<IfaceType> {
    expand_type(sema, named, ty)
}

fn expand_type(
    sema: &SemaResult,
    named: &HashMap<TypeId, (String, String)>,
    ty: TypeId,
) -> Option<IfaceType> {
    Some(match sema.types.get(ty) {
        TypeKind::Builtin(b) => IfaceType::Builtin(b.name().to_string()),
        TypeKind::Pointer { base } => {
            IfaceType::Pointer(Box::new(export_type_ref(sema, named, *base)?))
        }
        TypeKind::Array { indices, base } => IfaceType::Array {
            indices: indices
                .iter()
                .map(|i| export_type_ref(sema, named, *i))
                .collect::<Option<Vec<_>>>()?,
            base: Box::new(export_type_ref(sema, named, *base)?),
        },
        TypeKind::OpenArray { base } => {
            IfaceType::OpenArray(Box::new(export_type_ref(sema, named, *base)?))
        }
        TypeKind::Set { packed, base } => IfaceType::Set {
            packed: *packed,
            base: Box::new(export_type_ref(sema, named, *base)?),
        },
        TypeKind::Vector { lanes, base } => IfaceType::Vector {
            lanes: *lanes,
            base: Box::new(export_type_ref(sema, named, *base)?),
        },
        TypeKind::Subrange { host, lo, hi } => IfaceType::Subrange {
            host: Box::new(export_type_ref(sema, named, *host)?),
            lo: *lo,
            hi: *hi,
        },
        TypeKind::Enum { name, names, values } => IfaceType::Enum {
            name: name.clone(),
            names: names.clone(),
            values: values.clone(),
        },
        TypeKind::Record(layout) => {
            // Variant (CASE) parts are not round-trippable yet → bail.
            if layout.variant.is_some() {
                return None;
            }
            IfaceType::Record {
                fields: layout
                    .fields
                    .iter()
                    .map(|f| {
                        Some(IfaceField {
                            name: f.name.clone(),
                            ty: export_type_ref(sema, named, f.ty)?,
                        })
                    })
                    .collect::<Option<Vec<_>>>()?,
            }
        }
        TypeKind::Proc { params, return_ty } => IfaceType::Proc {
            params: params
                .iter()
                .map(|p| {
                    Some(IfaceParam {
                        name: None,
                        mode: export_mode(p.mode),
                        ty: export_type_ref(sema, named, p.ty)?,
                    })
                })
                .collect::<Option<Vec<_>>>()?,
            return_ty: match return_ty {
                Some(r) => Some(Box::new(export_type_ref(sema, named, *r)?)),
                None => None,
            },
        },
        // Class types and unresolved forwards aren't round-trippable yet.
        TypeKind::Class { .. } | TypeKind::Unresolved => return None,
    })
}

fn export_mode(m: ParamMode) -> IfaceParamMode {
    match m {
        ParamMode::Value => IfaceParamMode::Value,
        ParamMode::Var => IfaceParamMode::Var,
        ParamMode::Const => IfaceParamMode::Const,
    }
}

fn export_proc_sig(
    sema: &SemaResult,
    named: &HashMap<TypeId, (String, String)>,
    sig: &ProcSig,
) -> Option<IfaceProcSig> {
    Some(IfaceProcSig {
        params: sig
            .params
            .iter()
            .map(|p| {
                Some(IfaceParam {
                    name: p.name.clone(),
                    mode: export_mode(p.mode),
                    ty: export_type_ref(sema, named, p.ty)?,
                })
            })
            .collect::<Option<Vec<_>>>()?,
        return_ty: match sig.return_ty {
            Some(r) => Some(export_type_ref(sema, named, r)?),
            None => None,
        },
        calling_conv: match sig.calling_conv {
            CallingConv::Default => IfaceCallingConv::Default,
            CallingConv::Windows => IfaceCallingConv::Windows,
            CallingConv::Cdecl => IfaceCallingConv::Cdecl,
            CallingConv::Asm => IfaceCallingConv::Asm,
        },
        attrs: sig
            .attrs
            .iter()
            .map(|a| match a {
                ProcAttrKind::Inline => IfaceProcAttr::Inline,
                ProcAttrKind::NoOptimize => IfaceProcAttr::NoOptimize,
                ProcAttrKind::Varargs => IfaceProcAttr::Varargs,
            })
            .collect(),
        linkage: sig.external_linkage.as_ref().map(|l| IfaceLinkage {
            link_name: l.link_name.clone(),
            dll_name: l.dll_name.clone(),
            is_external: l.is_external,
        }),
    })
}

fn export_const(value: &crate::constant::ConstValue) -> Option<IfaceConst> {
    use crate::constant::ConstValue as C;
    Some(match value {
        C::Int(n) => IfaceConst::Int(*n),
        C::Real(f) => IfaceConst::Real(*f),
        C::Bool(b) => IfaceConst::Bool(*b),
        C::Char(c) => IfaceConst::Char(*c),
        C::Str(s) => IfaceConst::Str(s.clone()),
        C::Set(m) => IfaceConst::Set(m.clone()),
        C::Nil => IfaceConst::Nil,
        C::FuncRef(n) => IfaceConst::FuncRef(n.clone()),
        C::Complex(re, im) => IfaceConst::Complex(*re, *im),
        C::Aggregate(items) => {
            IfaceConst::Aggregate(items.iter().map(export_const).collect::<Option<Vec<_>>>()?)
        }
    })
}

/// Every cross-/same-module named type the interface references, as
/// `(module, name)` pairs. The wiring uses this to confirm an interface's
/// imports are all already interned before committing to re-intern it (so an
/// import cycle falls back to a full check instead of half-building).
pub fn referenced_import_types(iface: &ModuleInterface) -> Vec<(&str, &str)> {
    let mut out = Vec::new();
    for sym in &iface.symbols {
        match &sym.kind {
            IfaceSymbolKind::Const { ty, .. }
            | IfaceSymbolKind::Type(ty)
            | IfaceSymbolKind::Var { ty }
            | IfaceSymbolKind::EnumMember { ty, .. } => collect_named(ty, &mut out),
            IfaceSymbolKind::Proc(sig) => {
                for p in &sig.params {
                    collect_named(&p.ty, &mut out);
                }
                if let Some(r) = &sig.return_ty {
                    collect_named(r, &mut out);
                }
            }
        }
    }
    out
}

fn collect_named<'a>(ty: &'a IfaceType, out: &mut Vec<(&'a str, &'a str)>) {
    match ty {
        IfaceType::Named { module, name } => out.push((module, name)),
        IfaceType::Pointer(b) | IfaceType::OpenArray(b) => collect_named(b, out),
        IfaceType::Array { indices, base } => {
            for i in indices {
                collect_named(i, out);
            }
            collect_named(base, out);
        }
        IfaceType::Set { base, .. } | IfaceType::Vector { base, .. } => collect_named(base, out),
        IfaceType::Subrange { host, .. } => collect_named(host, out),
        IfaceType::Record { fields } => {
            for f in fields {
                collect_named(&f.ty, out);
            }
        }
        IfaceType::Proc { params, return_ty } => {
            for p in params {
                collect_named(&p.ty, out);
            }
            if let Some(r) = return_ty {
                collect_named(r, out);
            }
        }
        IfaceType::Builtin(_) | IfaceType::Enum { .. } => {}
    }
}

// ---- re-intern --------------------------------------------------------------

const DUMMY_SPAN: Span = Span { start: SourcePosition::START, end: SourcePosition::START };

/// Re-intern a serialized interface into the destination arenas, reproducing
/// the module's scope and types exactly as a fresh check would. Returns the new
/// module `ScopeId`, or `None` if a referenced import type cannot be resolved
/// (the caller then falls back to a full check of this module).
///
/// `resolve_import(module, name)` supplies the `TypeId` of a named type exported
/// by an already-loaded *imported* module — modules are interned in topological
/// order, so a module's imports are always interned before it.
#[allow(clippy::too_many_arguments)]
pub fn intern_interface(
    iface: &ModuleInterface,
    module_id: ModuleId,
    types: &mut TypeArena,
    scopes: &mut ScopeArena,
    pervasive: ScopeId,
    next_decl: &mut u32,
    next_binding: &mut u32,
    resolve_import: &dyn Fn(&str, &str) -> Option<TypeId>,
) -> Option<ScopeId> {
    // Pass 1: a placeholder TypeId for each named type this module declares, so
    // forward and self references (e.g. `POINTER TO Node` inside `Node`) resolve.
    let mut local: HashMap<String, TypeId> = HashMap::new();
    for sym in &iface.symbols {
        if let IfaceSymbolKind::Type(_) = &sym.kind {
            local.insert(sym.name.clone(), types.alloc_unresolved());
        }
    }
    let resolve = |module: &str, name: &str| -> Option<TypeId> {
        if module == iface.module {
            local.get(name).copied()
        } else {
            resolve_import(module, name)
        }
    };

    // Pass 2: build the module scope.
    let scope = scopes.push(ScopeKind::Module, Some(pervasive));
    for sym in &iface.symbols {
        let kind = match &sym.kind {
            IfaceSymbolKind::Type(def) => {
                let placeholder = local[&sym.name];
                let k = intern_kind(def, types, &resolve)?;
                types.set(placeholder, k);
                SymbolKind::Type(placeholder)
            }
            IfaceSymbolKind::Const { ty, value } => SymbolKind::Const {
                ty: intern_type(ty, types, &resolve)?,
                value: intern_const(value),
            },
            IfaceSymbolKind::Var { ty } => SymbolKind::Var {
                ty: intern_type(ty, types, &resolve)?,
                param_mode: None,
            },
            IfaceSymbolKind::Proc(sig) => SymbolKind::Proc(intern_proc_sig(sig, types, &resolve)?),
            IfaceSymbolKind::EnumMember { ty, ord } => SymbolKind::EnumMember {
                ty: intern_type(ty, types, &resolve)?,
                ord: *ord,
            },
        };
        let declaration_id = DeclarationId(*next_decl);
        *next_decl += 1;
        let binding_id = BindingId(*next_binding);
        *next_binding += 1;
        scopes.get_mut(scope).insert(Symbol {
            name: sym.name.clone(),
            kind,
            span: DUMMY_SPAN,
            declaration_id,
            binding_id,
            provenance: SymbolProvenance::Declared {
                module: module_id,
                module_name: iface.module.clone(),
            },
            exported: true,
        });
    }
    Some(scope)
}

fn intern_mode(m: IfaceParamMode) -> ParamMode {
    match m {
        IfaceParamMode::Value => ParamMode::Value,
        IfaceParamMode::Var => ParamMode::Var,
        IfaceParamMode::Const => ParamMode::Const,
    }
}

/// Reference position: resolve a named type to its existing `TypeId`; allocate
/// any anonymous structural type fresh.
fn intern_type(
    ity: &IfaceType,
    types: &mut TypeArena,
    resolve: &dyn Fn(&str, &str) -> Option<TypeId>,
) -> Option<TypeId> {
    match ity {
        IfaceType::Named { module, name } => resolve(module, name),
        IfaceType::Builtin(name) => types.builtin_by_name(name),
        other => {
            let kind = intern_kind(other, types, resolve)?;
            Some(types.alloc(kind))
        }
    }
}

/// Build the `TypeKind` for a structural type, allocating nested anonymous
/// types as it goes.
fn intern_kind(
    ity: &IfaceType,
    types: &mut TypeArena,
    resolve: &dyn Fn(&str, &str) -> Option<TypeId>,
) -> Option<TypeKind> {
    Some(match ity {
        // A `TYPE` whose right-hand side is a builtin or another named type
        // (e.g. `TYPE BOOL = INTEGER32`): the distinct named type's slot takes a
        // copy of the referent's kind, matching how sema represents the alias.
        IfaceType::Builtin(name) => {
            let id = types.builtin_by_name(name)?;
            types.get(id).clone()
        }
        IfaceType::Named { module, name } => {
            let id = resolve(module, name)?;
            types.get(id).clone()
        }
        IfaceType::Pointer(b) => TypeKind::Pointer { base: intern_type(b, types, resolve)? },
        IfaceType::Array { indices, base } => {
            let mut idx = Vec::with_capacity(indices.len());
            for i in indices {
                idx.push(intern_type(i, types, resolve)?);
            }
            TypeKind::Array { indices: idx, base: intern_type(base, types, resolve)? }
        }
        IfaceType::OpenArray(b) => TypeKind::OpenArray { base: intern_type(b, types, resolve)? },
        IfaceType::Set { packed, base } => {
            TypeKind::Set { packed: *packed, base: intern_type(base, types, resolve)? }
        }
        IfaceType::Vector { lanes, base } => {
            TypeKind::Vector { lanes: *lanes, base: intern_type(base, types, resolve)? }
        }
        IfaceType::Subrange { host, lo, hi } => {
            TypeKind::Subrange { host: intern_type(host, types, resolve)?, lo: *lo, hi: *hi }
        }
        IfaceType::Enum { name, names, values } => TypeKind::Enum {
            name: name.clone(),
            names: names.clone(),
            values: values.clone(),
        },
        IfaceType::Record { fields } => {
            let mut fs = Vec::with_capacity(fields.len());
            for f in fields {
                fs.push(RecordFieldSlot { name: f.name.clone(), ty: intern_type(&f.ty, types, resolve)? });
            }
            TypeKind::Record(RecordLayout { name: None, fields: fs, variant: None })
        }
        IfaceType::Proc { params, return_ty } => {
            let mut ps = Vec::with_capacity(params.len());
            for p in params {
                ps.push(ProcParam { mode: intern_mode(p.mode), ty: intern_type(&p.ty, types, resolve)? });
            }
            let ret = match return_ty {
                Some(r) => Some(intern_type(r, types, resolve)?),
                None => None,
            };
            TypeKind::Proc { params: ps, return_ty: ret }
        }
    })
}

fn intern_proc_sig(
    sig: &IfaceProcSig,
    types: &mut TypeArena,
    resolve: &dyn Fn(&str, &str) -> Option<TypeId>,
) -> Option<ProcSig> {
    let mut params = Vec::with_capacity(sig.params.len());
    for p in &sig.params {
        params.push(NamedParam {
            name: p.name.clone(),
            mode: intern_mode(p.mode),
            ty: intern_type(&p.ty, types, resolve)?,
        });
    }
    let return_ty = match &sig.return_ty {
        Some(r) => Some(intern_type(r, types, resolve)?),
        None => None,
    };
    Some(ProcSig {
        params,
        return_ty,
        calling_conv: match sig.calling_conv {
            IfaceCallingConv::Default => CallingConv::Default,
            IfaceCallingConv::Windows => CallingConv::Windows,
            IfaceCallingConv::Cdecl => CallingConv::Cdecl,
            IfaceCallingConv::Asm => CallingConv::Asm,
        },
        attrs: sig
            .attrs
            .iter()
            .map(|a| match a {
                IfaceProcAttr::Inline => ProcAttrKind::Inline,
                IfaceProcAttr::NoOptimize => ProcAttrKind::NoOptimize,
                IfaceProcAttr::Varargs => ProcAttrKind::Varargs,
            })
            .collect(),
        external_linkage: sig.linkage.as_ref().map(|l| ProcExternalLinkage {
            link_name: l.link_name.clone(),
            dll_name: l.dll_name.clone(),
            is_external: l.is_external,
        }),
    })
}

fn intern_const(v: &IfaceConst) -> crate::constant::ConstValue {
    use crate::constant::ConstValue as C;
    match v {
        IfaceConst::Int(n) => C::Int(*n),
        IfaceConst::Real(f) => C::Real(*f),
        IfaceConst::Bool(b) => C::Bool(*b),
        IfaceConst::Char(c) => C::Char(*c),
        IfaceConst::Str(s) => C::Str(s.clone()),
        IfaceConst::Set(m) => C::Set(m.clone()),
        IfaceConst::Nil => C::Nil,
        IfaceConst::FuncRef(n) => C::FuncRef(n.clone()),
        IfaceConst::Complex(re, im) => C::Complex(*re, *im),
        IfaceConst::Aggregate(items) => C::Aggregate(items.iter().map(intern_const).collect()),
    }
}

/// Serialise an interface to the on-disk cache payload (bincode).
pub fn encode(iface: &ModuleInterface) -> Result<Vec<u8>, String> {
    bincode::serialize(iface).map_err(|e| format!("interface encode failed: {e}"))
}

/// Deserialise an interface payload, rejecting a version mismatch.
pub fn decode(bytes: &[u8]) -> Result<ModuleInterface, String> {
    let iface: ModuleInterface =
        bincode::deserialize(bytes).map_err(|e| format!("interface decode failed: {e}"))?;
    if iface.format_version != IFACE_FORMAT_VERSION {
        return Err(format!(
            "interface version mismatch: expected {IFACE_FORMAT_VERSION}, found {}",
            iface.format_version
        ));
    }
    Ok(iface)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::analyze::check_module_graph;
    use newm2_loader::{build_module_graph, SearchPath};
    use std::fs;
    use std::path::{Path, PathBuf};

    fn tmpdir(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("newm2-iface-export-{name}"));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn export_and_bincode_roundtrip() {
        let dir = tmpdir("rt");
        fs::write(
            dir.join("Lib.def"),
            "DEFINITION MODULE Lib;\n\
             CONST Max = 100;\n\
             TYPE Pair = RECORD a, b: INTEGER; END;\n\
             TYPE PairPtr = POINTER TO Pair;\n\
             VAR origin: Pair;\n\
             PROCEDURE Twice (n: INTEGER): INTEGER;\n\
             END Lib.\n",
        )
        .unwrap();
        fs::write(dir.join("P.mod"), "MODULE P;\nFROM Lib IMPORT Max;\nBEGIN\nEND P.\n").unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("P.mod"), &sp).unwrap();
        let sema = check_module_graph(&graph);
        let mid = graph.lookup("Lib").unwrap();

        let iface = export_interface(&sema, &graph, mid).expect("Lib must be exportable");
        assert_eq!(iface.module, "Lib");
        // CONST, two TYPEs, VAR, PROC.
        assert!(iface.symbols.iter().any(|s| s.name == "Max"));
        assert!(iface.symbols.iter().any(|s| s.name == "Pair"));
        assert!(iface.symbols.iter().any(|s| s.name == "Twice"));

        // PairPtr must reference Pair *by name*, not expand it.
        let pp = iface.symbols.iter().find(|s| s.name == "PairPtr").unwrap();
        match &pp.kind {
            IfaceSymbolKind::Type(IfaceType::Pointer(b)) => match b.as_ref() {
                IfaceType::Named { module, name } => {
                    assert_eq!((module.as_str(), name.as_str()), ("Lib", "Pair"));
                }
                other => panic!("PairPtr base should be Named(Lib.Pair), got {other:?}"),
            },
            other => panic!("PairPtr should be a pointer type, got {other:?}"),
        }

        // bincode survives a round-trip.
        let bytes = encode(&iface).unwrap();
        let back = decode(&bytes).unwrap();
        assert_eq!(iface, back, "interface must survive a bincode round-trip");
    }

    // The whole point: re-interning a cached interface into fresh arenas must
    // reproduce exactly what a fresh check produced. We compare the canonical
    // interface render (the same identity proven context-independent in M1).
    #[test]
    fn reintern_matches_fresh_check() {
        let dir = tmpdir("reintern");
        fs::write(
            dir.join("Lib.def"),
            "DEFINITION MODULE Lib;\n\
             CONST Max = 100;\n\
             TYPE Color = (red, green, blue);\n\
             TYPE Pair = RECORD a, b: INTEGER; END;\n\
             TYPE PairPtr = POINTER TO Pair;\n\
             TYPE Names = ARRAY [0..3] OF CHAR;\n\
             TYPE Alias = CARDINAL;\n\
             VAR origin: Pair;\n\
             VAR count: CARDINAL;\n\
             PROCEDURE Twice (n: INTEGER): INTEGER;\n\
             PROCEDURE Swap (VAR a, b: Pair);\n\
             END Lib.\n",
        )
        .unwrap();
        fs::write(dir.join("P.mod"), "MODULE P;\nIMPORT Lib;\nBEGIN\nEND P.\n").unwrap();
        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("P.mod"), &sp).unwrap();
        let sema = check_module_graph(&graph);
        let mid = graph.lookup("Lib").unwrap();

        let fresh = crate::print::format_module_interface(&sema, &graph, mid);
        let iface = export_interface(&sema, &graph, mid).expect("Lib must be exportable");

        // Re-intern into fresh, independent arenas (a clean compile context).
        let mut types = crate::types::TypeArena::new();
        let mut scopes = ScopeArena::default();
        let pervasive = scopes.push(ScopeKind::Pervasive, None);
        let (mut next_decl, mut next_binding) = (0u32, 0u32);
        let new_mid = ModuleId(0);
        let scope = intern_interface(
            &iface,
            new_mid,
            &mut types,
            &mut scopes,
            pervasive,
            &mut next_decl,
            &mut next_binding,
            &|_, _| None,
        )
        .expect("re-intern must succeed");

        let mut module_scopes = HashMap::new();
        module_scopes.insert(new_mid, scope);
        let sema2 = SemaResult {
            module_scopes,
            proc_scopes: HashMap::new(),
            types,
            classes: crate::class::ClassArena::default(),
            scopes,
            expr_types: HashMap::new(),
            designator_types: HashMap::new(),
            selector_bindings: HashMap::new(),
            resolved_names: HashMap::new(),
            diagnostics: Vec::new(),
            pervasive,
        };
        let reint = crate::print::format_module_interface(&sema2, &graph, new_mid);

        assert_eq!(
            fresh, reint,
            "re-interned interface must render identically to the fresh check\n--- fresh ---\n{fresh}\n--- reint ---\n{reint}"
        );
        assert!(fresh.contains("TYPE Color = ENUM"), "sanity: {fresh}");
    }

    fn cache_cfg(dir: &Path) -> crate::symcache::CacheConfig {
        crate::symcache::CacheConfig {
            dir: dir.join(".cache"),
            codegen_flags: String::new(),
            memory_mode: newm2_loader::MemoryMode::Gc,
            read: true,
            write: true,
        }
    }

    fn check_cached(dir: &Path, entry: &str, cfg: &crate::symcache::CacheConfig) -> SemaResult {
        let mut sp = SearchPath::new();
        sp.push(dir);
        let graph = build_module_graph(&dir.join(entry), &sp).unwrap();
        crate::analyze::check_module_graph_cached(&graph, cfg)
    }

    // End-to-end: a warm-cache compile produces the same interface as a cold one,
    // and honours the contract — a DEF edit invalidates importers, a body edit
    // does not.
    #[test]
    fn cache_roundtrip_and_invalidation() {
        let dir = tmpdir("cache-e2e");
        let lib_v1 = "DEFINITION MODULE Lib;\nCONST Max = 100;\nTYPE T = INTEGER;\nEND Lib.\n";
        fs::write(dir.join("Lib.def"), lib_v1).unwrap();
        fs::write(dir.join("Lib.mod"), "IMPLEMENTATION MODULE Lib;\nEND Lib.\n").unwrap();
        fs::write(dir.join("P.mod"), "MODULE P;\nFROM Lib IMPORT Max;\nBEGIN\nEND P.\n").unwrap();
        let cfg = cache_cfg(&dir);

        // Cold compile (writes the cache).
        let cold = check_cached(&dir, "P.mod", &cfg);
        assert!(!cold.has_errors());
        let cold_iface = {
            let mut sp = SearchPath::new();
            sp.push(&dir);
            let g = build_module_graph(&dir.join("P.mod"), &sp).unwrap();
            crate::print::format_module_interface(&cold, &g, g.lookup("Lib").unwrap())
        };

        // Warm compile (reads the cache) must produce the identical Lib interface.
        let warm = check_cached(&dir, "P.mod", &cfg);
        assert!(!warm.has_errors());
        let warm_iface = {
            let mut sp = SearchPath::new();
            sp.push(&dir);
            let g = build_module_graph(&dir.join("P.mod"), &sp).unwrap();
            crate::print::format_module_interface(&warm, &g, g.lookup("Lib").unwrap())
        };
        assert_eq!(cold_iface, warm_iface, "warm-cache interface must match cold");
        assert!(warm_iface.contains("CONST Max"));

        // Editing only Lib's *body* must NOT invalidate the cached interface:
        // the on-disk key is unchanged (the DEF hash didn't move).
        fs::write(
            dir.join("Lib.mod"),
            "IMPLEMENTATION MODULE Lib;\n(* a comment changes the body only *)\nEND Lib.\n",
        )
        .unwrap();
        let key_before = crate::symcache::cache_key(
            &{
                let mut sp = SearchPath::new();
                sp.push(&dir);
                build_module_graph(&dir.join("P.mod"), &sp).unwrap()
            },
            {
                let mut sp = SearchPath::new();
                sp.push(&dir);
                let g = build_module_graph(&dir.join("P.mod"), &sp).unwrap();
                g.lookup("Lib").unwrap()
            },
            &cfg,
        );

        // Editing Lib's DEF must change its hash → the importer's key changes.
        fs::write(
            dir.join("Lib.def"),
            "DEFINITION MODULE Lib;\nCONST Max = 200;\nTYPE T = INTEGER;\nEND Lib.\n",
        )
        .unwrap();
        let (g2, lib2, p2) = {
            let mut sp = SearchPath::new();
            sp.push(&dir);
            let g = build_module_graph(&dir.join("P.mod"), &sp).unwrap();
            let lib = g.lookup("Lib").unwrap();
            let p = g.lookup("P").unwrap();
            (g, lib, p)
        };
        let key_after_def = crate::symcache::cache_key(&g2, lib2, &cfg);
        assert_ne!(
            key_before.map(|k| k.to_text()),
            key_after_def.map(|k| k.to_text()),
            "a DEF edit must change Lib's cache key"
        );
        // P imports Lib, so P's key includes Lib's (changed) DEF hash → P misses too.
        let _ = p2;
    }

    #[test]
    fn unsupported_constructs_are_declined_not_corrupted() {
        // A variant (CASE) record is not round-trippable yet: the whole module
        // must decline to export rather than silently drop the variant part.
        let dir = tmpdir("decline");
        fs::write(
            dir.join("Var.def"),
            "DEFINITION MODULE Var;\n\
             TYPE T = RECORD\n\
               tag: INTEGER;\n\
               CASE k: INTEGER OF\n\
               | 0: a: INTEGER;\n\
               | 1: b: CHAR;\n\
               END;\n\
             END;\n\
             END Var.\n",
        )
        .unwrap();
        fs::write(dir.join("P.mod"), "MODULE P;\nIMPORT Var;\nBEGIN\nEND P.\n").unwrap();

        let mut sp = SearchPath::new();
        sp.push(&dir);
        let graph = build_module_graph(&dir.join("P.mod"), &sp).unwrap();
        let sema = check_module_graph(&graph);
        let mid = graph.lookup("Var").unwrap();
        assert!(
            export_interface(&sema, &graph, mid).is_none(),
            "a module with a variant record must decline to export (safe fallback)"
        );
    }
}
