//! Cooperative GC safepoint — re-exported from [`crate::gc`].
//!
//! The full implementation (cluster allocator, mark-sweep collector,
//! mutator registry, callee-save spill) lives in `gc.rs`.  This module
//! exists for backward-compatibility with import paths that reference
//! `safepoint::nm2_safepoint` etc.

pub use crate::gc::{
    nm2_gc_pop_root, nm2_gc_push_root, nm2_pin, nm2_safepoint, nm2_unpin,
    parked_count, release_gc_stop, request_gc_stop,
};

// Re-export the safepoint flag so existing tests that reference
// `COORD.stop_requested` can be updated to use the new name.
pub use crate::gc::SAFEPOINT_REQUESTED;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safepoint_noop_when_no_gc_requested() {
        // Fast path: if SAFEPOINT_REQUESTED is 0, nm2_safepoint() returns
        // immediately without parking.  This test checks it does not hang.
        // (parked_count() is not asserted here — parallel test threads may
        // temporarily set/clear the flag.)
        release_gc_stop(); // ensure flag is clear before polling
        nm2_safepoint();
    }

    #[test]
    fn request_release_roundtrip() {
        use std::sync::atomic::Ordering;
        request_gc_stop();
        assert_ne!(SAFEPOINT_REQUESTED.load(Ordering::Relaxed), 0);
        release_gc_stop();
        assert_eq!(SAFEPOINT_REQUESTED.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn push_pop_root_noop() {
        let mut slot: *mut u8 = std::ptr::null_mut();
        nm2_gc_push_root(&mut slot as *mut *mut u8);
        nm2_gc_pop_root();
    }

    #[test]
    fn pin_unpin_noop() {
        nm2_pin(std::ptr::null_mut());
        nm2_unpin(std::ptr::null_mut());
    }
}
