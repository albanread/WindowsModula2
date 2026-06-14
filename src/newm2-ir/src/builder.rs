//! `FuncBuilder` — imperative API for constructing a function's CFG.
//!
//! ## Workflow
//!
//! ```text
//! let mut b = FuncBuilder::new("my_proc", params, return_ty, mode);
//! let header = b.new_block("while_cond");
//! let body   = b.new_block("while_body");
//! let exit   = b.new_block("while_exit");
//!
//! b.terminate(Terminator::Goto(header));   // seal entry
//! b.switch_to(header);
//! let cond = b.fresh_reg();
//! b.push(Inst::Const { dst: cond, val: ConstVal::Bool(true) });
//! b.terminate(Terminator::CondBr { cond, t_block: body, f_block: exit });
//! // … etc.
//! let func = b.finish();
//! ```

use crate::block::BasicBlock;
use crate::func::{Func, IrParam, LoopFrame};
use crate::inst::{BlockId, Inst, Terminator, ValueId};
use crate::module::MemoryMode;
use newm2_sema::types::TypeId;

pub struct FuncBuilder {
    name: String,
    params: Vec<IrParam>,
    return_ty: Option<TypeId>,
    blocks: Vec<BasicBlock>,
    current: BlockId,
    next_reg: u32,
    loop_stack: Vec<LoopFrame>,
    memory_mode: MemoryMode,
    entry: BlockId,
    exit: BlockId,
}

impl FuncBuilder {
    /// Create a new builder.  Two blocks are pre-allocated: `entry` (B0)
    /// and `exit` (B1).  The active block starts at `entry`.
    pub fn new(
        name: impl Into<String>,
        params: Vec<IrParam>,
        return_ty: Option<TypeId>,
        memory_mode: MemoryMode,
    ) -> Self {
        let entry_id = BlockId(0);
        let exit_id = BlockId(1);
        Self {
            name: name.into(),
            params,
            return_ty,
            blocks: vec![
                BasicBlock::new_labeled(entry_id, "entry"),
                BasicBlock::new_labeled(exit_id, "exit"),
            ],
            current: entry_id,
            next_reg: 0,
            loop_stack: Vec::new(),
            memory_mode,
            entry: entry_id,
            exit: exit_id,
        }
    }

    /// The function's declared result type (`None` for a proper procedure).
    pub fn return_ty(&self) -> Option<TypeId> {
        self.return_ty
    }

    /// Allocate a fresh virtual register.
    pub fn fresh_reg(&mut self) -> ValueId {
        let id = ValueId(self.next_reg);
        self.next_reg += 1;
        id
    }

    /// Allocate a new basic block (labelled, not yet the active block).
    pub fn new_block(&mut self, label: impl Into<String>) -> BlockId {
        let id = BlockId(self.blocks.len() as u32);
        self.blocks.push(BasicBlock::new_labeled(id, label));
        id
    }

    /// Make `id` the active block.
    pub fn switch_to(&mut self, id: BlockId) {
        self.current = id;
    }

    pub fn current_block(&self) -> BlockId {
        self.current
    }

    pub fn entry_block(&self) -> BlockId {
        self.entry
    }

    pub fn exit_block(&self) -> BlockId {
        self.exit
    }

    pub fn memory_mode(&self) -> MemoryMode {
        self.memory_mode
    }

    /// Returns `true` if the current block already has a terminator.
    pub fn is_terminated(&self) -> bool {
        !matches!(self.blocks[self.current.0 as usize].term, Terminator::Unreachable)
    }

    /// Append an instruction to the active block.
    /// Silently drops the instruction if the block is already terminated
    /// (dead code after EXIT / RETURN — not an error).
    pub fn push(&mut self, inst: Inst) {
        if self.is_terminated() {
            return;
        }
        self.blocks[self.current.0 as usize].insts.push(inst);
    }

    /// Terminate the active block.  Idempotent — the first terminator wins;
    /// subsequent calls are silently ignored (handles unreachable paths).
    pub fn terminate(&mut self, term: Terminator) {
        if self.is_terminated() {
            return;
        }
        self.blocks[self.current.0 as usize].term = term;
    }

    // ---- Loop stack -------------------------------------------------------

    pub fn push_loop(&mut self, frame: LoopFrame) {
        self.loop_stack.push(frame);
    }

    pub fn pop_loop(&mut self) -> Option<LoopFrame> {
        self.loop_stack.pop()
    }

    pub fn current_loop(&self) -> Option<&LoopFrame> {
        self.loop_stack.last()
    }

    // ---- Finalise ---------------------------------------------------------

    /// Consume the builder and produce the finished `Func`.
    ///
    /// Unsealed blocks (those still holding `Terminator::Unreachable`) are
    /// patched to a well-typed terminator to keep the CFG well-formed.
    pub fn finish(mut self) -> Func {
        for block in &mut self.blocks {
            if matches!(block.term, Terminator::Unreachable) {
                block.term = if self.return_ty.is_some() {
                    Terminator::Unreachable
                } else {
                    Terminator::Return(None)
                };
            }
        }
        Func {
            name: self.name,
            params: self.params,
            return_ty: self.return_ty,
            blocks: self.blocks,
            entry: self.entry,
            exit: self.exit,
            memory_mode: self.memory_mode,
            is_extern: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inst::{ConstVal, Inst};

    #[test]
    fn fresh_builder_has_entry_and_exit() {
        let b = FuncBuilder::new("f", vec![], None, MemoryMode::NoGc);
        let f = b.finish();
        assert_eq!(f.blocks.len(), 2);
        assert_eq!(f.entry, BlockId(0));
        assert_eq!(f.exit, BlockId(1));
    }

    #[test]
    fn new_block_increments_id() {
        let mut b = FuncBuilder::new("f", vec![], None, MemoryMode::NoGc);
        let id = b.new_block("extra");
        assert_eq!(id.0, 2);
    }

    #[test]
    fn push_appends_to_active_block() {
        let mut b = FuncBuilder::new("f", vec![], None, MemoryMode::NoGc);
        let r = b.fresh_reg();
        b.push(Inst::Const { dst: r, val: ConstVal::Int(42) });
        let f = b.finish();
        assert_eq!(f.blocks[0].insts.len(), 1);
    }

    #[test]
    fn push_after_terminate_is_dropped() {
        let mut b = FuncBuilder::new("f", vec![], None, MemoryMode::NoGc);
        let exit = b.exit_block();
        b.terminate(Terminator::Goto(exit));
        let r = b.fresh_reg();
        b.push(Inst::Const { dst: r, val: ConstVal::Int(1) });
        let f = b.finish();
        assert_eq!(f.blocks[0].insts.len(), 0);
    }

    #[test]
    fn finish_patches_unreachable_blocks() {
        let mut b = FuncBuilder::new("f", vec![], None, MemoryMode::NoGc);
        let extra = b.new_block("orphan");
        let exit = b.exit_block();
        b.terminate(Terminator::Goto(exit));
        let f = b.finish();
        // Both exit and orphan should have non-Unreachable terminators.
        assert!(!matches!(f.blocks[extra.0 as usize].term, Terminator::Unreachable));
        assert!(!matches!(f.blocks[exit.0 as usize].term, Terminator::Unreachable));
    }
}
