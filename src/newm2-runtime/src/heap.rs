//! Manual heap — the classical Modula-2 `Storage` backing.
//!
//! NewM2 treats Modula-2 as a systems-programming language: memory is
//! managed by hand. `NEW` / `Storage.ALLOCATE` map to [`nm2_alloc`] and
//! `DISPOSE` / `Storage.DEALLOCATE` map to [`nm2_free`]. There are no
//! stack maps, safe points, or write barriers — allocation is a direct
//! call into the OS heap manager.
//!
//! On Windows the heap is a private `HeapCreate` heap (itself backed by
//! `VirtualAlloc`); the OS handles page granularity and coalescing. A
//! portable `std::alloc` fallback keeps the crate building on non-Windows
//! CI hosts.
//!
//! Allocations are zero-filled so freshly `NEW`-ed records start clean.

use std::sync::atomic::{AtomicU64, Ordering};

/// Live + lifetime counters for the manual heap. Always maintained;
/// surfaced by `newm2 dump-heap`.
pub struct HeapStats {
    pub alloc_blocks: AtomicU64,
    pub alloc_bytes: AtomicU64,
    pub free_blocks: AtomicU64,
    pub free_bytes: AtomicU64,
    pub live_blocks: AtomicU64,
    pub live_bytes: AtomicU64,
    pub peak_live_bytes: AtomicU64,
}

impl HeapStats {
    const fn new() -> Self {
        HeapStats {
            alloc_blocks: AtomicU64::new(0),
            alloc_bytes: AtomicU64::new(0),
            free_blocks: AtomicU64::new(0),
            free_bytes: AtomicU64::new(0),
            live_blocks: AtomicU64::new(0),
            live_bytes: AtomicU64::new(0),
            peak_live_bytes: AtomicU64::new(0),
        }
    }

    fn record_alloc(&self, bytes: u64) {
        self.alloc_blocks.fetch_add(1, Ordering::Relaxed);
        self.alloc_bytes.fetch_add(bytes, Ordering::Relaxed);
        self.live_blocks.fetch_add(1, Ordering::Relaxed);
        let live = self.live_bytes.fetch_add(bytes, Ordering::Relaxed) + bytes;
        self.peak_live_bytes.fetch_max(live, Ordering::Relaxed);
    }

    fn record_free(&self, bytes: u64) {
        self.free_blocks.fetch_add(1, Ordering::Relaxed);
        self.free_bytes.fetch_add(bytes, Ordering::Relaxed);
        self.live_blocks.fetch_sub(1, Ordering::Relaxed);
        self.live_bytes.fetch_sub(bytes, Ordering::Relaxed);
    }
}

pub static HEAP_STATS: HeapStats = HeapStats::new();

/// Allocate `size` zero-filled bytes. Returns a 16-byte-aligned pointer,
/// or null on failure (out of memory). JIT-callable: `NEW` / `ALLOCATE`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_alloc(size: u64) -> *mut u8 {
    // Never hand back a zero-size block; round up so HeapSize-based
    // accounting and pointer arithmetic stay well-defined.
    let req = size.max(1);
    let ptr = imp::alloc(req);
    if !ptr.is_null() {
        HEAP_STATS.record_alloc(imp::usable_size(ptr));
    }
    ptr
}

/// Free a block previously returned by [`nm2_alloc`]. Null is ignored
/// (harmless double-DISPOSE after the pointer is NILed). JIT-callable.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_free(ptr: *mut u8) {
    if ptr.is_null() {
        return;
    }
    let bytes = imp::usable_size(ptr);
    imp::free(ptr);
    HEAP_STATS.record_free(bytes);
}

// ---------------------------------------------------------------------------
// Windows: private HeapCreate heap (backed by VirtualAlloc).
// ---------------------------------------------------------------------------
#[cfg(windows)]
mod imp {
    use std::ffi::c_void;
    use std::sync::OnceLock;

    const HEAP_ZERO_MEMORY: u32 = 0x0000_0008;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn HeapCreate(options: u32, initial_size: usize, maximum_size: usize) -> *mut c_void;
        fn HeapAlloc(heap: *mut c_void, flags: u32, bytes: usize) -> *mut c_void;
        fn HeapFree(heap: *mut c_void, flags: u32, mem: *const c_void) -> i32;
        fn HeapSize(heap: *mut c_void, flags: u32, mem: *const c_void) -> usize;
    }

    /// Wrapper so the raw `HANDLE` can live in a `OnceLock`.
    struct Heap(*mut c_void);
    // SAFETY: a Win32 heap handle is process-global and the heap is
    // created serialized (thread-safe); sharing the handle is sound.
    unsafe impl Send for Heap {}
    unsafe impl Sync for Heap {}

    static HEAP: OnceLock<Heap> = OnceLock::new();

    fn heap() -> *mut c_void {
        // initial=0, maximum=0 → a growable, serialized private heap.
        HEAP.get_or_init(|| Heap(unsafe { HeapCreate(0, 0, 0) })).0
    }

    pub fn alloc(size: u64) -> *mut u8 {
        let h = heap();
        if h.is_null() {
            return std::ptr::null_mut();
        }
        unsafe { HeapAlloc(h, HEAP_ZERO_MEMORY, size as usize) as *mut u8 }
    }

    pub fn free(ptr: *mut u8) {
        let h = heap();
        if !h.is_null() {
            unsafe {
                HeapFree(h, 0, ptr as *const c_void);
            }
        }
    }

    /// Actual allocated size of a live block (for accurate accounting).
    pub fn usable_size(ptr: *mut u8) -> u64 {
        let h = heap();
        if h.is_null() {
            return 0;
        }
        unsafe { HeapSize(h, 0, ptr as *const c_void) as u64 }
    }
}

// ---------------------------------------------------------------------------
// Non-Windows fallback: std::alloc with a size-prefix header so `free`
// works without the caller passing a size. CI-build hygiene only.
// ---------------------------------------------------------------------------
#[cfg(not(windows))]
mod imp {
    use std::alloc::{Layout, alloc_zeroed, dealloc};

    /// 16-byte header keeps the returned payload 16-byte aligned and
    /// stores the requested size for `free` / `usable_size`.
    const PREFIX: usize = 16;
    const ALIGN: usize = 16;

    fn layout(total: usize) -> Layout {
        Layout::from_size_align(total, ALIGN).unwrap()
    }

    pub fn alloc(size: u64) -> *mut u8 {
        let total = PREFIX + size as usize;
        let base = unsafe { alloc_zeroed(layout(total)) };
        if base.is_null() {
            return std::ptr::null_mut();
        }
        unsafe {
            (base as *mut u64).write(size);
            base.add(PREFIX)
        }
    }

    pub fn free(ptr: *mut u8) {
        unsafe {
            let base = ptr.sub(PREFIX);
            let size = (base as *const u64).read() as usize;
            dealloc(base, layout(PREFIX + size));
        }
    }

    pub fn usable_size(ptr: *mut u8) -> u64 {
        unsafe {
            let base = ptr.sub(PREFIX);
            (base as *const u64).read()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alloc_is_zeroed_and_freeable() {
        let p = nm2_alloc(64);
        assert!(!p.is_null());
        // zero-filled
        for i in 0..64 {
            assert_eq!(unsafe { *p.add(i) }, 0);
        }
        // writable
        unsafe { *p = 0xAB };
        nm2_free(p);
    }

    #[test]
    fn free_null_is_harmless() {
        nm2_free(std::ptr::null_mut());
    }

    #[test]
    fn stats_track_allocation() {
        // HEAP_STATS is process-global and other tests allocate concurrently,
        // so assert on the monotonic lifetime counters (which only ever grow):
        // our alloc/free each contribute at least one, regardless of races.
        let a0 = HEAP_STATS.alloc_blocks.load(Ordering::Relaxed);
        let f0 = HEAP_STATS.free_blocks.load(Ordering::Relaxed);
        let p = nm2_alloc(128);
        assert!(!p.is_null());
        assert!(HEAP_STATS.alloc_blocks.load(Ordering::Relaxed) >= a0 + 1);
        nm2_free(p);
        assert!(HEAP_STATS.free_blocks.load(Ordering::Relaxed) >= f0 + 1);
    }
}
