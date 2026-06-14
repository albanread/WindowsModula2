//! Module-graph data structures.

use crate::cache::ContentHash;
use newm2_parser::ast;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ModuleId(pub usize);

#[derive(Debug, Clone)]
pub struct ModuleNode {
    pub id: ModuleId,
    pub name: String,
    /// `None` for the SYSTEM intrinsic module and other compiler-
    /// provided pseudo-modules that have no on-disk DEF.
    pub def_path: Option<PathBuf>,
    pub impl_path: Option<PathBuf>,
    /// `None` for intrinsics; `Some` once the DEF has been parsed.
    pub def_ast: Option<ast::Module>,
    /// Implementation AST. Only populated when the IMPL is found
    /// AND was requested (PROGRAM modules always parse their body).
    pub impl_ast: Option<ast::Module>,
    /// DJB2 hash of the DEF source — `None` for intrinsics.
    pub def_hash: Option<ContentHash>,
    /// Direct imports in source order (resolved to graph IDs).
    pub imports: Vec<ModuleId>,
    /// LOCAL MODULE declarations found in any procedure body of this
    /// module's IMPL. Enumerated here by name — sema resolves their
    /// imports inside the owning procedure scope.
    pub local_modules: Vec<String>,
    /// `true` when the module is a compiler-provided intrinsic with
    /// no source on disk (currently just SYSTEM).
    pub is_intrinsic: bool,
}

#[derive(Debug, Clone, Default)]
pub struct ModuleGraph {
    pub modules: Vec<ModuleNode>,
    pub by_name: std::collections::HashMap<String, ModuleId>,
    /// Topological order: dependency before dependent. Each `ModuleId`
    /// appears exactly once.
    pub topo_order: Vec<ModuleId>,
}

impl ModuleGraph {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, id: ModuleId) -> &ModuleNode {
        &self.modules[id.0]
    }

    pub fn lookup(&self, name: &str) -> Option<ModuleId> {
        self.by_name.get(name).copied()
    }
}
