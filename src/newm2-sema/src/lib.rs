//! NewM2 semantic analysis.
//!
//! Symbol table per scope kind (PROGRAM/IMPLEMENTATION → procedure →
//! LOCAL MODULE → block), type formation, CARDINAL/INTEGER strictness,
//! OPEN ARRAY parameter handling, WITH resolution, RECORD CASE tag
//! tracking, constant folding, ISO EXCEPTION sema, class vtable layout.
//!
//! Entry point: [`check_module_graph`].

pub mod analyze;
pub mod class;
pub mod completion;
pub mod describe;
pub mod heapcheck;
pub mod constant;
pub mod iface;
pub mod iid;
pub mod print;
pub mod scope;
pub mod symcache;
pub mod types;

pub use analyze::{
    Diagnostic, SelectorBinding, Severity, SemaResult, check_module_graph, check_module_graph_cached,
    check_module_graph_cached_strict, check_module_graph_strict,
};
pub use completion::{Completion, complete_at, line_col_to_offset};
pub use describe::describe_at;
pub use heapcheck::analyze_new_dispose;
pub use iface::{ModuleInterface, export_interface};
pub use print::format_module_interface;
pub use symcache::CacheConfig;
pub use class::{ClassArena, ClassSymbol, ClassSymbolId, FieldSlot, MethodSlot, VtableSlot};
pub use constant::{ConstValue, EvalError, eval_const};
pub use print::format_sema;
pub use scope::{
    CallingConv, NamedParam, ProcAttrKind, ProcSig, Scope, ScopeArena, ScopeId, ScopeKind,
    Symbol, SymbolKind,
};
pub use types::{
    Builtin, ParamMode, ProcParam, RecordFieldSlot, RecordLayout, TypeArena, TypeId, TypeKind,
    VariantArmLayout, VariantLabel, VariantLayout,
};
