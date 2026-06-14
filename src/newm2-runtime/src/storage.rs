//! Runtime shims backing the ISO `Storage` module
//! (`Storage.ALLOCATE` / `Storage.DEALLOCATE`).
//!
//! NewM2's `NEW(p)` / `DISPOSE(p)` builtins lower directly to
//! `Inst::Allocate` / `Inst::Deallocate` in the IR and bypass these
//! shims entirely — they're only here for ISO 10514-1-compliant
//! programs that invoke `Storage.ALLOCATE(addr, size)` explicitly,
//! which is rare but allowed.
//!
//! Bound by name in `bind_runtime_helpers`:
//!   `NM2.Storage.Allocate`   → `nm2_storage_allocate`
//!   `NM2.Storage.Deallocate` → `nm2_storage_deallocate`
//!
//! These do NOT participate in the tracing GC. Memory returned by
//! `nm2_storage_allocate` is owned by the caller and must be released
//! with a matching `nm2_storage_deallocate` (passing the same size,
//! per `std::alloc::Layout` semantics).

use std::alloc::Layout;

/// 16-byte alignment — matches the GC block alignment so a pointer from
/// `Storage.ALLOCATE` can be aliased onto a typed Modula-2 record without
/// alignment surprises.
const STORAGE_ALIGN: usize = 16;

/// Allocate `n` bytes via the system allocator and store the resulting
/// pointer into `*addr_slot`. A zero-byte request yields a null pointer
/// (consistent with the ISO note that "the value passed back may have
/// any value, in particular NIL"). Allocation failure aborts the
/// process via `handle_alloc_error` — there is no Modula-2-level
/// exception path here yet.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_storage_allocate(
    addr_slot: *mut *mut u8,
    n: usize,
) {
    if addr_slot.is_null() {
        return;
    }
    if n == 0 {
        unsafe { *addr_slot = std::ptr::null_mut() };
        return;
    }
    let layout = Layout::from_size_align(n, STORAGE_ALIGN)
        .expect("nm2_storage_allocate: invalid layout");
    let ptr = unsafe { std::alloc::alloc(layout) };
    if ptr.is_null() {
        std::alloc::handle_alloc_error(layout);
    }
    unsafe { *addr_slot = ptr };
}

/// Free the buffer at `*addr_slot` and clear the slot. `n` must match
/// the original allocation size (Rust `std::alloc::Layout` requires it).
/// A null pointer is a no-op — ISO leaves the behaviour implementation-
/// defined and we choose "silently succeed".
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_storage_deallocate(
    addr_slot: *mut *mut u8,
    n: usize,
) {
    if addr_slot.is_null() {
        return;
    }
    let ptr = unsafe { *addr_slot };
    if ptr.is_null() || n == 0 {
        unsafe { *addr_slot = std::ptr::null_mut() };
        return;
    }
    let layout = Layout::from_size_align(n, STORAGE_ALIGN)
        .expect("nm2_storage_deallocate: invalid layout");
    unsafe { std::alloc::dealloc(ptr, layout) };
    unsafe { *addr_slot = std::ptr::null_mut() };
}
