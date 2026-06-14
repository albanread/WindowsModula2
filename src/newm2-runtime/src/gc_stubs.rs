//! No-op GC entry points for the default (manual-memory) build.
//!
//! When the `gc` feature is disabled the tracing collector is not
//! compiled in, but `SYSTEM.COLLECT` / `SYSTEM.GCREPORT` may still appear
//! in source. These stubs let such programs link and run — they simply do
//! nothing, which is the correct semantics under manual memory.

/// `SYSTEM.COLLECT` — no-op without the collector.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_collect() {}

/// `SYSTEM.GCREPORT` — no-op without the collector.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_gcreport() {}
