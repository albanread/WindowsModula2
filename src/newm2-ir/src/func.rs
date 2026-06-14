//! Functions (CFGs) and loop context frames.

use crate::block::BasicBlock;
use crate::inst::BlockId;
use crate::module::MemoryMode;
use newm2_sema::types::TypeId;

/// One entry on the loop stack, tracking where EXIT and continue go.
#[derive(Debug, Clone)]
pub struct LoopFrame {
    /// Target for an `EXIT` statement.
    pub exit_block: BlockId,
    /// Target for the loop back-edge (header for WHILE/FOR, body for REPEAT).
    pub continue_block: BlockId,
}

/// A named parameter of an IR function.
#[derive(Debug, Clone)]
pub struct IrParam {
    pub name: String,
    pub ty: TypeId,
    /// `true` for `VAR` parameters (caller passes an address).
    pub is_var: bool,
}

/// An IR function — a complete CFG.
#[derive(Debug, Clone)]
pub struct Func {
    pub name: String,
    pub params: Vec<IrParam>,
    pub return_ty: Option<TypeId>,
    /// All basic blocks in construction order; blocks[0] is always `entry`.
    pub blocks: Vec<BasicBlock>,
    /// Entry block (always `BlockId(0)`).
    pub entry: BlockId,
    /// Dedicated exit block (NewCP convention) — all normalised returns
    /// target this block; it carries the sole `Return` terminator.
    pub exit: BlockId,
    pub memory_mode: MemoryMode,
    /// `true` for extern-only declarations with no body.
    pub is_extern: bool,
}

impl Func {
    pub fn get_block(&self, id: BlockId) -> &BasicBlock {
        &self.blocks[id.0 as usize]
    }

    pub fn get_block_mut(&mut self, id: BlockId) -> &mut BasicBlock {
        &mut self.blocks[id.0 as usize]
    }

    /// Reverse post-order traversal from the entry block.
    ///
    /// RPO gives a stable linear ordering that respects dominance: every
    /// block appears before its successors (modulo back-edges).  Used by
    /// `dump-cfg` to display CFGs in a readable order.
    pub fn rpo(&self) -> Vec<BlockId> {
        let n = self.blocks.len();
        let mut visited = vec![false; n];
        let mut order = Vec::with_capacity(n);
        self.rpo_dfs(self.entry, &mut visited, &mut order);
        order.reverse();
        order
    }

    fn rpo_dfs(&self, b: BlockId, visited: &mut Vec<bool>, order: &mut Vec<BlockId>) {
        let idx = b.0 as usize;
        if visited[idx] {
            return;
        }
        visited[idx] = true;
        // Avoid panicking on unreachable/out-of-range blocks.
        if idx < self.blocks.len() {
            for s in self.blocks[idx].term.succs() {
                self.rpo_dfs(s, visited, order);
            }
        }
        order.push(b);
    }

    /// All blocks reachable from entry in construction order (for dump-ir).
    pub fn construction_order(&self) -> impl Iterator<Item = &BasicBlock> {
        self.blocks.iter()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::block::BasicBlock;
    use crate::inst::Terminator;
    use crate::module::MemoryMode;

    fn make_func_two_blocks() -> Func {
        let entry = BlockId(0);
        let exit = BlockId(1);
        let mut b0 = BasicBlock::new_labeled(entry, "entry");
        b0.term = Terminator::Goto(exit);
        let mut b1 = BasicBlock::new_labeled(exit, "exit");
        b1.term = Terminator::Return(None);
        Func {
            name: "test".into(),
            params: vec![],
            return_ty: None,
            blocks: vec![b0, b1],
            entry,
            exit,
            memory_mode: MemoryMode::NoGc,
            is_extern: false,
        }
    }

    #[test]
    fn rpo_two_block_func() {
        let f = make_func_two_blocks();
        let rpo = f.rpo();
        // Entry should come before exit in RPO.
        assert_eq!(rpo, vec![BlockId(0), BlockId(1)]);
    }

    #[test]
    fn construction_order_yields_all_blocks() {
        let f = make_func_two_blocks();
        assert_eq!(f.construction_order().count(), 2);
    }
}
