//! Basic blocks — the nodes of a function's CFG.

use crate::inst::{BlockId, Inst, Terminator};

#[derive(Debug, Clone)]
pub struct BasicBlock {
    pub id: BlockId,
    /// Optional human-readable label used in dump output (e.g. `"while_cond"`).
    pub label: Option<String>,
    pub insts: Vec<Inst>,
    pub term: Terminator,
}

impl BasicBlock {
    pub fn new(id: BlockId) -> Self {
        Self { id, label: None, insts: Vec::new(), term: Terminator::Unreachable }
    }

    pub fn new_labeled(id: BlockId, label: impl Into<String>) -> Self {
        Self { id, label: Some(label.into()), insts: Vec::new(), term: Terminator::Unreachable }
    }
}
