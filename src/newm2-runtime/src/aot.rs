//! Ahead-of-time (native `.exe`) program entry orchestration.
//!
//! The JIT path (`newm2-llvm::run_modules`) drives module initialization and
//! finalization from Rust, catching `HALT` / uncaught exceptions at the engine
//! boundary. A statically linked program has no such driver, so the AOT object
//! emits a small table of per-module entry points and a C `main` that calls
//! [`nm2_aot_run`]. This function reproduces the JIT's ordering and termination
//! semantics:
//!
//!  * module *bodies* run in array order — the emitter lays the table out in
//!    dependency (topological) order, so imports initialize before importers
//!    and the program module's `BEGIN … END` runs last;
//!  * each body runs under `catch_unwind`, so a `HALT` (a [`HaltMarker`]
//!    payload) is clean termination and an uncaught exception is a diagnostic;
//!  * once a body has run (or halted), termination begins and every initialized
//!    module's *finalizer* (`FINALLY`) runs in reverse order — ISO LIFO;
//!  * the process exit code is 0 on success, 1 if any body/finalizer raised an
//!    exception that was never handled.

use crate::exceptions::{describe_exception, ExceptionPayload};
use crate::termination::{begin_termination, HaltMarker};

/// One module's entry points, as laid out by the AOT emitter. A null pointer
/// means the module has no such part (e.g. no `FINALLY`). The struct is
/// `#[repr(C)]` with two pointer-sized fields so the emitted `[N x {ptr,ptr}]`
/// table matches exactly.
#[repr(C)]
pub struct AotEntry {
    /// `<module>.body` — the initialization (`BEGIN`) part, or null.
    pub body: Option<extern "C-unwind" fn()>,
    /// `<module>.final` — the `FINALLY` part, or null.
    pub finalizer: Option<extern "C-unwind" fn()>,
}

/// Outcome of running one protected `void` entry point.
enum Outcome {
    /// Returned normally, or the entry was null.
    Ran,
    /// Unwound via `HALT` — run finalizers, then exit with the carried status.
    Halted(i32),
    /// Unwound via an uncaught exception.
    Failed(String),
}

/// Run one optional entry point under `catch_unwind`, mapping a `HALT` or an
/// uncaught M2 exception to an [`Outcome`]. `where_` labels the diagnostic.
fn run_protected(entry: Option<extern "C-unwind" fn()>, where_: &str) -> Outcome {
    let Some(f) = entry else { return Outcome::Ran };
    match std::panic::catch_unwind(|| f()) {
        Ok(()) => Outcome::Ran,
        Err(payload) => {
            if let Some(h) = payload.downcast_ref::<HaltMarker>() {
                return Outcome::Halted(h.code);
            }
            if let Some(exc) = payload.downcast_ref::<ExceptionPayload>() {
                let msg = String::from_utf8_lossy(&exc.message);
                let tail = if msg.is_empty() { String::new() } else { format!(": {msg}") };
                let what = describe_exception(exc.source, exc.number);
                Outcome::Failed(format!("unhandled exception in {where_}: {what}{tail}"))
            } else {
                Outcome::Failed(format!("panic in {where_}"))
            }
        }
    }
}

/// Program entry called by the AOT-emitted C `main`. `entries` points at an
/// array of [`AotEntry`] in topological order; `n` is its length. Returns the
/// process exit code (0 = success, 1 = an unhandled exception).
///
/// # Safety
/// `entries` must point at `n` valid, immutable [`AotEntry`] records for the
/// duration of the call (the emitter places them in a constant global).
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_aot_run(entries: *const AotEntry, n: usize) -> i32 {
    crate::nm2_install_crash_handler();

    let slice = if entries.is_null() || n == 0 {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(entries, n) }
    };

    // Initialize each module body in order. A HALT stops further bodies but the
    // halting module still counts as initialized (its finalizer must run).
    let mut initialized = 0usize;
    let mut first_error: Option<String> = None;
    let mut halt_code: Option<i32> = None;
    for entry in slice {
        match run_protected(entry.body, "module initialization") {
            Outcome::Ran => initialized += 1,
            Outcome::Halted(code) => {
                initialized += 1;
                halt_code = Some(code);
                break;
            }
            Outcome::Failed(e) => {
                first_error = Some(e);
                break;
            }
        }
    }

    // Termination: finalizers run LIFO for every initialized module, whether
    // termination is normal, via HALT, or via an uncaught exception above.
    begin_termination();
    for entry in slice[..initialized].iter().rev() {
        if let Outcome::Failed(e) = run_protected(entry.finalizer, "module finalization") {
            if first_error.is_none() {
                first_error = Some(e);
            }
        }
    }

    match first_error {
        Some(e) => {
            eprintln!("newm2: {e}");
            1
        }
        // HALT: exit with the status it carried (bare HALT defaults to 1).
        None => halt_code.unwrap_or(0),
    }
}
