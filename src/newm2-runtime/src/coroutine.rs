//! Coroutine support via Win32 fibers.
//!
//! Implements the PIM `SYSTEM.NEWPROCESS` / `SYSTEM.TRANSFER` model. Each
//! coroutine is a fiber; the running coroutine is tracked in a thread-local so
//! `TRANSFER(from, to)` can record the suspended coroutine without needing the
//! `GetCurrentFiber` TEB intrinsic.
//!
//! A coroutine that runs to completion would, per Win32, terminate the thread
//! when its fiber function returns; the trampoline instead switches back to the
//! main fiber so falling off the end of a coroutine is survivable.

use core::ffi::c_void;
use std::cell::Cell;
use std::ptr;

// The fiber entry is `extern "system" fn(*mut c_void)`; CreateFiber/SwitchToFiber
// live in kernel32.
unsafe extern "system" {
    fn ConvertThreadToFiber(param: *mut c_void) -> *mut c_void;
    fn CreateFiber(
        stack_size: usize,
        start: extern "system" fn(*mut c_void),
        param: *mut c_void,
    ) -> *mut c_void;
    fn SwitchToFiber(fiber: *mut c_void);
}

thread_local! {
    /// The fiber currently running on this thread (the "current coroutine").
    static CURRENT: Cell<*mut c_void> = const { Cell::new(ptr::null_mut()) };
    /// The thread's original (main) fiber, set on first use.
    static MAIN: Cell<*mut c_void> = const { Cell::new(ptr::null_mut()) };
}

/// The M2 coroutine body: a parameterless procedure.
type CoroutineBody = extern "C-unwind" fn();

/// Ensure the calling thread is a fiber and return its main fiber handle.
/// Idempotent — safe to call before every `NEWPROCESS`.
fn ensure_main_fiber() -> *mut c_void {
    MAIN.with(|m| {
        let mut h = m.get();
        if h.is_null() {
            h = unsafe { ConvertThreadToFiber(ptr::null_mut()) };
            m.set(h);
            CURRENT.with(|c| c.set(h));
        }
        h
    })
}

extern "system" fn fiber_trampoline(param: *mut c_void) {
    // `param` is a boxed coroutine body pointer.
    let body = unsafe { *Box::from_raw(param as *mut CoroutineBody) };
    body();
    // The coroutine returned; hand control back to the main fiber rather than
    // letting the fiber function return (which would end the thread).
    let main = MAIN.with(|m| m.get());
    if !main.is_null() {
        CURRENT.with(|c| c.set(main));
        unsafe { SwitchToFiber(main) };
    }
}

/// `SYSTEM.NEWPROCESS(body, workspace, size, VAR cor)` — create a coroutine
/// that will run `body`. The PIM workspace pointer is ignored (the OS manages
/// the fiber stack); `size` is used as the stack size hint. Returns the fiber
/// handle, which the compiler stores into the `cor` PROCESS variable.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_coroutine_new(body: CoroutineBody, stack_size: usize) -> *mut c_void {
    ensure_main_fiber();
    let boxed = Box::into_raw(Box::new(body)) as *mut c_void;
    let stack = if stack_size == 0 { 64 * 1024 } else { stack_size };
    unsafe { CreateFiber(stack, fiber_trampoline, boxed) }
}

/// `COROUTINES.CURRENT()` — the running coroutine's handle (ISO). Ensures the
/// thread is a fiber first so the main routine has a valid coroutine identity.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_coroutine_current() -> *mut c_void {
    ensure_main_fiber();
    CURRENT.with(|c| c.get())
}

/// `SYSTEM.TRANSFER(VAR from, to)` — suspend the running coroutine, recording
/// its handle in `*from`, and resume `to`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_coroutine_transfer(from: *mut *mut c_void, to: *mut c_void) {
    ensure_main_fiber();
    let current = CURRENT.with(|c| c.get());
    if !from.is_null() {
        unsafe { *from = current };
    }
    if to.is_null() || to == current {
        return;
    }
    CURRENT.with(|c| c.set(to));
    unsafe { SwitchToFiber(to) };
}
