//! IR module — top-level container for functions and globals.

use new_asm;
use crate::func::{Func, IrParam};
use newm2_sema::{ConstValue, TypeId};

/// Memory management mode for a compilation unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryMode {
    /// GC-backed allocation (default — statepoints in codegen).
    Gc,
    /// Manual allocation (--no-gc — no GC instructions emitted).
    NoGc,
}

/// A module-level global declaration.
#[derive(Debug, Clone)]
pub enum Global {
    /// External function imported from another module or Win32.
    ExternFunc {
        name: String,
        import_name: Option<String>,
        dll_name: Option<String>,
        params: Option<Vec<IrParam>>,
        return_ty: Option<TypeId>,
        /// C-style variadic (`printf(...)`): the LLVM function type is declared
        /// `isVarArg` so call sites may pass extra arguments.
        is_variadic: bool,
    },
    /// Module-level static variable.
    Static { name: String, ty: TypeId, init: Option<ConstValue>, exported: bool },
    /// Interned string literal.
    StringConst { name: String, value: String },
    /// Class vtable descriptor.
    ///
    /// Emitted as a zero-initialised mutable `[vtable_slots.len() x ptr]`
    /// LLVM global named `{class_name}.vtable`.  Function pointers are
    /// written in post-JIT by `lib.rs` using `LLVMGetPointerToGlobal` on
    /// each `FunctionValue` (bypasses MCJIT's dyld name-table entirely, which
    /// avoids the well-known constant-initialiser relocation bug).
    ///
    /// `vtable_slots[i]` is the LLVM function name for the i-th vtable slot
    /// (formed as `{DefiningClassName}.{MethodName}` by the IR lowering pass).
    /// An empty string means the slot is abstract (no implementation body).
    ClassDesc {
        class_name: String,
        vtable_slots: Vec<String>,
        /// When true, physical slot 0 of the emitted `{class}.vtable` holds the
        /// `{class}.typeinfo` pointer (RTTI) and the methods named by
        /// `vtable_slots` therefore start at physical slot 1. Native classes set
        /// this; the post-JIT patcher and dispatch lowering add the matching +1.
        has_typeinfo: bool,
    },
    /// Per-class RTTI descriptor, emitted as a constant global
    /// `{class_name}.typeinfo` = `{ parent: ptr, name: ptr, depth: i64 }`
    /// (matching `newm2_runtime::rtti::TypeInfo`).
    ///
    /// Emitted for **every native class — concrete AND abstract** (so an
    /// abstract base is a valid `ISMEMBER`/`GUARD` target and derived classes
    /// can chain to it); COM interfaces get none. `parent_name`, when present,
    /// is the base class's name — its `{base}.typeinfo` is referenced by symbol
    /// and resolved by the linker (AOT) / JIT. `depth` is 0 at a root.
    TypeInfo {
        class_name: String,
        parent_name: Option<String>,
        depth: u64,
    },
}

/// The IR for a single compiled module.
#[derive(Debug)]
pub struct IrModule {
    pub name: String,
    pub globals: Vec<Global>,
    pub funcs: Vec<Func>,
    pub memory_mode: MemoryMode,
    /// x86-64 ASM procedure definitions (emitted as LLVM `module asm`).
    pub asm_procs: Vec<new_asm::AsmProc>,
}

impl IrModule {
    pub fn new(name: impl Into<String>, memory_mode: MemoryMode) -> Self {
        Self {
            name: name.into(),
            globals: Vec::new(),
            funcs: Vec::new(),
            memory_mode,
            asm_procs: Vec::new(),
        }
    }

    pub fn is_asm_proc(&self, name: &str) -> bool {
        self.asm_procs.iter().any(|p| p.name == name)
    }
}
