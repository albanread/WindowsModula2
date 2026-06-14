//! Symbol table: scopes, symbols, procedure signatures.
//!
//! Every syntactic scope in a Modula-2 program corresponds to a `Scope`
//! node in the `ScopeArena`.  Scopes form a parent-chain; lookup walks
//! up the chain until the pervasive (built-in) scope at the root.
//!
//! The four scope kinds the language defines:
//! - `Pervasive` — pre-declared identifiers (INTEGER, BOOLEAN, TRUE, …).
//! - `Module`    — top-level DEFINITION / IMPLEMENTATION / PROGRAM scope.
//! - `Procedure` — procedure or function body (includes parameters).
//! - `LocalModule` — MODULE … END nested inside a procedure.
//! - `Block`     — anonymous block introduced by WITH or a plain BEGIN.
//!
//! Each `Symbol` carries the `SymbolKind` (const, type, var, proc, …),
//! its span for diagnostics, provenance, and an `exported` flag.

use std::collections::HashMap;

use newm2_lexer::Span;
use newm2_loader::ModuleId;

use crate::class::ClassSymbolId;
use crate::constant::ConstValue;
use crate::types::TypeId;

// ---- Scope ----------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ScopeId(pub u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScopeKind {
    Pervasive,
    Module,
    Procedure,
    LocalModule,
    Block,
}

#[derive(Debug, Clone)]
pub struct Scope {
    pub kind: ScopeKind,
    pub parent: Option<ScopeId>,
    /// Insertion-ordered map so `format_sema` output is deterministic.
    symbols: Vec<(String, Symbol)>,
    /// Fast-lookup index into `symbols`.
    index: HashMap<String, usize>,
}

impl Scope {
    pub fn new(kind: ScopeKind, parent: Option<ScopeId>) -> Self {
        Self { kind, parent, symbols: Vec::new(), index: HashMap::new() }
    }

    /// Insert a symbol.  Silently overwrites if the name already exists
    /// (the caller is responsible for raising a "duplicate" diagnostic
    /// before calling this if needed).
    pub fn insert(&mut self, sym: Symbol) {
        let name = sym.name.clone();
        if let Some(&idx) = self.index.get(&name) {
            self.symbols[idx].1 = sym;
        } else {
            let idx = self.symbols.len();
            self.symbols.push((name.clone(), sym));
            self.index.insert(name, idx);
        }
    }

    /// Look up a symbol by exact name in *this* scope only (no parent walk).
    pub fn get(&self, name: &str) -> Option<&Symbol> {
        self.index.get(name).map(|&i| &self.symbols[i].1)
    }

    /// Mutable lookup — used by the analyser to back-patch placeholders.
    pub fn get_mut(&mut self, name: &str) -> Option<&mut Symbol> {
        self.index.get(name).copied().map(|i| &mut self.symbols[i].1)
    }

    /// Number of symbols in this scope (cheap; used to invalidate the
    /// const-lookup cache when the symbol set grows).
    pub fn symbol_count(&self) -> usize {
        self.symbols.len()
    }

    /// Iterate symbols in insertion order.
    pub fn iter(&self) -> impl Iterator<Item = &Symbol> {
        self.symbols.iter().map(|(_, s)| s)
    }

    /// Iterate symbols mutably in insertion order.
    pub fn iter_mut(&mut self) -> impl Iterator<Item = &mut Symbol> {
        self.symbols.iter_mut().map(|(_, s)| s)
    }
}

#[derive(Debug, Default)]
pub struct ScopeArena {
    scopes: Vec<Scope>,
}

impl ScopeArena {
    pub fn push(&mut self, kind: ScopeKind, parent: Option<ScopeId>) -> ScopeId {
        let id = ScopeId(self.scopes.len() as u32);
        self.scopes.push(Scope::new(kind, parent));
        id
    }

    pub fn get(&self, id: ScopeId) -> &Scope {
        &self.scopes[id.0 as usize]
    }

    pub fn get_mut(&mut self, id: ScopeId) -> &mut Scope {
        &mut self.scopes[id.0 as usize]
    }

    /// Walk `scope` and all ancestors, returning the first `Symbol`
    /// with the given `name`.  Stops at the pervasive scope.
    pub fn lookup(&self, mut scope: ScopeId, name: &str) -> Option<&Symbol> {
        loop {
            let s = self.get(scope);
            if let Some(sym) = s.get(name) {
                return Some(sym);
            }
            scope = s.parent?;
        }
    }

    /// Walk *only* the current scope and module-level parents, skipping
    /// procedure scopes.  Used for exported-name lookup when importing a
    /// module: we only see module-level names, not procedure locals.
    pub fn lookup_module_level(&self, mut scope: ScopeId, name: &str) -> Option<&Symbol> {
        loop {
            let s = self.get(scope);
            if matches!(s.kind, ScopeKind::Module | ScopeKind::Pervasive) {
                if let Some(sym) = s.get(name) {
                    return Some(sym);
                }
            }
            scope = s.parent?;
        }
    }
}

// ---- Symbol ---------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DeclarationId(pub u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BindingId(pub u32);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportProvenanceHop {
    pub from_module: ModuleId,
    pub from_module_name: String,
    pub import_span: Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SymbolProvenance {
    Pervasive,
    Declared {
        module: ModuleId,
        module_name: String,
    },
    Imported {
        from_module: ModuleId,
        from_module_name: String,
        original_module: Option<ModuleId>,
        original_module_name: Option<String>,
        original_name: String,
        import_span: Span,
        import_chain: Vec<ImportProvenanceHop>,
    },
    Intrinsic {
        module: ModuleId,
        module_name: String,
    },
}

impl SymbolProvenance {
    pub fn declaring_module(&self) -> Option<(ModuleId, &str)> {
        match self {
            SymbolProvenance::Declared { module, module_name }
            | SymbolProvenance::Intrinsic { module, module_name } => Some((*module, module_name.as_str())),
            SymbolProvenance::Imported {
                original_module: Some(module),
                original_module_name: Some(module_name),
                ..
            } => Some((*module, module_name.as_str())),
            SymbolProvenance::Pervasive
            | SymbolProvenance::Imported {
                original_module: None,
                ..
            }
            | SymbolProvenance::Imported {
                original_module_name: None,
                ..
            } => None,
        }
    }

    pub fn immediate_import(&self) -> Option<&ImportProvenanceHop> {
        match self {
            SymbolProvenance::Imported { import_chain, .. } => import_chain.first(),
            _ => None,
        }
    }

    pub fn import_chain(&self) -> &[ImportProvenanceHop] {
        match self {
            SymbolProvenance::Imported { import_chain, .. } => import_chain,
            _ => &[],
        }
    }

    pub fn root_name(&self) -> Option<&str> {
        match self {
            SymbolProvenance::Pervasive => None,
            SymbolProvenance::Declared { .. } | SymbolProvenance::Intrinsic { .. } => None,
            SymbolProvenance::Imported { original_name, .. } => Some(original_name.as_str()),
        }
    }

    pub fn is_imported(&self) -> bool {
        matches!(self, SymbolProvenance::Imported { .. })
    }
}

#[derive(Debug, Clone)]
pub struct Symbol {
    pub name: String,
    pub kind: SymbolKind,
    pub span: Span,
    pub declaration_id: DeclarationId,
    pub binding_id: BindingId,
    pub provenance: SymbolProvenance,
    pub exported: bool,
}

impl Symbol {
    pub fn imported_from(
        &self,
        from_module: ModuleId,
        from_module_name: &str,
        import_span: Span,
        binding_id: BindingId,
    ) -> Self {
        let (original_module, original_module_name, original_name, mut import_chain) = match &self.provenance {
            SymbolProvenance::Imported {
                original_module,
                original_module_name,
                original_name,
                import_chain,
                ..
            } => (*original_module, original_module_name.clone(), original_name.clone(), import_chain.clone()),
            SymbolProvenance::Intrinsic { module, module_name } => {
                (Some(*module), Some(module_name.clone()), self.name.clone(), Vec::new())
            }
            SymbolProvenance::Declared { module, module_name } => {
                (Some(*module), Some(module_name.clone()), self.name.clone(), Vec::new())
            }
            SymbolProvenance::Pervasive => (None, None, self.name.clone(), Vec::new()),
        };
        import_chain.insert(0, ImportProvenanceHop {
            from_module,
            from_module_name: from_module_name.to_string(),
            import_span,
        });

        let mut imported = self.clone();
        imported.binding_id = binding_id;
        imported.provenance = SymbolProvenance::Imported {
            from_module,
            from_module_name: from_module_name.to_string(),
            original_module,
            original_module_name,
            original_name,
            import_span,
            import_chain,
        };
        imported
    }
}

#[derive(Debug, Clone)]
pub enum SymbolKind {
    /// A compile-time constant.
    Const { ty: TypeId, value: ConstValue },
    /// A type declaration.
    Type(TypeId),
    /// A variable (global or local).
    Var {
        ty: TypeId,
        param_mode: Option<crate::types::ParamMode>,
    },
    /// A procedure or function.
    Proc(ProcSig),
    /// A module reference (used for qualified-name lookup: `M.x`).
    Module(ModuleId, ScopeId),
    /// A class type.
    Class(ClassSymbolId),
    /// An enumeration member (`ord` = ordinal value in the enum).
    EnumMember { ty: TypeId, ord: i128 },
}

impl SymbolKind {
    pub fn kind_name(&self) -> &'static str {
        match self {
            SymbolKind::Const { .. } => "constant",
            SymbolKind::Type(_) => "type",
            SymbolKind::Var { .. } => "variable",
            SymbolKind::Proc(_) => "procedure",
            SymbolKind::Module(..) => "module",
            SymbolKind::Class(_) => "class",
            SymbolKind::EnumMember { .. } => "enumeration member",
        }
    }
}

// ---- Procedure signature --------------------------------------------------

/// A resolved procedure / method signature.
#[derive(Debug, Clone, PartialEq)]
pub struct ProcSig {
    pub params: Vec<NamedParam>,
    pub return_ty: Option<TypeId>,
    pub calling_conv: CallingConv,
    pub attrs: Vec<ProcAttrKind>,
    pub external_linkage: Option<ProcExternalLinkage>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcExternalLinkage {
    pub link_name: String,
    pub dll_name: Option<String>,
    pub is_external: bool,
}

/// A procedure parameter with optional name (anonymous in type expressions).
#[derive(Debug, Clone, PartialEq)]
pub struct NamedParam {
    pub name: Option<String>,
    pub mode: crate::types::ParamMode,
    pub ty: TypeId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallingConv {
    /// Default for the target (Win64 CC on x86_64-windows-msvc).
    Default,
    /// `<*PROCATTR Windows*>` — explicit Win64 CC (same as Default on
    /// the current target, kept for semantic annotation).
    Windows,
    /// `<*PROCATTR CDECL*>`.
    Cdecl,
    /// `<*PROCATTR Asm*>`.
    Asm,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcAttrKind {
    Inline,
    NoOptimize,
    /// C-style variadic procedure (`PROCEDURE p(fixed; ...)`), e.g. printf.
    Varargs,
}

impl ProcSig {
    /// Two procedure types are compatible if their parameter sequences
    /// and return types agree (PIM §6.9).  Calling convention and
    /// attribute tags are *not* part of type compatibility; they are
    /// codegen annotations.
    pub fn type_compatible(&self, other: &ProcSig) -> bool {
        if self.return_ty != other.return_ty {
            return false;
        }
        if self.params.len() != other.params.len() {
            return false;
        }
        self.params.iter().zip(&other.params).all(|(a, b)| {
            a.mode == b.mode && a.ty == b.ty
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Builtin, TypeArena};
    use newm2_lexer::{SourcePosition, Span};

    const ZERO: Span = Span {
        start: SourcePosition { line: 1, column: 1, offset: 0 },
        end: SourcePosition { line: 1, column: 1, offset: 0 },
    };

    #[test]
    fn scope_insert_lookup() {
        let mut arena = ScopeArena::default();
        let ta = TypeArena::new();
        let root = arena.push(ScopeKind::Pervasive, None);
        let scope = arena.push(ScopeKind::Module, Some(root));
        let int_id = ta.builtin(Builtin::Integer);
        arena.get_mut(scope).insert(Symbol {
            name: "x".into(),
            kind: SymbolKind::Var {
                ty: int_id,
                param_mode: None,
            },
            span: ZERO,
            declaration_id: DeclarationId(0),
            binding_id: BindingId(0),
            provenance: SymbolProvenance::Declared {
                module: ModuleId(0),
                module_name: "<test>".into(),
            },
            exported: false,
        });
        // Direct lookup.
        assert!(arena.get(scope).get("x").is_some());
        // Lookup across parent chain.
        let child = arena.push(ScopeKind::Block, Some(scope));
        assert!(arena.lookup(child, "x").is_some());
        assert!(arena.lookup(child, "z").is_none());
    }

    #[test]
    fn proc_sig_type_compatible() {
        let ta = TypeArena::new();
        let int_id = ta.builtin(Builtin::Integer);
        let sig_a = ProcSig {
            params: vec![NamedParam {
                name: Some("n".into()),
                mode: crate::types::ParamMode::Value,
                ty: int_id,
            }],
            return_ty: Some(int_id),
            calling_conv: CallingConv::Default,
            attrs: vec![],
            external_linkage: None,
        };
        let sig_b = ProcSig {
            params: vec![NamedParam {
                name: Some("m".into()), // different name — still compatible
                mode: crate::types::ParamMode::Value,
                ty: int_id,
            }],
            return_ty: Some(int_id),
            calling_conv: CallingConv::Windows,  // different CC — still compatible
            attrs: vec![],
            external_linkage: None,
        };
        assert!(sig_a.type_compatible(&sig_b));
    }
}
