//! ISO 10514-1 EXCEPTIONS pseudo-module runtime.
//!
//! Layered over Rust's panic/unwind machinery. On `x86_64-pc-windows-msvc`,
//! that machinery is Windows SEH; on other targets it is the platform-native
//! unwinder. Either way, we never construct funclets or personality routines
//! ourselves — we let `panic_any` / `catch_unwind` do it.
//!
//! ## Calling convention
//!
//! Every entry point is `extern "C-unwind"`. Modula-2 EXCEPT/FINALLY frames
//! reach these via the JIT symbol table. M2 procedures themselves must also
//! be `"C-unwind"` so panics can transit them without aborting.
//!
//! ## Payload
//!
//! [`ExceptionPayload`] is the panic value. It carries the ISO triple
//! (source, number, message). When `catch_unwind` returns it, [`nm2_run_protected`]
//! installs it as the thread's CURRENT exception so `IsCurrentSource`,
//! `CurrentNumber`, and `IsExceptionalExecution` can answer the right thing
//! while a handler runs.
//!
//! ## Boundary policy
//!
//! [`nm2_run_protected`] only catches *our* payload type. A panic carrying a
//! different payload (e.g. a Rust `panic!` from runtime code) is re-raised
//! immediately so it cannot be silently swallowed by M2 code.

use std::cell::RefCell;
use std::panic::{self, AssertUnwindSafe};
use std::sync::Once;
use std::sync::atomic::{AtomicU64, Ordering};

// ── Payload ─────────────────────────────────────────────────────────────────

const MESSAGE_CAP: usize = 256;

/// What `panic_any` carries when M2 code raises.
#[derive(Clone)]
pub struct ExceptionPayload {
    pub source: u64,
    pub number: u32,
    pub message: Vec<u8>,
}

// ── Thread-local current exception state ────────────────────────────────────

thread_local! {
    /// CURRENT exception while a handler (or FINALLY during a raise) runs.
    /// `None` outside of exceptional execution.
    static CURRENT: RefCell<Option<ExceptionPayload>> = const { RefCell::new(None) };
}

// ── Source allocator ────────────────────────────────────────────────────────

/// Source ids are a monotonically increasing 64-bit counter. Zero is reserved
/// to mean "no source" so callers can use 0 as a sentinel.
static NEXT_SOURCE: AtomicU64 = AtomicU64::new(1);

// ── Panic-hook suppression ─────────────────────────────────────────────────
//
// Rust's default panic hook prints `thread 'X' panicked at ...` to stderr for
// every panic. M2 `RAISE` is *intended* unwinding, not a bug — printing a
// Rust panic message for each one is user-facing noise. We install a hook
// that chains to the previous hook *only* for foreign payloads; our
// [`ExceptionPayload`] panics are silent.

static INSTALL_HOOK_ONCE: Once = Once::new();

pub(crate) fn install_panic_hook() {
    INSTALL_HOOK_ONCE.call_once(|| {
        let prev = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            // M2 RAISE and HALT are intended unwinding, not bugs — stay silent.
            if info.payload().is::<ExceptionPayload>()
                || info.payload().is::<crate::termination::HaltMarker>()
            {
                return;
            }
            prev(info);
        }));
    });
}

// ── Primitives ──────────────────────────────────────────────────────────────

/// `EXCEPTIONS.AllocateSource` backing.
///
/// Returns a fresh non-zero source id. Sources are process-wide, not
/// thread-local — ISO does not require thread-local sources and giving every
/// thread its own would prevent cross-thread RAISE matching.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_alloc_exception_source() -> u64 {
    NEXT_SOURCE.fetch_add(1, Ordering::Relaxed)
}

/// `EXCEPTIONS.RAISE` backing.
///
/// Never returns; unwinds the stack via Rust panic. The message is read as a
/// NUL-terminated byte string and capped at [`MESSAGE_CAP`] bytes; this
/// matches the calling convention NewM2 codegen uses for `ARRAY OF CHAR`
/// parameters (a single pointer, no length pair).
///
/// # Safety
/// `msg_ptr` must point to a NUL-terminated buffer, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_raise(
    source: u64,
    number: u64,
    msg_ptr: *const u16,
    _msg_high: u64,
) -> ! {
    install_panic_hook();
    // The M2 message is wide (UTF-16, NUL-terminated); store it as UTF-8.
    let message = if msg_ptr.is_null() {
        Vec::new()
    } else {
        let units = unsafe { crate::io::utf16_nul_terminated_slice(msg_ptr) };
        let units = &units[..units.len().min(MESSAGE_CAP)];
        crate::io::render_utf16_units(units).into_bytes()
    };
    // The M2-facing ExceptionNumber is CARDINAL (64-bit); the payload keeps
    // the canonical 32-bit ISO number, truncating an out-of-range value.
    panic::panic_any(ExceptionPayload { source, number: number as u32, message });
}

/// Read up to `cap` bytes from a NUL-terminated buffer at `ptr`. Returns an
/// empty `Vec` if `ptr` is null.
///
/// # Safety
/// `ptr` must be null or point to a NUL-terminated readable buffer.
unsafe fn copy_nul_terminated(ptr: *const u8, cap: usize) -> Vec<u8> {
    if ptr.is_null() {
        return Vec::new();
    }
    let mut len = 0usize;
    while len < cap {
        // SAFETY: caller guarantees a NUL appears within the buffer.
        if unsafe { *ptr.add(len) } == 0 {
            break;
        }
        len += 1;
    }
    unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec()
}

/// Re-raise the thread's CURRENT exception. Used after a FINALLY runs and the
/// outer protected frame still needs to propagate.
///
/// # Safety
/// CURRENT must be `Some(_)`. Codegen must only call this when the protected
/// frame's dispatch logic determined the exception is still in flight.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_reraise() -> ! {
    install_panic_hook();
    let payload = CURRENT.with(|c| c.borrow_mut().take())
        .expect("nm2_reraise called with no CURRENT exception");
    panic::panic_any(payload);
}

/// `EXCEPTIONS.CurrentNumber`. Returns 0 if no exception is current. Widened
/// to 64-bit to match the M2 `CARDINAL` ABI (the payload number is 32-bit).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_current_number() -> u64 {
    CURRENT.with(|c| c.borrow().as_ref().map(|p| p.number as u64).unwrap_or(0))
}

/// Companion to `nm2_current_number`: the source of the current exception, or
/// 0 if no exception is current.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_current_source() -> u64 {
    CURRENT.with(|c| c.borrow().as_ref().map(|p| p.source).unwrap_or(0))
}

/// `EXCEPTIONS.IsCurrentSource(s)` — equivalent to `nm2_current_source() == s`,
/// exposed as its own primitive so the M2 wrapper is a one-liner.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_is_current_source(source: u64) -> bool {
    CURRENT.with(|c| c.borrow().as_ref().is_some_and(|p| p.source == source))
}

/// `EXCEPTIONS.IsExceptionalExecution` — true while a handler or FINALLY runs
/// because of an active exception.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_is_exceptional_execution() -> bool {
    CURRENT.with(|c| c.borrow().is_some())
}

/// `ASSERT` failure: raise a panic with a standard ASSERT source id
/// and the supplied message. Never returns. Codegen calls this in the
/// "condition was false" path of an ASSERT lowering.
///
/// # Safety
/// `msg_ptr` must be null or point to a NUL-terminated readable buffer.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_assert_failed(
    msg_ptr: *const u8,
    _msg_high: u64,
) -> ! {
    install_panic_hook();
    let message = unsafe { copy_nul_terminated(msg_ptr, MESSAGE_CAP) };
    // Use a fixed sentinel source for ASSERT (distinct from any
    // user-allocated source). ISO doesn't pin a specific source
    // identity; we use ASSERT_SOURCE as a stable id so user code
    // can `IsCurrentSource(ASSERT_SOURCE)` if it wants to catch.
    panic::panic_any(ExceptionPayload {
        source: ASSERT_SOURCE,
        number: 0,
        message,
    });
}

/// Reserved exception source for assertion failures.
pub const ASSERT_SOURCE: u64 = u64::MAX;

/// Reserved exception source for ISO `M2EXCEPTION` language exceptions
/// (index/range/CASE-select/... raised by runtime checks). Distinct from
/// `ASSERT_SOURCE` and from user sources (which count up from 1).
pub const M2_SOURCE: u64 = u64::MAX - 1;

/// Reserved exception source for the NewM2 `GUARD` no-match exception. Kept
/// OUT of the closed ISO `M2EXCEPTION.M2Exceptions` enum (raising a 16th ordinal
/// through `nm2_raise_m2` would make `VAL`-ing it back UB) — instead it gets its
/// own sentinel source, exactly mirroring `ASSERT_SOURCE` / `M2_SOURCE`.
pub const GUARD_SOURCE: u64 = u64::MAX - 2;

/// `M2EXCEPTION.M2Exceptions` enumeration ordinals (the ISO order).
pub mod m2exc {
    pub const INDEX: u64 = 0;
    pub const RANGE: u64 = 1;
    pub const CASE_SELECT: u64 = 2;
    pub const INVALID_LOCATION: u64 = 3;
    pub const FUNCTION: u64 = 4;
    pub const WHOLE_VALUE: u64 = 5;
    pub const WHOLE_DIV: u64 = 6;
    pub const REAL_VALUE: u64 = 7;
    pub const REAL_DIV: u64 = 8;
}

/// The fixed source id for ISO language exceptions, so `M2EXCEPTION` can do
/// `IsM2Exception` / `M2Exception` against the current exception.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_m2_source() -> u64 {
    M2_SOURCE
}

/// Raise an ISO language (`M2EXCEPTION`) exception with the fixed `M2_SOURCE`.
/// Codegen calls this for runtime checks (array index, CASE selector, range,
/// division, …). Never returns.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_raise_m2(number: u64) -> ! {
    install_panic_hook();
    let message: Vec<u8> = match number {
        m2exc::INDEX => b"array index out of range".to_vec(),
        m2exc::RANGE => b"value out of range".to_vec(),
        m2exc::CASE_SELECT => b"CASE selector matched no label".to_vec(),
        m2exc::WHOLE_DIV | m2exc::REAL_DIV => b"division by zero".to_vec(),
        _ => b"M2 exception".to_vec(),
    };
    panic::panic_any(ExceptionPayload { source: M2_SOURCE, number: number as u32, message });
}

/// The fixed source id for the GUARD no-match exception, so a NewM2 OO-exception
/// module can do `IsCurrentSource(nm2_guard_source())` to catch it.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_guard_source() -> u64 {
    GUARD_SOURCE
}

/// Raise the GUARD no-match exception: a `GUARD selector AS …` matched no arm and
/// the statement had no `ELSE`. Codegen calls this in the guard default path.
/// Never returns.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_raise_guard() -> ! {
    install_panic_hook();
    panic::panic_any(ExceptionPayload {
        source: GUARD_SOURCE,
        number: 0,
        message: b"GUARD selector matched no arm".to_vec(),
    });
}

/// `M2EXCEPTION.M2Exceptions` ordinal names, in ISO order. Single source of
/// truth shared with the def/mod and the unhandled-exception diagnostic.
pub const M2_EXCEPTION_NAMES: [&str; 15] = [
    "indexException",
    "rangeException",
    "caseSelectException",
    "invalidLocation",
    "functionException",
    "wholeValueException",
    "wholeDivException",
    "realValueException",
    "realDivException",
    "complexValueException",
    "complexDivException",
    "protException",
    "sysException",
    "coException",
    "exException",
];

/// Human-readable name for an exception identity `(source, number)`, used by
/// the JIT boundary's unhandled-exception diagnostic. Recognises the two
/// runtime sentinels (`ASSERT_SOURCE`, `M2_SOURCE`); anything else is a user
/// source and is printed numerically.
pub fn describe_exception(source: u64, number: u32) -> String {
    match source {
        ASSERT_SOURCE => "failed ASSERT".to_string(),
        GUARD_SOURCE => "GUARD selector matched no arm".to_string(),
        M2_SOURCE => match M2_EXCEPTION_NAMES.get(number as usize) {
            Some(name) => format!("M2EXCEPTION.{name}"),
            None => format!("M2EXCEPTION ordinal {number}"),
        },
        _ => format!("source {source} number {number}"),
    }
}

/// Codegen-facing helper: a handler that has run to completion should call
/// this to clear CURRENT, so that an outer protected frame does not see the
/// exception as still in flight.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_exception_handled() {
    CURRENT.with(|c| *c.borrow_mut() = None);
}

/// Codegen-facing helper: copy the CURRENT exception's message into a caller
/// buffer as a NUL-terminated string. Used to back `EXCEPTIONS.GetMessage`
/// where the M2 caller passes an open `ARRAY OF CHAR` (single pointer, no
/// length pair). The runtime caps the write at [`MESSAGE_CAP`] bytes; M2
/// callers are responsible for sizing their buffer accordingly. If no
/// exception is current, writes a single NUL.
///
/// # Safety
/// `buf` must point to at least [`MESSAGE_CAP`] + 1 writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_current_message(buf: *mut u16, high: u64) {
    if buf.is_null() {
        return;
    }
    // `text` is a wide (UTF-16) open `ARRAY OF CHAR`; `high` is its HIGH bound,
    // so it holds high+1 code units. Re-encode the stored UTF-8 message to
    // UTF-16, bounded so the caller's buffer never overflows.
    let cap = high.saturating_add(1) as usize;
    CURRENT.with(|c| {
        let borrow = c.borrow();
        let bytes: &[u8] = borrow.as_ref().map(|p| p.message.as_slice()).unwrap_or(&[]);
        let units: Vec<u16> = String::from_utf8_lossy(bytes).encode_utf16().collect();
        let n = units.len().min(cap.saturating_sub(1));
        unsafe {
            for (i, &u) in units[..n].iter().enumerate() {
                *buf.add(i) = u;
            }
            *buf.add(n) = 0;
        }
    });
}

/// Run `body(state)` under `catch_unwind`. Returns the source id of the
/// raised exception (and installs the payload as CURRENT), or `0` if the
/// body completed normally. Source ids are allocated starting at 1, so
/// `0` is an unambiguous "not raised" sentinel — this keeps the codegen
/// ABI to a single integer return value, which is easier to consume from
/// the IR layer than a multi-field struct.
///
/// - Normal return → returns `0`. CURRENT is unchanged.
/// - Panic carrying an [`ExceptionPayload`] → returns the source id (non-zero),
///   installs the payload as CURRENT. Codegen can subsequently call
///   `nm2_current_number` / `nm2_current_message` to read the rest.
/// - Panic carrying anything else (a Rust `panic!`, an OOM, etc.) → the panic
///   is re-raised unchanged. M2 EXCEPT handlers cannot catch foreign panics.
///
/// # Safety
/// `body` must be a valid `extern "C-unwind"` function pointer; `state` is
/// passed to it opaque. The codegen guarantees that lifetime of anything
/// `state` points into outlives the call.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_run_protected(
    body: unsafe extern "C-unwind" fn(*mut u8),
    state: *mut u8,
) -> u64 {
    let result = panic::catch_unwind(AssertUnwindSafe(|| unsafe { body(state) }));
    match result {
        Ok(()) => 0,
        Err(payload) => match payload.downcast::<ExceptionPayload>() {
            Ok(boxed) => {
                let p = *boxed;
                let source = p.source;
                CURRENT.with(|c| *c.borrow_mut() = Some(p));
                source
            }
            Err(other) => panic::resume_unwind(other),
        },
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // The thread-local CURRENT is per-test-thread; tests that share a thread
    // need to clean up. Cargo runs tests in parallel by default but each test
    // gets its own thread, so explicit cleanup is enough.
    static SOURCE_LOCK: Mutex<()> = Mutex::new(());

    fn fresh_source() -> u64 {
        // Serialize so log assertions about source ids are stable.
        let _g = SOURCE_LOCK.lock().unwrap();
        nm2_alloc_exception_source()
    }

    #[test]
    fn allocate_source_is_non_zero_and_unique() {
        let a = fresh_source();
        let b = fresh_source();
        assert_ne!(a, 0);
        assert_ne!(b, 0);
        assert_ne!(a, b);
    }

    #[test]
    fn protected_normal_return_has_no_raise() {
        unsafe extern "C-unwind" fn ok(_state: *mut u8) {}
        let raised = unsafe { nm2_run_protected(ok, std::ptr::null_mut()) };
        assert_eq!(raised, 0);
        assert!(!nm2_is_exceptional_execution());
    }

    #[test]
    fn protected_catches_our_panic_and_installs_current() {
        let src = fresh_source();

        #[repr(C)]
        struct State {
            src: u64,
            num: u64,
        }
        let state = State { src, num: 42 };

        unsafe extern "C-unwind" fn raise_it(state: *mut u8) {
            let s = unsafe { &*(state as *const State) };
            // Wide (UTF-16) NUL-terminated "boom".
            let msg: [u16; 5] = [b'b' as u16, b'o' as u16, b'o' as u16, b'm' as u16, 0];
            unsafe { nm2_raise(s.src, s.num, msg.as_ptr(), 4) };
        }

        let raised = unsafe {
            nm2_run_protected(raise_it, (&state as *const _ as *mut State) as *mut u8)
        };
        assert_eq!(raised, src);

        // CURRENT is installed.
        assert!(nm2_is_exceptional_execution());
        assert_eq!(nm2_current_source(), src);
        assert_eq!(nm2_current_number(), 42);
        assert!(nm2_is_current_source(src));
        assert!(!nm2_is_current_source(src.wrapping_add(1)));

        // Message round-trips through the wide path.
        let mut buf = [0u16; 16];
        unsafe { nm2_current_message(buf.as_mut_ptr(), 15) };
        let want: [u16; 4] = [b'b' as u16, b'o' as u16, b'o' as u16, b'm' as u16];
        assert_eq!(&buf[..4], &want);
        assert_eq!(buf[4], 0);

        nm2_exception_handled();
        assert!(!nm2_is_exceptional_execution());
        assert_eq!(nm2_current_source(), 0);
        assert_eq!(nm2_current_number(), 0);
    }

    #[test]
    fn protected_reraises_foreign_panic() {
        unsafe extern "C-unwind" fn foreign(_state: *mut u8) {
            panic!("rust panic, not an M2 exception");
        }

        let result = std::panic::catch_unwind(|| unsafe {
            nm2_run_protected(foreign, std::ptr::null_mut())
        });
        assert!(result.is_err(), "foreign panic must propagate past nm2_run_protected");
        // CURRENT must remain clear (foreign payload was not installed).
        assert!(!nm2_is_exceptional_execution());
    }

    #[test]
    fn reraise_propagates_current() {
        let src = fresh_source();

        unsafe extern "C-unwind" fn raise_it(state: *mut u8) {
            let src = unsafe { *(state as *const u64) };
            unsafe { nm2_raise(src, 7, std::ptr::null(), 0) };
        }

        let raised = unsafe {
            nm2_run_protected(raise_it, (&src as *const u64) as *mut u8)
        };
        assert_eq!(raised, src);
        // CURRENT is installed; simulate a handler-less frame that re-raises.
        let result = std::panic::catch_unwind(|| unsafe { nm2_reraise() });
        assert!(result.is_err());
        // After reraise, the panic carried the payload; CURRENT was taken.
        assert!(!nm2_is_exceptional_execution());
    }

    #[test]
    fn message_truncates_at_cap() {
        let src = fresh_source();
        // 1024 wide X's plus a wide NUL.
        let mut big = vec![b'X' as u16; 1024];
        big.push(0);

        unsafe extern "C-unwind" fn raise_big(state: *mut u8) {
            let (src, ptr, high) = unsafe { *(state as *const (u64, *const u16, u64)) };
            unsafe { nm2_raise(src, 0, ptr, high) };
        }
        let args: (u64, *const u16, u64) = (src, big.as_ptr(), big.len() as u64 - 1);
        let raised = unsafe {
            nm2_run_protected(raise_big, &args as *const _ as *mut u8)
        };
        assert_eq!(raised, src);

        // Stored message is capped at MESSAGE_CAP code units (all ASCII 'X',
        // so one UTF-8 byte each).
        let mut buf = [0u16; MESSAGE_CAP + 1];
        unsafe { nm2_current_message(buf.as_mut_ptr(), MESSAGE_CAP as u64) };
        assert_eq!(buf[MESSAGE_CAP], 0);
        assert!(buf[..MESSAGE_CAP].iter().all(|&u| u == b'X' as u16));

        nm2_exception_handled();
    }
}
