//! NewM2 IR — typed mid-level IR, CFG, and LLVM lowering.
//!
//! ## Architecture
//!
//! - One terminator per basic block (no fall-through edges).
//! - CFG *is* the IR: no separate flat three-address code.
//! - Instructions: `Call`, `IndCall`, `SetOp`, `Allocate`/`Deallocate`,
//!   `NewProcess`/`Transfer`, and (in GC mode) `GcRoot`/`GcSafePoint`/
//!   `Pin`/`Unpin`.
//!
//! ## Entry points
//!
//! - [`lower::lower_module`] — AST + sema result → [`module::IrModule`]
//! - [`print::format_ir`]  — `newm2 dump-ir`
//! - [`print::format_cfg`] — `newm2 dump-cfg` (RPO ordering)

pub mod block;
pub mod builder;
pub mod func;
pub mod inst;
pub mod lower;
pub mod module;
pub mod print;

pub use inst::{BinOp, BlockId, CastKind, ConstVal, Inst, SetOpKind, Terminator, UnaryOp, ValueId};
pub use func::{Func, IrParam, LoopFrame};
pub use module::{Global, IrModule, MemoryMode};
pub use lower::{lower_module, lower_module_opts};
pub use print::{format_cfg, format_ir};
