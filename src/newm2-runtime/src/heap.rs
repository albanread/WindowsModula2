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

use std::sync::atomic::{AtomicU8, AtomicU64, Ordering};

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

// ---------------------------------------------------------------------------
// Heap guard (`--protect-heap` / NM2_PROTECT_HEAP): a COUNTING Bloom filter of
// the live allocation set. `add` on alloc, `check+decrement` on free.
//
// Why counting (not a plain Bloom): double-free needs removal — a freed pointer
// must leave the live set, or every realloc-that-reuses-an-address would false-
// alarm. The invariant count[slot] = #(live pointers hashing to slot) means a
// genuinely-live pointer always reads non-zero, so the guard NEVER blocks a
// correct free (no false positives that break working programs). It can only
// MISS a double-free via hash aliasing — rare, and tunable by filter size.
//
// Why a fixed filter (not a HashMap): no per-allocation growth, and it never
// recurses into the heap it guards. Leaks come from the exact live counters.
// ---------------------------------------------------------------------------

const BLOOM_LEN: usize = 1 << 22; // 4,194,304 counters; k=4 hashes
const BLOOM_MASK: u64 = (BLOOM_LEN as u64) - 1;
const BLOOM_K: usize = 4;

// A STATIC counting Bloom filter — no allocation, so it works in an AOT Modula-2
// exe that never ran Rust's lang_start (the global allocator may be unavailable).
// 4 MiB of zero-filled BSS, only touched when the guard is on -> an off-guard
// program commits ~nothing and pays one relaxed load on the alloc/free path.
const ZERO_CTR: AtomicU8 = AtomicU8::new(0);
static BLOOM: [AtomicU8; BLOOM_LEN] = [ZERO_CTR; BLOOM_LEN];
static DOUBLE_FREE: AtomicU64 = AtomicU64::new(0);
// 0 = undecided, 1 = on, 2 = off, 3 = deciding (claimed)
static GUARD_STATE: AtomicU8 = AtomicU8::new(0);

unsafe extern "C" {
    fn atexit(cb: extern "C" fn()) -> i32;
}

/// Is NM2_PROTECT_HEAP set (and not "0")? Read via the Win32 API directly — an AOT
/// Modula-2 exe never runs Rust's lang_start, so `std::env` doesn't see the
/// environment there; GetEnvironmentVariableW does, and works in the JIT too.
#[cfg(windows)]
fn guard_on_env() -> bool {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetEnvironmentVariableW(name: *const u16, buf: *mut u16, size: u32) -> u32;
    }
    let src = b"NM2_PROTECT_HEAP";
    let mut name = [0u16; 17];
    let mut i = 0;
    while i < src.len() {
        name[i] = src[i] as u16;
        i += 1;
    }
    let mut val = [0u16; 8];
    let n = unsafe { GetEnvironmentVariableW(name.as_ptr(), val.as_mut_ptr(), 8) };
    if n == 0 {
        return false; // not set
    }
    !(n == 1 && val[0] == b'0' as u16) // set, and not exactly "0"
}

#[cfg(not(windows))]
fn guard_on_env() -> bool {
    std::env::var_os("NM2_PROTECT_HEAP").map(|v| !v.is_empty() && v != "0").unwrap_or(false)
}

/// Whether the heap guard is active — env-gated, decided once (atomics only, so no
/// dependency on Rust runtime init). Registers the at-exit leak report on enable.
fn guard_on() -> bool {
    loop {
        match GUARD_STATE.load(Ordering::Acquire) {
            1 => return true,
            2 => return false,
            0 => {
                if GUARD_STATE.compare_exchange(0, 3, Ordering::AcqRel, Ordering::Acquire).is_ok() {
                    let on = guard_on_env();
                    if on {
                        unsafe { atexit(guard_report_atexit) };
                    }
                    GUARD_STATE.store(if on { 1 } else { 2 }, Ordering::Release);
                    return on;
                }
            }
            _ => core::hint::spin_loop(), // another thread is deciding
        }
    }
}

/// k slot indices for a pointer via double-hashing (Kirsch–Mitzenmacher).
/// The low 4 bits are dropped (16-byte alignment).
fn bloom_indices(ptr: *mut u8) -> [usize; BLOOM_K] {
    let h = (ptr as u64) >> 4;
    let mut h1 = h.wrapping_mul(0xff51afd7ed558ccd);
    h1 ^= h1 >> 33;
    let mut h2 = h.wrapping_mul(0xc4ceb9fe1a85ec53);
    h2 ^= h2 >> 29;
    h2 |= 1; // odd step => visits distinct slots
    let mut out = [0usize; BLOOM_K];
    let mut i = 0;
    while i < BLOOM_K {
        out[i] = (h1.wrapping_add((i as u64).wrapping_mul(h2)) & BLOOM_MASK) as usize;
        i += 1;
    }
    out
}

fn bloom_add(ptr: *mut u8) {
    for idx in bloom_indices(ptr) {
        let c = &BLOOM[idx];
        loop {
            let v = c.load(Ordering::Relaxed);
            if v == 255 {
                break; // saturated: leave it (conservative; never under-counts a live ptr)
            }
            if c.compare_exchange_weak(v, v + 1, Ordering::Relaxed, Ordering::Relaxed).is_ok() {
                break;
            }
        }
    }
}

/// TRUE if the pointer was (probably) live and is now removed; FALSE means a slot
/// read zero => definitely never live here => double/invalid free.
fn bloom_remove(ptr: *mut u8) -> bool {
    let idx = bloom_indices(ptr);
    for &i in &idx {
        if BLOOM[i].load(Ordering::Relaxed) == 0 {
            return false;
        }
    }
    for &i in &idx {
        let c = &BLOOM[i];
        loop {
            let v = c.load(Ordering::Relaxed);
            if v == 0 || v == 255 {
                break; // underflow guard / saturated slot stays put
            }
            if c.compare_exchange_weak(v, v - 1, Ordering::Relaxed, Ordering::Relaxed).is_ok() {
                break;
            }
        }
    }
    true
}

/// Write to stderr via the Win32 API — `std::io::stderr()` may be uninitialized in
/// an AOT Modula-2 exe (no lang_start), but the stderr HANDLE is always valid.
#[cfg(windows)]
fn werr(s: &[u8]) {
    use std::ffi::c_void;
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetStdHandle(which: u32) -> *mut c_void;
        fn WriteFile(h: *mut c_void, buf: *const u8, n: u32, written: *mut u32, ovl: *mut c_void) -> i32;
    }
    const STD_ERROR_HANDLE: u32 = 0xFFFF_FFF4; // (DWORD)-12
    let h = unsafe { GetStdHandle(STD_ERROR_HANDLE) };
    if h.is_null() || h as isize == -1 {
        return;
    }
    let mut written = 0u32;
    unsafe { WriteFile(h, s.as_ptr(), s.len() as u32, &mut written, std::ptr::null_mut()) };
}
#[cfg(not(windows))]
fn werr(s: &[u8]) {
    use std::io::Write;
    let _ = std::io::stderr().write_all(s);
}

fn put_str(buf: &mut [u8], mut p: usize, s: &[u8]) -> usize {
    for &b in s {
        if p < buf.len() {
            buf[p] = b;
            p += 1;
        }
    }
    p
}
fn put_u64(buf: &mut [u8], mut p: usize, mut n: u64) -> usize {
    let mut tmp = [0u8; 20];
    let mut t = 0;
    if n == 0 {
        tmp[0] = b'0';
        t = 1;
    } else {
        while n > 0 {
            tmp[t] = b'0' + (n % 10) as u8;
            t += 1;
            n /= 10;
        }
    }
    while t > 0 {
        t -= 1;
        if p < buf.len() {
            buf[p] = tmp[t];
            p += 1;
        }
    }
    p
}

extern "C" fn guard_report_atexit() {
    let df = DOUBLE_FREE.load(Ordering::Relaxed);
    let blocks = HEAP_STATS.live_blocks.load(Ordering::Relaxed);
    let bytes = HEAP_STATS.live_bytes.load(Ordering::Relaxed);
    let mut buf = [0u8; 160];
    let mut p = put_str(&mut buf, 0, b"nm2-heap-guard: ");
    p = put_u64(&mut buf, p, df);
    p = put_str(&mut buf, p, b" double/invalid free(s) caught; ");
    if blocks > 0 {
        p = put_str(&mut buf, p, b"LEAK ");
        p = put_u64(&mut buf, p, blocks);
        p = put_str(&mut buf, p, b" block(s), ");
        p = put_u64(&mut buf, p, bytes);
        p = put_str(&mut buf, p, b" byte(s) live at exit\n");
    } else {
        p = put_str(&mut buf, p, b"no leaks (all blocks freed)\n");
    }
    werr(&buf[..p]);
}

/// Force the heap guard on regardless of NM2_PROTECT_HEAP. Codegen emits a call to
/// this at program entry when built with `--protect-heap`, so the exe self-guards
/// without needing the env var. Idempotent; registers the at-exit leak report once.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_heap_guard_force_on() {
    let prev = GUARD_STATE.swap(1, Ordering::AcqRel);
    if prev != 1 {
        unsafe { atexit(guard_report_atexit) };
    }
}

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
        if guard_on() {
            bloom_add(ptr);
        }
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
    if guard_on() && !bloom_remove(ptr) {
        // double or invalid free: report and PREVENT it (don't corrupt the heap)
        DOUBLE_FREE.fetch_add(1, Ordering::Relaxed);
        werr(b"nm2-heap-guard: double or invalid free caught (skipped)\n");
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
