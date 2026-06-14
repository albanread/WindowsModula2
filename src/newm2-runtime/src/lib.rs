//! NewM2 runtime — Storage, ISO channel I/O, strings, math, coroutines,
//! exceptions, the Win32 platform shim, and the copied iGui.
//!
//! Two static-library variants are built:
//! - `newm2_runtime_gc`: tracing GC backs `Storage.ALLOCATE`.
//! - `newm2_runtime_nogc`: classical manual `HeapAlloc` / `HeapFree`.

/// Full GC: cluster allocator, mark-sweep collector, mutator registry,
/// callee-save spill, `nm2_new_rec`, `nm2_init_gc`, all JIT-callable shims.
/// Quarantined behind the opt-in `gc` feature (off by default).
#[cfg(feature = "gc")]
pub mod gc;

/// Manual heap (`HeapAlloc`/`HeapFree`-backed) — the default and only
/// memory model. `nm2_alloc` / `nm2_free` back `NEW` / `DISPOSE`.
pub mod heap;

/// JIT-callable I/O shims (WriteString, WriteInt, WriteLn …) with
/// thread-local capture for testing.
pub mod io;

// Bootstrap runtime primitives backing the ISO library (ported from M2NEW;
// to be partly rewritten in M2 / direct Win32 later). All `NM2.*`-bound,
// no GC/IDE coupling.
/// `COPY` / `LENGTH` string primitives (ISO `Strings`).
pub mod strings;
/// `frexp`/`ldexp`/`modf` (ISO `LowReal`/`RealMath`).
pub mod fmath;
/// Explicit `Storage.ALLOCATE`/`DEALLOCATE` (NEW/DISPOSE bypass this).
pub mod storage;
/// `ProgramArgs` command-line access.
pub mod program_args;
/// Disk-file I/O backing ISO `SeqFile`/`StreamFile`/`RndFile`.
pub mod file;
/// Wall-clock for ISO `SysClock`.
pub mod sysclock;

/// `SYSTEM.SHIFT` / `SYSTEM.ROTATE` bit-pattern helpers.
pub mod bitops;

/// Coroutine support (`SYSTEM.NEWPROCESS` / `SYSTEM.TRANSFER`) via Win32 fibers.
pub mod coroutine;

/// COM interop glue (CoInitialize / CoGetMalloc / GUID equality).
pub mod com;

/// ISO TERMINATION (HasHalted / IsTerminating) + the HALT unwind path.
pub mod termination;

/// Ahead-of-time (`.exe`) program entry orchestration (`nm2_aot_run`).
pub mod aot;

/// Native callback interop (M2 procedure as a C function pointer).
pub mod callback;

/// ISO 10514-1 EXCEPTIONS runtime (RAISE / protected blocks) built on Rust
/// panic/catch_unwind. Runtime foundation; codegen EXCEPT/FINALLY lowering
/// is a separate step.
pub mod exceptions;

/// Signal-safe Windows crash handler producing annotated (M2 + native)
/// backtraces on fatal hardware faults.
pub mod crash;

/// Backward-compat re-exports of the safepoint API (delegates to `gc`).
#[cfg(feature = "gc")]
pub mod safepoint;

/// No-op `SYSTEM.COLLECT` / `SYSTEM.GCREPORT` for the manual-memory build.
#[cfg(not(feature = "gc"))]
mod gc_stubs;

#[cfg(feature = "gc")]
pub use gc::{
    // Allocation
    nm2_init_gc, nm2_new_rec, nm2_sys_new,
    nm2_register_thread, nm2_unregister_thread,
    nm2_collect, nm2_gcreport,
    // Safepoint / cooperative park
    nm2_safepoint, nm2_gc_push_root, nm2_gc_pop_root, nm2_pin, nm2_unpin,
    // Module global-root registration
    nm2_register_module_roots,
    // Pressure-based GC tuning
    nm2_set_gc_pressure, gc_pressure_threshold, alloc_pressure_bytes,
    // Rust-side GC trigger API
    collect, parked_count, release_gc_stop, request_gc_stop,
    collect_log_snapshot, register_typedesc, snapshot,
    // Frozen ABI types (needed by codegen)
    BlockHeader, TypeDesc, ModuleDesc,
    // Introspection types (used by dump-heap)
    ClusterView, CollectRecord, GcState, ModuleView, MutatorView, TypeDescEntry,
    // Live counters (used by dump-heap)
    HEAP_COUNTERS,
};

// Manual-memory build: GC entry points resolve to no-ops.
#[cfg(not(feature = "gc"))]
pub use gc_stubs::{nm2_collect, nm2_gcreport};

pub use heap::{HEAP_STATS, HeapStats, nm2_alloc, nm2_free};

// Bootstrap runtime primitives (NM2.*-bound).
pub use strings::{
    nm2_copy_string, nm2_copy_wstring, nm2_copy_wstring_narrow, nm2_string_length, nm2_wstr_length,
};
pub use fmath::{
    nm2_math_arccos, nm2_math_arccosh, nm2_math_arcsin, nm2_math_arcsinh, nm2_math_arctan,
    nm2_math_arctan2, nm2_math_arctanh, nm2_math_cos, nm2_math_cosh, nm2_math_exp, nm2_math_floor,
    nm2_math_frexp, nm2_math_ldexp, nm2_math_lg, nm2_math_ln, nm2_math_modf, nm2_math_pow,
    nm2_math_sin, nm2_math_sinh, nm2_math_sqrt, nm2_math_tan, nm2_math_tanh, nm2_math_trunc_to_card,
    nm2_math_trunc_to_int,
};
pub use storage::{nm2_storage_allocate, nm2_storage_deallocate};
pub use program_args::{nm2_program_args_copy, nm2_program_args_count, nm2_program_args_set};
pub use file::{
    nm2_file_close, nm2_file_flush, nm2_file_open, nm2_file_read, nm2_file_read_text,
    nm2_file_seek, nm2_file_size, nm2_file_tell, nm2_file_write, nm2_file_write_text,
};
pub use sysclock::nm2_sysclock_now;
pub use bitops::{nm2_rotate, nm2_shift};
pub use coroutine::{nm2_coroutine_current, nm2_coroutine_new, nm2_coroutine_transfer};
pub use com::{nm2_com_drive, nm2_com_get_malloc, nm2_com_init, nm2_com_uninit, nm2_guid_eq};
pub use aot::{AotEntry, nm2_aot_run};
pub use callback::nm2_sort_i64;
pub use termination::{
    HaltMarker, begin_termination, nm2_halt, nm2_term_has_halted, nm2_term_is_terminating,
};
pub use exceptions::{
    ASSERT_SOURCE, ExceptionPayload, describe_exception, nm2_alloc_exception_source, nm2_assert_failed,
    nm2_current_message, nm2_current_number, nm2_current_source, nm2_exception_handled,
    nm2_is_current_source, nm2_is_exceptional_execution, nm2_m2_source, nm2_raise,
    nm2_raise_m2, nm2_reraise, nm2_run_protected,
};

pub use crash::{nm2_finalize_jit_symbols, nm2_install_crash_handler, nm2_register_jit_symbol};

pub use io::{
    // Test-capture API (Rust-side only, not JIT-bound)
    nm2_test_capture_drain, nm2_test_capture_start,
    // JIT-callable I/O shims
    nm2_io_write_char, nm2_io_write_card, nm2_io_write_int,
    nm2_io_write_ln, nm2_io_write_str, nm2_io_write_uchar, nm2_io_write_ucard,
    nm2_io_write_uint, nm2_io_write_ustr,
    // Simulated libc (printf/exit equivalents)
    nm2_libc_printf, nm2_libc_exit,
    // ISO channel device backing (NM2IO.*)
    nm2_io_write_text, nm2_io_write_err_text, nm2_io_write_bytes,
    nm2_io_flush, nm2_io_flush_err,
    nm2_io_peek_char, nm2_io_consume_char, nm2_io_read_text,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryMode {
    Gc,
    NoGc,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_are_distinct() {
        assert_ne!(MemoryMode::Gc, MemoryMode::NoGc);
    }
}
