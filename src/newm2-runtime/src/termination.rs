//! ISO 10514-1 TERMINATION support.
//!
//! `HasHalted()` is TRUE once `HALT` has been executed; `IsTerminating()` is
//! TRUE once program termination (finalization) has begun. A module finalizer
//! (`FINALLY`) queries these to learn how the program is ending.
//!
//! `HALT` unwinds via [`HaltMarker`] (like an exception) so the JIT entry
//! boundary can catch it, run the module finalizers — which then observe
//! `HasHalted()`/`IsTerminating()` as TRUE — and exit cleanly, rather than the
//! old `llvm.trap` abort that skipped finalization.

use std::panic;
use std::sync::atomic::{AtomicBool, Ordering};

static HALTED: AtomicBool = AtomicBool::new(false);
static TERMINATING: AtomicBool = AtomicBool::new(false);

/// Panic payload that marks a `HALT` (vs. an exception) at the JIT boundary.
/// `code` is the process exit status: bare `HALT` defaults to 1 (abnormal
/// termination); `HALT(n)` carries `n`, so `HALT(0)` is a clean exit.
pub struct HaltMarker {
    pub code: i32,
}

/// `TERMINATION.HasHalted()` — TRUE once `HALT` has run.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_term_has_halted() -> bool {
    HALTED.load(Ordering::SeqCst)
}

/// `TERMINATION.IsTerminating()` — TRUE once finalization has begun.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_term_is_terminating() -> bool {
    TERMINATING.load(Ordering::SeqCst)
}

/// Mark that program termination (finalization) has begun. Called by the JIT
/// runner before it executes module finalizers.
pub fn begin_termination() {
    TERMINATING.store(true, Ordering::SeqCst);
}

/// `HALT(code)` — record the halt, begin termination, and unwind to the entry
/// boundary so finalizers run, carrying the process exit status. Never returns.
/// Bare `HALT` lowers to `nm2_halt(1)`; `HALT(n)` to `nm2_halt(n)`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_halt(code: i64) -> ! {
    HALTED.store(true, Ordering::SeqCst);
    TERMINATING.store(true, Ordering::SeqCst);
    // Silence the default panic hook for this intended unwind.
    crate::exceptions::install_panic_hook();
    panic::panic_any(HaltMarker { code: code as i32 });
}
