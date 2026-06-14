//! NewM2 garbage collector — conservative mark-and-sweep over a cluster heap.
//!
//! Ported from NewCP's `gc.rs` (v2).  The on-wire data layout
//! (`BlockHeader`, `TypeDesc`, `ModuleDesc`) is **frozen** — JIT codegen
//! depends on these byte offsets.
//!
//! ## Architecture
//!
//! - **Clusters**: 1 MiB OS allocations subdivided into 16-byte-aligned
//!   blocks.  Each block has a 16-byte `BlockHeader` prefix followed by
//!   the zero-initialised payload.  Allocation tries every existing cluster
//!   (free-list first-fit, then bump), collects when all are full, grows
//!   if collection didn't free enough.
//!
//! - **Mark phase**: conservative scan of every parked mutator's stack
//!   `[parked_rsp, stack_top)` plus callee-saved register spill.  For each
//!   word that decodes as a live managed payload pointer, mark the block and
//!   trace its `TypeDesc.ptroffs`.
//!
//! - **Sweep phase**: linear walk of every cluster; dead blocks go on the
//!   free list; adjacent free blocks are coalesced.  Finalizers are queued
//!   and run after the safepoint window is closed.
//!
//! - **Safepoint**: `nm2_safepoint()` polls `SAFEPOINT_REQUESTED`.  When
//!   set, the calling mutator spills callee-saves, records its RSP, and
//!   parks on `SAFEPOINT_CONDVAR` until the collector clears the flag.
//!
//! All JIT-callable entry points use `extern "C-unwind"` so that Rust
//! panics can propagate back through JIT frames and be caught by
//! `std::panic::catch_unwind` in `newm2-llvm::run_module`.

use std::alloc::Layout;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU8, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, RwLock};
use std::thread::ThreadId;
use std::time::{Duration, Instant};

use crate::io::runtime_write_str;

// ─────────────────────────────────────────────────────────────────────────────
// On-wire layout — frozen; JIT codegen depends on these byte offsets.
// ─────────────────────────────────────────────────────────────────────────────

/// Header prefixed to every block in a cluster (allocated *or* free).
///
/// 16 bytes, 16-aligned.  JIT-emitted code locates the header by
/// subtracting `size_of::<BlockHeader>()` (= 16) from the payload pointer
/// it holds.
///
/// `tag` packs the `TypeDesc` address with a single mark-bit in the LSB.
/// A tag whose value (mark-bit cleared) is 0 denotes a **free** block; the
/// payload then begins with a `FreeBlockLink`.
///
/// `block_size` is the total size of this block in bytes, including this
/// header.  Required to walk the cluster linearly during sweep.
#[repr(C)]
pub struct BlockHeader {
    pub tag: usize,
    pub block_size: usize,
}

impl BlockHeader {
    const MARK_BIT: usize = 1;

    #[inline] pub fn is_marked(&self) -> bool { self.tag & Self::MARK_BIT != 0 }
    #[inline] pub fn set_mark(&mut self)       { self.tag |=  Self::MARK_BIT; }
    #[inline] pub fn clear_mark(&mut self)     { self.tag &= !Self::MARK_BIT; }
    #[inline] pub fn type_desc(&self) -> *const TypeDesc {
        (self.tag & !Self::MARK_BIT) as *const TypeDesc
    }
    #[inline] pub fn is_free(&self) -> bool {
        (self.tag & !Self::MARK_BIT) == 0
    }
}

pub type Finalizer = unsafe extern "C" fn(*mut u8);

/// Runtime type descriptor emitted by `newm2-llvm` for every heap-allocated
/// type.  Layout frozen — must match the struct type emitted in codegen.
///
/// ```text
/// { i64 size, ptr module, ptr finalizer, ptr base,
///   ptr vtable, i64 vtable_len, ptr name, [1 x i64] ptroffs }
/// ```
#[repr(C)]
pub struct TypeDesc {
    /// Payload size in bytes (not counting the 16-byte BlockHeader).
    pub size: isize,
    /// Pointer to the module-level `ModuleDesc`, or null.
    pub module: *const ModuleDesc,
    /// Optional finalizer called before the block is reclaimed.
    pub finalizer: Option<Finalizer>,
    /// Base-type TypeDesc for IS / type-guard traversal, or null.
    pub base: *const TypeDesc,
    /// Pointer to the vtable array (mutable, patched post-JIT), or null.
    pub vtable: *const *const (),
    /// Number of vtable slots.
    pub vtable_len: u64,
    /// Qualified type name as a zero-terminated UTF-32 codepoint sequence
    /// (`*const u32`), or null.  Read by `dump-heap` and the type catalog.
    pub name: *const u32,
    /// Sentinel-terminated array of non-negative byte offsets of pointer
    /// fields within the payload.  Terminated by the first negative entry
    /// (sentinel = -1 cast to isize).  Used by the mark phase for precise
    /// child tracing.  Just `[-1]` when no pointer fields are tracked.
    pub ptroffs: [isize; 0],
}

unsafe impl Sync for TypeDesc {}
unsafe impl Send for TypeDesc {}

impl TypeDesc {
    /// Iterator over the non-negative pointer offsets in `ptroffs`.
    /// Terminates at the first negative entry.
    ///
    /// # Safety
    /// `ptroffs` must be a valid sentinel-terminated array for the
    /// lifetime of the iterator.
    pub unsafe fn pointer_offsets(&self) -> impl Iterator<Item = isize> {
        let mut idx = 0usize;
        let base = self.ptroffs.as_ptr();
        std::iter::from_fn(move || unsafe {
            let offset = *base.add(idx);
            if offset < 0 { None } else { idx += 1; Some(offset) }
        })
    }
}

/// Module-level root metadata.  Layout frozen.
#[repr(C)]
pub struct ModuleDesc {
    pub var_base: *const u8,
    pub ptrs: *const isize,
    pub next: *const ModuleDesc,
}

unsafe impl Sync for ModuleDesc {}
unsafe impl Send for ModuleDesc {}

// ─────────────────────────────────────────────────────────────────────────────
// Always-on atomic counters
// ─────────────────────────────────────────────────────────────────────────────

pub struct HeapCounters {
    pub alloc_blocks_lifetime:          AtomicU64,
    pub alloc_bytes_lifetime:           AtomicU64,
    pub free_blocks_lifetime:           AtomicU64,
    pub free_bytes_lifetime:            AtomicU64,
    pub bump_path_blocks:               AtomicU64,
    pub free_list_path_blocks:          AtomicU64,
    pub grow_events:                    AtomicU64,
    pub collect_cycles:                 AtomicU64,
    pub collect_total_nanos:            AtomicU64,
    pub collect_last_nanos:             AtomicU64,
    pub collect_last_reclaimed_bytes:   AtomicU64,
    pub live_blocks:                    AtomicU64,
    pub live_bytes:                     AtomicU64,
    pub cluster_count:                  AtomicU64,
    pub module_root_count:              AtomicU64,
    pub peak_live_bytes:                AtomicU64,
    pub registered_threads:             AtomicU64,
}

impl HeapCounters {
    const fn zeroed() -> Self {
        macro_rules! z { () => { AtomicU64::new(0) }; }
        Self {
            alloc_blocks_lifetime:        z!(),
            alloc_bytes_lifetime:         z!(),
            free_blocks_lifetime:         z!(),
            free_bytes_lifetime:          z!(),
            bump_path_blocks:             z!(),
            free_list_path_blocks:        z!(),
            grow_events:                  z!(),
            collect_cycles:               z!(),
            collect_total_nanos:          z!(),
            collect_last_nanos:           z!(),
            collect_last_reclaimed_bytes: z!(),
            live_blocks:                  z!(),
            live_bytes:                   z!(),
            cluster_count:                z!(),
            module_root_count:            z!(),
            peak_live_bytes:              z!(),
            registered_threads:           z!(),
        }
    }
}

pub static HEAP_COUNTERS: HeapCounters = HeapCounters::zeroed();

// ─────────────────────────────────────────────────────────────────────────────
// Cluster — one OS-allocation chunk subdivided into blocks
// ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_CLUSTER_SIZE: usize = 1 << 20; // 1 MiB
pub(crate) const BLOCK_ALIGN: usize = 16;
pub(crate) const MIN_BLOCK: usize = 32;

#[derive(Debug, Clone, Copy)]
pub(crate) enum AllocPath { Bump, FreeList }

/// Free-block payload prefix (singly-linked list within a cluster).
#[repr(C)]
struct FreeBlockLink { next: *mut u8 }

pub(crate) struct Cluster {
    pub(crate) base: *mut u8,
    pub(crate) size: usize,
    pub(crate) bump: usize,
    pub(crate) free_list: *mut u8,
    layout: Layout,
    /// Bit `i` set iff a block begins at `i * BLOCK_ALIGN` from `base`.
    pub(crate) block_starts: Vec<u64>,
}

unsafe impl Send for Cluster {}

impl Drop for Cluster {
    fn drop(&mut self) {
        unsafe { std::alloc::dealloc(self.base, self.layout) };
    }
}

impl Cluster {
    fn new(min_size: usize) -> Self {
        let size = min_size.max(DEFAULT_CLUSTER_SIZE);
        let layout = Layout::from_size_align(size, BLOCK_ALIGN).unwrap();
        let base = unsafe { std::alloc::alloc_zeroed(layout) };
        if base.is_null() { std::alloc::handle_alloc_error(layout); }
        let bits = size / BLOCK_ALIGN;
        let words = (bits + 63) / 64;
        Self { base, size, bump: 0, free_list: std::ptr::null_mut(), layout,
               block_starts: vec![0u64; words] }
    }

    #[inline]
    fn contains(&self, addr: usize) -> bool {
        let base = self.base as usize;
        addr >= base && addr < base + self.bump
    }

    #[inline]
    fn mark_block_start(&mut self, offset: usize) {
        let bit = offset / BLOCK_ALIGN;
        self.block_starts[bit / 64] |= 1u64 << (bit % 64);
    }

    #[inline]
    fn clear_block_start(&mut self, offset: usize) {
        let bit = offset / BLOCK_ALIGN;
        self.block_starts[bit / 64] &= !(1u64 << (bit % 64));
    }

    fn block_start_at_or_below(&self, offset: usize) -> Option<usize> {
        let offset = offset.min(self.bump.saturating_sub(BLOCK_ALIGN));
        let bit = offset / BLOCK_ALIGN;
        let word_idx = bit / 64;
        let bit_in_word = bit % 64;
        let mask = if bit_in_word == 63 { !0u64 } else { (1u64 << (bit_in_word + 1)) - 1 };
        let first = self.block_starts[word_idx] & mask;
        if first != 0 {
            let top = 63 - first.leading_zeros() as usize;
            return Some((word_idx * 64 + top) * BLOCK_ALIGN);
        }
        for w in (0..word_idx).rev() {
            let word = self.block_starts[w];
            if word != 0 {
                let top = 63 - word.leading_zeros() as usize;
                return Some((w * 64 + top) * BLOCK_ALIGN);
            }
        }
        None
    }

    /// Try to satisfy a `total_size`-byte allocation.  Returns the
    /// **header** pointer plus the path taken.  Payload bytes are zeroed.
    ///
    /// # Safety
    /// `total_size` must be a multiple of `BLOCK_ALIGN` and ≥ `MIN_BLOCK`.
    unsafe fn try_alloc(&mut self, total_size: usize) -> Option<(*mut u8, AllocPath)> {
        let header_size = std::mem::size_of::<BlockHeader>();

        // Free-list (first-fit).
        unsafe {
            let mut prev_link: *mut *mut u8 = &mut self.free_list;
            while !(*prev_link).is_null() {
                let block = *prev_link;
                let block_size = (*(block as *const BlockHeader)).block_size;
                let next_link = block.add(header_size) as *mut *mut u8;
                if block_size >= total_size {
                    *prev_link = *next_link;
                    let leftover = block_size - total_size;
                    if leftover >= MIN_BLOCK {
                        let split = block.add(total_size);
                        let split_offset = (split as usize) - (self.base as usize);
                        let split_hdr = split as *mut BlockHeader;
                        (*split_hdr).tag = 0;
                        (*split_hdr).block_size = leftover;
                        let split_link = split.add(header_size) as *mut FreeBlockLink;
                        split_link.write(FreeBlockLink { next: self.free_list });
                        self.free_list = split;
                        self.mark_block_start(split_offset);
                        (*(block as *mut BlockHeader)).block_size = total_size;
                    }
                    let final_size = (*(block as *const BlockHeader)).block_size;
                    let payload = block.add(header_size);
                    std::ptr::write_bytes(payload, 0, final_size - header_size);
                    return Some((block, AllocPath::FreeList));
                }
                prev_link = next_link;
            }
        }

        // Bump from tail.
        if self.bump.checked_add(total_size)? <= self.size {
            let block_offset = self.bump;
            let block = unsafe { self.base.add(block_offset) };
            self.bump += total_size;
            unsafe { (*(block as *mut BlockHeader)).block_size = total_size; }
            self.mark_block_start(block_offset);
            return Some((block, AllocPath::Bump));
        }

        None
    }

    /// Resolve an arbitrary address to the payload start of the block
    /// containing it, or `None`.  Used by the conservative stack scan.
    unsafe fn resolve(&self, addr: usize) -> Option<*const u8> {
        if !self.contains(addr) { return None; }
        let header_size = std::mem::size_of::<BlockHeader>();
        let base = self.base as usize;
        let offset_in_cluster = addr - base;
        let block_offset = self.block_start_at_or_below(offset_in_cluster)?;
        unsafe {
            let block = self.base.add(block_offset);
            let hdr = block as *const BlockHeader;
            let block_size = (*hdr).block_size;
            if block_size < MIN_BLOCK || block_offset + block_size > self.bump { return None; }
            let block_end = base + block_offset + block_size;
            if addr >= block_end { return None; }
            let type_bits = (*hdr).tag & !BlockHeader::MARK_BIT;
            if type_bits == 0 { return None; } // free block
            let payload_start = base + block_offset + header_size;
            if addr < payload_start { return None; }
            Some(payload_start as *const u8)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TypeDesc registry
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct TypeDescEntry {
    pub addr: usize,
    pub block_count: u64,
    pub owner_module: Option<String>,
    pub size_bytes: isize,
}

pub(crate) struct TypeDescRegistry {
    by_addr: HashMap<usize, TypeDescEntry>,
}

impl TypeDescRegistry {
    fn new() -> Self { Self { by_addr: HashMap::new() } }

    fn record(&mut self, td: usize, owner_module: Option<String>) {
        let size_bytes = if td == 0 { 0 } else { unsafe { (*(td as *const TypeDesc)).size } };
        self.by_addr.entry(td).or_insert(TypeDescEntry {
            addr: td, block_count: 0, owner_module, size_bytes,
        });
    }

    fn inc(&mut self, td: usize) {
        let entry = self.by_addr.entry(td).or_insert_with(|| TypeDescEntry {
            addr: td,
            block_count: 0,
            owner_module: None,
            size_bytes: if td == 0 { 0 } else { unsafe { (*(td as *const TypeDesc)).size } },
        });
        entry.block_count = entry.block_count.saturating_add(1);
    }

    fn dec(&mut self, td: usize) {
        if let Some(entry) = self.by_addr.get_mut(&td) {
            if entry.block_count > 0 { entry.block_count -= 1; }
        }
    }

    pub(crate) fn snapshot(&self) -> Vec<TypeDescEntry> {
        let mut out: Vec<_> = self.by_addr.values().cloned().collect();
        out.sort_by_key(|e| e.addr);
        out
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Module roots
// ─────────────────────────────────────────────────────────────────────────────

pub(crate) struct ModuleRoots {
    pub(crate) name: String,
    pub(crate) var_base: *const u8,
    pub(crate) offsets: Vec<isize>,
}

unsafe impl Send for ModuleRoots {}

// ─────────────────────────────────────────────────────────────────────────────
// Per-thread mutator state
// ─────────────────────────────────────────────────────────────────────────────

const STATE_RUNNING:        u8 = 0;
const STATE_PARKED:         u8 = 2;

pub(crate) struct Mutator {
    pub(crate) thread_id:              ThreadId,
    pub(crate) stack_top:              usize,
    pub(crate) state:                  AtomicU8,
    pub(crate) parked_sp:              AtomicUsize,
    /// Callee-saved register spill captured at park time.
    pub(crate) spill:                  Mutex<[usize; 16]>,
    pub(crate) alloc_blocks_lifetime:  AtomicU64,
    pub(crate) alloc_bytes_lifetime:   AtomicU64,
    pub(crate) park_count:             AtomicU64,
}

// ─────────────────────────────────────────────────────────────────────────────
// Collection log
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct CollectRecord {
    pub generation:       u64,
    pub elapsed_nanos:    u64,
    pub mutators_parked:  u64,
    pub roots_marked:     u64,
    pub blocks_freed:     u64,
    pub bytes_freed:      u64,
    pub bytes_live_after: u64,
}

pub(crate) struct CollectLog {
    capacity: usize,
    entries:  std::collections::VecDeque<CollectRecord>,
}

impl CollectLog {
    fn new(cap: usize) -> Self {
        Self { capacity: cap, entries: std::collections::VecDeque::with_capacity(cap) }
    }

    fn push(&mut self, rec: CollectRecord) {
        if self.entries.len() == self.capacity { self.entries.pop_front(); }
        self.entries.push_back(rec);
    }

    pub(crate) fn snapshot(&self) -> Vec<CollectRecord> {
        self.entries.iter().cloned().collect()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Heap state
// ─────────────────────────────────────────────────────────────────────────────

pub struct Heap {
    pub(crate) clusters:            Vec<Cluster>,
    pub(crate) modules:             Vec<ModuleRoots>,
    pub(crate) type_descs:          TypeDescRegistry,
    pub(crate) collect_log:         CollectLog,
    pub(crate) generation:          u64,
    pub(crate) pending_finalizers:  Vec<(Finalizer, *mut u8)>,
}

unsafe impl Send for Heap {}

static HEAP_CELL: OnceLock<Mutex<Heap>> = OnceLock::new();

fn heap_lock() -> std::sync::MutexGuard<'static, Heap> {
    HEAP_CELL.get_or_init(|| {
        Mutex::new(Heap {
            clusters: Vec::new(),
            modules: Vec::new(),
            type_descs: TypeDescRegistry::new(),
            collect_log: CollectLog::new(16),
            generation: 0,
            pending_finalizers: Vec::new(),
        })
    }).lock().unwrap()
}

// ─────────────────────────────────────────────────────────────────────────────
// Mutator registry + TLS
// ─────────────────────────────────────────────────────────────────────────────

static MUTATORS: RwLock<Vec<Arc<Mutator>>> = RwLock::new(Vec::new());

/// Initial-thread bootstrap stack base.  Set by `nm2_init_gc`.
static BOOTSTRAP_STACK_BASE: AtomicUsize = AtomicUsize::new(0);

struct MutatorTls {
    handle: std::cell::RefCell<Option<Arc<Mutator>>>,
}

impl Drop for MutatorTls {
    fn drop(&mut self) {
        if let Some(m) = self.handle.borrow().clone() {
            let id = m.thread_id;
            m.state.store(STATE_PARKED, Ordering::SeqCst);
            let mut threads = MUTATORS.write().unwrap();
            threads.retain(|x| x.thread_id != id);
            HEAP_COUNTERS.registered_threads.store(threads.len() as u64, Ordering::Relaxed);
            drop(threads);
            let _g = SAFEPOINT_LOCK.lock().unwrap();
            SAFEPOINT_CONDVAR.notify_all();
        }
    }
}

thread_local! {
    static MUTATOR_HANDLE: MutatorTls = MutatorTls {
        handle: std::cell::RefCell::new(None),
    };
}

fn ensure_mutator() -> Arc<Mutator> {
    if let Some(m) = MUTATOR_HANDLE.with(|tls| tls.handle.borrow().clone()) {
        return m;
    }
    let stack_top = BOOTSTRAP_STACK_BASE.load(Ordering::Acquire);
    register_thread_inner(stack_top)
}

fn register_thread_inner(stack_top: usize) -> Arc<Mutator> {
    let m = Arc::new(Mutator {
        thread_id: std::thread::current().id(),
        stack_top,
        state: AtomicU8::new(STATE_RUNNING),
        parked_sp: AtomicUsize::new(0),
        spill: Mutex::new([0usize; 16]),
        alloc_blocks_lifetime: AtomicU64::new(0),
        alloc_bytes_lifetime: AtomicU64::new(0),
        park_count: AtomicU64::new(0),
    });
    {
        let mut threads = MUTATORS.write().unwrap();
        threads.push(m.clone());
        HEAP_COUNTERS.registered_threads.store(threads.len() as u64, Ordering::Relaxed);
    }
    MUTATOR_HANDLE.with(|tls| { *tls.handle.borrow_mut() = Some(m.clone()); });
    m
}

// ─────────────────────────────────────────────────────────────────────────────
// Cooperative safepoint mechanism
// ─────────────────────────────────────────────────────────────────────────────

/// Global stop-the-world flag.  Mutators check this at safepoints and at
/// every allocation slow-path.  The collector sets it, waits for every
/// mutator to park, does its work, then clears and notifies.
pub static SAFEPOINT_REQUESTED: AtomicU8 = AtomicU8::new(0);
pub(crate) static SAFEPOINT_CONDVAR:   Condvar   = Condvar::new();
pub(crate) static SAFEPOINT_LOCK:      Mutex<()> = Mutex::new(());

// ─────────────────────────────────────────────────────────────────────────────
// Pressure-based collection
//
// Every successful allocation adds its byte count to ALLOC_PRESSURE_BYTES.
// When the counter crosses GC_PRESSURE_THRESHOLD_BYTES the next nm2_new_rec
// call triggers a stop-the-world collection and resets the counter.  This
// keeps heap occupancy bounded well below the hard "all clusters full" limit
// and produces shorter, more frequent GC pauses rather than one long pause
// at heap exhaustion.
//
// Default threshold: 512 KiB.  Tunable at runtime via nm2_set_gc_pressure.
// ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_PRESSURE_THRESHOLD_BYTES: u64 = 512 * 1024;

static ALLOC_PRESSURE_BYTES:     AtomicU64 = AtomicU64::new(0);
static GC_PRESSURE_THRESHOLD:    AtomicU64 = AtomicU64::new(DEFAULT_PRESSURE_THRESHOLD_BYTES);

/// Park the current mutator at a safepoint.  Spills callee-saved registers,
/// captures RSP, marks state as Parked, waits on `SAFEPOINT_CONDVAR` until
/// the collector clears the flag.
#[inline(never)]
fn park_self() {
    let m = ensure_mutator();
    let mut spill_buf = [0usize; 16];
    let sp = capture_sp(&mut spill_buf);
    if let Ok(mut buf) = m.spill.lock() { *buf = spill_buf; }
    m.parked_sp.store(sp, Ordering::Release);
    m.state.store(STATE_PARKED, Ordering::SeqCst);
    m.park_count.fetch_add(1, Ordering::Relaxed);
    let mut guard = SAFEPOINT_LOCK.lock().unwrap();
    while SAFEPOINT_REQUESTED.load(Ordering::Acquire) != 0 {
        guard = SAFEPOINT_CONDVAR.wait(guard).unwrap();
    }
    drop(guard);
    m.state.store(STATE_RUNNING, Ordering::SeqCst);
}

// ─────────────────────────────────────────────────────────────────────────────
// JIT-callable entry points  (extern "C-unwind" — see module-level doc)
// ─────────────────────────────────────────────────────────────────────────────

/// Initialise the GC and record the bootstrap-thread stack base.  Idempotent;
/// only the first call has effect.  Must be called once per process on the
/// bootstrap thread before any other `nm2_*` entry point.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_init_gc(base_stack: *const u8) {
    let prev = BOOTSTRAP_STACK_BASE.load(Ordering::Acquire);
    if prev == 0 {
        BOOTSTRAP_STACK_BASE.store(base_stack as usize, Ordering::Release);
    }
    ensure_mutator();
}

/// Register the calling thread as a NewM2 mutator.  Required by any thread
/// that wants to call into JIT'd code.  The bootstrap thread is registered
/// automatically by `nm2_init_gc`.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_register_thread(stack_top: *const u8) {
    let _ = register_thread_inner(stack_top as usize);
}

/// Unregister the calling thread.  The TLS drop guard also does this on
/// thread exit, so explicit calls are optional.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_unregister_thread() {
    let id = std::thread::current().id();
    let mut threads = MUTATORS.write().unwrap();
    threads.retain(|m| m.thread_id != id);
    HEAP_COUNTERS.registered_threads.store(threads.len() as u64, Ordering::Relaxed);
    MUTATOR_HANDLE.with(|tls| { *tls.handle.borrow_mut() = None; });
}

/// Allocate and zero-initialise a heap-tracked record.
///
/// `tag` must point to the type's `TypeDesc` global emitted by `newm2-llvm`.
/// Returns a pointer to the zeroed payload (the `TypeDesc` address is stored
/// in the `BlockHeader` immediately before it).
///
/// Allocation is implicitly a safepoint poll: if the GC requested a stop,
/// this call will park until collection finishes before allocating.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_new_rec(tag: *const TypeDesc) -> *mut u8 {
    if SAFEPOINT_REQUESTED.load(Ordering::Acquire) != 0 {
        park_self();
    }

    let mut spill_buf = [0usize; 16];
    let sp = capture_sp(&mut spill_buf);

    let mutator = ensure_mutator();
    let payload_size = unsafe { (*tag).size as usize };
    let total_size = total_block_size(payload_size);
    let header_size = std::mem::size_of::<BlockHeader>();

    // Soft pressure trigger: collect before allocating a new block so the
    // returned payload cannot be reclaimed before the caller roots it.
    let projected_pressure = alloc_pressure_bytes().saturating_add(total_size as u64);
    if projected_pressure >= GC_PRESSURE_THRESHOLD.load(Ordering::Relaxed) {
        ALLOC_PRESSURE_BYTES.store(0, Ordering::Relaxed);
        let mut spill2 = [0usize; 16];
        let sp2 = capture_sp(&mut spill2);
        collect_stw(&mutator, sp2, &spill2);
    }

    let block = alloc_under_lock(total_size, &mutator, sp, &spill_buf);

    unsafe {
        let hdr = block as *mut BlockHeader;
        (*hdr).tag = tag as usize;
        (*hdr).block_size = total_size;
        heap_lock().type_descs.inc(tag as usize);
    }

    HEAP_COUNTERS.alloc_blocks_lifetime.fetch_add(1, Ordering::Relaxed);
    HEAP_COUNTERS.alloc_bytes_lifetime.fetch_add(total_size as u64, Ordering::Relaxed);
    mutator.alloc_blocks_lifetime.fetch_add(1, Ordering::Relaxed);
    mutator.alloc_bytes_lifetime.fetch_add(total_size as u64, Ordering::Relaxed);

    ALLOC_PRESSURE_BYTES.fetch_add(total_size as u64, Ordering::Relaxed);

    unsafe { block.add(header_size) }
}

/// Allocate untracked bytes (`SYSTEM.NEW`).  These live outside the cluster
/// heap and are never reclaimed by the GC.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_sys_new(n: usize) -> *mut u8 {
    if n == 0 { return std::ptr::NonNull::<u8>::dangling().as_ptr(); }
    let layout = Layout::from_size_align(n, BLOCK_ALIGN)
        .expect("nm2_sys_new: invalid layout");
    let ptr = unsafe { std::alloc::alloc(layout) };
    if ptr.is_null() { std::alloc::handle_alloc_error(layout); }
    ptr
}

/// Cooperative GC safepoint — called at every `GcSafePoint` IR site and
/// after every call in GC mode.  Fast path: one `Acquire` load.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_safepoint() {
    if SAFEPOINT_REQUESTED.load(Ordering::Acquire) != 0 {
        park_self();
    }
}

/// Register `root_slot` as a GC root for the current frame.
///
/// No-op under conservative scanning.  Hook for precise roots.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_gc_push_root(_root_slot: *mut *mut u8) {}

/// Pop the most-recently pushed GC root.  No-op under conservative scanning.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_gc_pop_root() {}

/// Pin a heap object (no-op until a copying collector is in use).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_pin(_ptr: *mut u8) {}

/// Unpin a heap object (no-op until a copying collector is in use).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_unpin(_ptr: *mut u8) {}

/// Set the pressure-collection threshold in bytes.
///
/// After every `threshold` bytes of cumulative allocation the GC will
/// trigger a stop-the-world cycle proactively, before the heap is full.
/// The default is 512 KiB.  Pass 0 to disable pressure collection
/// (hard-trigger only — collection happens when all clusters are full).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_set_gc_pressure(threshold_bytes: u64) {
    // 0 → disabled: store u64::MAX so the check never fires.
    let v = if threshold_bytes == 0 { u64::MAX } else { threshold_bytes };
    GC_PRESSURE_THRESHOLD.store(v, Ordering::Relaxed);
}

/// Return the current pressure-collection threshold in bytes.
/// Returns 0 when pressure collection is disabled.
pub fn gc_pressure_threshold() -> u64 {
    let v = GC_PRESSURE_THRESHOLD.load(Ordering::Relaxed);
    if v == u64::MAX { 0 } else { v }
}

/// Return bytes allocated since the last GC cycle.
pub fn alloc_pressure_bytes() -> u64 {
    ALLOC_PRESSURE_BYTES.load(Ordering::Relaxed)
}

/// Register a module's global pointer-typed variables as GC roots.
///
/// Called from the JIT'd `{module}.init_roots` function emitted by codegen.
/// The collector's mark phase scans each registered slot precisely: it reads
/// `var_base + offset` as a `*const u8` (pointer payload) and traces it.
///
/// # Parameters
/// - `name`     — NUL-terminated module name (informational; used in heap dumps).
/// - `var_base` — Base address of the module's global variable block.
/// - `offsets`  — Array of `isize` offsets from `var_base`; each designates one
///                pointer-typed slot.  Terminated by the sentinel value `-1`
///                (same convention as `TypeDesc::ptroffs`).
/// - `count`    — Number of entries in `offsets` (excluding the `-1` sentinel).
///
/// Idempotent per module name: a second call with the same name is a no-op
/// (safe to call from every module re-load).
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_register_module_roots(
    name:     *const std::os::raw::c_char,
    var_base: *const u8,
    offsets:  *const isize,
    count:    usize,
) {
    let module_name = if name.is_null() {
        String::from("<unknown>")
    } else {
        unsafe { std::ffi::CStr::from_ptr(name) }
            .to_string_lossy()
            .into_owned()
    };

    let offset_slice: &[isize] = if count == 0 || offsets.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(offsets, count) }
    };

    let mut heap = heap_lock();

    // Idempotent: skip if already registered.
    if heap.modules.iter().any(|m| m.name == module_name) {
        return;
    }

    heap.modules.push(ModuleRoots {
        name: module_name,
        var_base,
        offsets: offset_slice.to_vec(),
    });
    HEAP_COUNTERS.module_root_count
        .fetch_add(count as u64, Ordering::Relaxed);
}

// ─────────────────────────────────────────────────────────────────────────────
// Rust API — GC trigger + introspection
// ─────────────────────────────────────────────────────────────────────────────

/// Trigger a stop-the-world collection from Rust code (tests / runtime).
pub fn collect() {
    let mut spill_buf = [0usize; 16];
    let sp = capture_sp(&mut spill_buf);
    let m = ensure_mutator();
    collect_stw(&m, sp, &spill_buf);
}

/// JIT-callable `SYSTEM.COLLECT`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_collect() {
    if BOOTSTRAP_STACK_BASE.load(Ordering::Acquire) == 0 {
        return;
    }
    collect();
}

/// JIT-callable `SYSTEM.GCREPORT`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_gcreport() {
    write_gc_report();
}

/// Set the stop flag.  Every mutator reaching a safepoint will park until
/// `release_gc_stop` is called.
pub fn request_gc_stop() {
    SAFEPOINT_REQUESTED.store(1, Ordering::Release);
    let _g = SAFEPOINT_LOCK.lock().unwrap();
    SAFEPOINT_CONDVAR.notify_all();
}

/// Clear the stop flag and wake all parked mutators.
pub fn release_gc_stop() {
    SAFEPOINT_REQUESTED.store(0, Ordering::Release);
    let _g = SAFEPOINT_LOCK.lock().unwrap();
    SAFEPOINT_CONDVAR.notify_all();
}

/// Number of mutators currently parked at a safepoint.
pub fn parked_count() -> usize {
    MUTATORS.read().unwrap()
        .iter()
        .filter(|m| m.state.load(Ordering::Acquire) == STATE_PARKED)
        .count()
}

/// Register a `TypeDesc` address with the registry.  Called by codegen-
/// emitted `__init_types` and by the loader surface.
pub fn register_typedesc(td: usize, owner_module: Option<String>) {
    heap_lock().type_descs.record(td, owner_module);
}

// ─────────────────────────────────────────────────────────────────────────────
// Allocation slow-path (handles refill / collect / grow)
// ─────────────────────────────────────────────────────────────────────────────

fn alloc_under_lock(
    total_size: usize,
    mutator: &Arc<Mutator>,
    caller_sp: usize,
    caller_spill: &[usize; 16],
) -> *mut u8 {
    // Try all existing clusters.
    {
        let mut heap = heap_lock();
        if let Some((block, path)) = try_alloc_in_clusters(&mut heap, total_size) {
            match path {
                AllocPath::Bump     => HEAP_COUNTERS.bump_path_blocks.fetch_add(1, Ordering::Relaxed),
                AllocPath::FreeList => HEAP_COUNTERS.free_list_path_blocks.fetch_add(1, Ordering::Relaxed),
            };
            return block;
        }
    }

    // Pressure → collect.
    collect_stw(mutator, caller_sp, caller_spill);

    // Retry after collection.
    {
        let mut heap = heap_lock();
        if let Some((block, path)) = try_alloc_in_clusters(&mut heap, total_size) {
            match path {
                AllocPath::Bump     => HEAP_COUNTERS.bump_path_blocks.fetch_add(1, Ordering::Relaxed),
                AllocPath::FreeList => HEAP_COUNTERS.free_list_path_blocks.fetch_add(1, Ordering::Relaxed),
            };
            return block;
        }
        // Grow.
        heap.clusters.push(Cluster::new(total_size));
        HEAP_COUNTERS.grow_events.fetch_add(1, Ordering::Relaxed);
        HEAP_COUNTERS.cluster_count.store(heap.clusters.len() as u64, Ordering::Relaxed);
        let last = heap.clusters.last_mut().unwrap();
        unsafe { last.try_alloc(total_size) }
            .map(|(block, _)| block)
            .expect("fresh cluster must satisfy the allocation request")
    }
}

fn try_alloc_in_clusters(heap: &mut Heap, total_size: usize) -> Option<(*mut u8, AllocPath)> {
    for cluster in &mut heap.clusters {
        if let Some(r) = unsafe { cluster.try_alloc(total_size) } {
            return Some(r);
        }
    }
    None
}

#[inline]
fn align_up(n: usize) -> usize { (n + BLOCK_ALIGN - 1) & !(BLOCK_ALIGN - 1) }

#[inline]
fn total_block_size(payload: usize) -> usize {
    align_up(std::mem::size_of::<BlockHeader>() + payload).max(MIN_BLOCK)
}

// ─────────────────────────────────────────────────────────────────────────────
// Stop-the-world collection
// ─────────────────────────────────────────────────────────────────────────────

fn collect_stw(initiator: &Arc<Mutator>, sp: usize, spill: &[usize; 16]) {
    let t0 = Instant::now();
    let mutators: Vec<Arc<Mutator>> = MUTATORS.read().unwrap().clone();

    // Park self first to avoid deadlocking a concurrent collector.
    if let Ok(mut buf) = initiator.spill.lock() { *buf = *spill; }
    initiator.parked_sp.store(sp, Ordering::Release);
    initiator.state.store(STATE_PARKED, Ordering::SeqCst);

    // Request safepoint and wait for every other mutator to park.
    SAFEPOINT_REQUESTED.store(1, Ordering::SeqCst);
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut all_parked = false;
    while Instant::now() < deadline {
        let running = mutators.iter().filter(|m| {
            m.thread_id != initiator.thread_id
                && m.state.load(Ordering::Acquire) != STATE_PARKED
        }).count();
        if running == 0 { all_parked = true; break; }
        std::thread::sleep(Duration::from_micros(50));
    }

    if !all_parked {
        initiator.state.store(STATE_RUNNING, Ordering::SeqCst);
        SAFEPOINT_REQUESTED.store(0, Ordering::SeqCst);
        let _g = SAFEPOINT_LOCK.lock().unwrap();
        SAFEPOINT_CONDVAR.notify_all();
        eprintln!("[nm2-gc] WARN: collect aborted; not all mutators parked within 2s");
        return;
    }

    let parked_count_snap = mutators.len() as u64;
    let (summary, pending_finalizers) = {
        let mut heap = heap_lock();
        let s = run_collect_cycle(&mut heap, &mutators);
        let pending = std::mem::take(&mut heap.pending_finalizers);
        (s, pending)
    };

    // Resume all mutators.
    SAFEPOINT_REQUESTED.store(0, Ordering::SeqCst);
    initiator.state.store(STATE_RUNNING, Ordering::SeqCst);
    ALLOC_PRESSURE_BYTES.store(0, Ordering::Relaxed); // reset pressure counter
    {
        let _g = SAFEPOINT_LOCK.lock().unwrap();
        SAFEPOINT_CONDVAR.notify_all();
    }

    // Run finalizers outside the safepoint window.
    for (fin, payload) in pending_finalizers {
        unsafe { fin(payload) };
    }

    let elapsed = t0.elapsed().as_nanos() as u64;
    HEAP_COUNTERS.collect_cycles.fetch_add(1, Ordering::Relaxed);
    HEAP_COUNTERS.collect_total_nanos.fetch_add(elapsed, Ordering::AcqRel);
    HEAP_COUNTERS.collect_last_nanos.store(elapsed, Ordering::Relaxed);
    HEAP_COUNTERS.collect_last_reclaimed_bytes.store(summary.bytes_freed, Ordering::Relaxed);

    let mut heap = heap_lock();
    heap.generation += 1;
    let generation_num = heap.generation;
    heap.collect_log.push(CollectRecord {
        generation: generation_num,
        elapsed_nanos: elapsed,
        mutators_parked: parked_count_snap,
        roots_marked: summary.roots_marked,
        blocks_freed: summary.blocks_freed,
        bytes_freed: summary.bytes_freed,
        bytes_live_after: summary.bytes_live,
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// Mark + sweep
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Default)]
struct CollectSummary {
    roots_marked: u64,
    blocks_freed: u64,
    bytes_freed:  u64,
    live_blocks:  u64,
    bytes_live:   u64,
}

fn run_collect_cycle(heap: &mut Heap, mutators: &[Arc<Mutator>]) -> CollectSummary {
    // Clear all marks.
    for cluster in &mut heap.clusters {
        let mut offset = 0usize;
        while offset < cluster.bump {
            unsafe {
                let hdr = cluster.base.add(offset) as *mut BlockHeader;
                if (*hdr).block_size < MIN_BLOCK { break; }
                (*hdr).clear_mark();
                offset += (*hdr).block_size;
            }
        }
    }

    let mut summary = CollectSummary::default();

    // Conservative scan: each parked mutator's stack + spill buffer.
    for m in mutators {
        let sp  = m.parked_sp.load(Ordering::Acquire);
        let top = m.stack_top;
        if sp == 0 || top == 0 || sp >= top { continue; }
        let word = std::mem::size_of::<usize>();
        let mut cursor = sp;
        while cursor < top {
            let val = unsafe { *(cursor as *const usize) };
            if let Some(payload) = resolve_heap_ptr(val, &heap.clusters) {
                unsafe { mark_object(payload, &heap.type_descs) };
                summary.roots_marked += 1;
            }
            cursor += word;
        }
        if let Ok(buf) = m.spill.lock() {
            for &val in buf.iter() {
                if let Some(payload) = resolve_heap_ptr(val, &heap.clusters) {
                    unsafe { mark_object(payload, &heap.type_descs) };
                    summary.roots_marked += 1;
                }
            }
        }
    }

    // Precise module roots.
    for module in &heap.modules {
        for &offset in &module.offsets {
            unsafe {
                let field = module.var_base.add(offset as usize) as *const *const u8;
                let ptr = *field;
                if !ptr.is_null() {
                    mark_object(ptr, &heap.type_descs);
                    summary.roots_marked += 1;
                }
            }
        }
    }

    // Sweep.
    let mut pending: Vec<(Finalizer, *mut u8)> = Vec::new();
    for cluster in &mut heap.clusters {
        let s = unsafe { cluster_sweep(cluster, &mut heap.type_descs, &mut pending) };
        summary.blocks_freed += s.blocks_freed;
        summary.bytes_freed  += s.bytes_freed;
        summary.live_blocks  += s.live_blocks;
        summary.bytes_live   += s.bytes_live;
    }
    heap.pending_finalizers.extend(pending);

    HEAP_COUNTERS.free_blocks_lifetime.fetch_add(summary.blocks_freed, Ordering::Relaxed);
    HEAP_COUNTERS.free_bytes_lifetime.fetch_add(summary.bytes_freed, Ordering::Relaxed);
    HEAP_COUNTERS.live_blocks.store(summary.live_blocks, Ordering::Relaxed);
    HEAP_COUNTERS.live_bytes.store(summary.bytes_live, Ordering::Relaxed);
    HEAP_COUNTERS.cluster_count.store(heap.clusters.len() as u64, Ordering::Relaxed);

    let mut peak = HEAP_COUNTERS.peak_live_bytes.load(Ordering::Acquire);
    while summary.bytes_live > peak {
        match HEAP_COUNTERS.peak_live_bytes.compare_exchange_weak(
            peak, summary.bytes_live, Ordering::AcqRel, Ordering::Acquire,
        ) {
            Ok(_) => break,
            Err(observed) => peak = observed,
        }
    }
    summary
}

fn resolve_heap_ptr(addr: usize, clusters: &[Cluster]) -> Option<*const u8> {
    if addr == 0 { return None; }
    for cluster in clusters {
        if let Some(p) = unsafe { cluster.resolve(addr) } { return Some(p); }
    }
    None
}

unsafe fn mark_object(start: *const u8, registry: &TypeDescRegistry) {
    let mut work: Vec<*const u8> = Vec::with_capacity(64);
    work.push(start);
    while let Some(payload) = work.pop() {
        if payload.is_null() { continue; }
        unsafe {
            let hdr = header_of(payload);
            if (*hdr).is_marked() || (*hdr).is_free() { continue; }
            (*hdr).set_mark();
            let td = (*hdr).type_desc();
            if td.is_null() { continue; }
            if !registry.by_addr.contains_key(&(td as usize)) { continue; }
            let payload_bytes = (*hdr).block_size
                .saturating_sub(std::mem::size_of::<BlockHeader>());
            let claimed = (*td).size;
            if claimed <= 0 || (claimed as usize) > payload_bytes { continue; }
            for offset in (*td).pointer_offsets() {
                if (offset as usize) + std::mem::size_of::<*const u8>() > payload_bytes { break; }
                let field = payload.add(offset as usize) as *const *const u8;
                let child = *field;
                if !child.is_null() { work.push(child); }
            }
        }
    }
}

#[derive(Default)]
struct SweepStats { blocks_freed: u64, bytes_freed: u64, live_blocks: u64, bytes_live: u64 }

unsafe fn cluster_sweep(
    cluster: &mut Cluster,
    registry: &mut TypeDescRegistry,
    pending_finalizers: &mut Vec<(Finalizer, *mut u8)>,
) -> SweepStats {
    let mut stats = SweepStats::default();
    let header_size = std::mem::size_of::<BlockHeader>();
    cluster.free_list = std::ptr::null_mut();
    let mut offset = 0usize;
    let mut prev_free: *mut u8 = std::ptr::null_mut();

    unsafe {
        while offset < cluster.bump {
            let block = cluster.base.add(offset);
            let hdr = block as *mut BlockHeader;
            let block_size = (*hdr).block_size;
            if block_size < MIN_BLOCK || offset + block_size > cluster.bump { break; }

            let type_bits = (*hdr).tag & !BlockHeader::MARK_BIT;
            let is_marked = (*hdr).tag & BlockHeader::MARK_BIT != 0;
            let was_free  = type_bits == 0;
            let is_dead   = !was_free && !is_marked;

            if !was_free && is_marked {
                (*hdr).clear_mark();
                stats.live_blocks += 1;
                stats.bytes_live  += block_size as u64;
                prev_free = std::ptr::null_mut();
            } else {
                if is_dead {
                    stats.blocks_freed += 1;
                    stats.bytes_freed  += block_size as u64;
                    registry.dec(type_bits);
                    if registry.by_addr.contains_key(&type_bits) {
                        let td = type_bits as *const TypeDesc;
                        let payload_bytes = block_size.saturating_sub(header_size);
                        let claimed = (*td).size;
                        if claimed > 0 && (claimed as usize) <= payload_bytes {
                            if let Some(fin) = (*td).finalizer {
                                pending_finalizers.push((fin, block.add(header_size)));
                            }
                        }
                    }
                }

                if !prev_free.is_null() {
                    // Coalesce with previous free block.
                    let prev_hdr = prev_free as *mut BlockHeader;
                    (*prev_hdr).block_size += block_size;
                    cluster.clear_block_start(offset);
                } else {
                    (*hdr).tag = 0;
                    (*hdr).block_size = block_size;
                    let link = block.add(header_size) as *mut FreeBlockLink;
                    link.write(FreeBlockLink { next: cluster.free_list });
                    cluster.free_list = block;
                    prev_free = block;
                }
            }
            offset += block_size;
        }
    }
    stats
}

#[inline]
unsafe fn header_of(payload: *const u8) -> *mut BlockHeader {
    unsafe { payload.sub(std::mem::size_of::<BlockHeader>()) as *mut BlockHeader }
}

// ─────────────────────────────────────────────────────────────────────────────
// Callee-saved register spill + RSP capture
// ─────────────────────────────────────────────────────────────────────────────

#[inline(never)]
fn capture_sp(spill_buf: &mut [usize; 16]) -> usize {
    let sp: usize;
    unsafe {
        #[cfg(all(target_arch = "x86_64", target_os = "windows"))]
        std::arch::asm!(
            "mov [{buf}     ], rbx",
            "mov [{buf} +  8], rbp",
            "mov [{buf} + 16], rdi",
            "mov [{buf} + 24], rsi",
            "mov [{buf} + 32], r12",
            "mov [{buf} + 40], r13",
            "mov [{buf} + 48], r14",
            "mov [{buf} + 56], r15",
            "mov {sp}, rsp",
            buf = in(reg) spill_buf.as_mut_ptr(),
            sp  = out(reg) sp,
        );

        #[cfg(all(target_arch = "x86_64", not(target_os = "windows")))]
        std::arch::asm!(
            "mov [{buf}     ], rbx",
            "mov [{buf} +  8], rbp",
            "mov [{buf} + 16], r12",
            "mov [{buf} + 24], r13",
            "mov [{buf} + 32], r14",
            "mov [{buf} + 40], r15",
            "mov {sp}, rsp",
            buf = in(reg) spill_buf.as_mut_ptr(),
            sp  = out(reg) sp,
        );

        #[cfg(target_arch = "aarch64")]
        std::arch::asm!(
            "stp x19, x20, [{buf}]",
            "stp x21, x22, [{buf}, #16]",
            "stp x23, x24, [{buf}, #32]",
            "stp x25, x26, [{buf}, #48]",
            "mov {sp}, sp",
            buf = in(reg) spill_buf.as_mut_ptr(),
            sp  = out(reg) sp,
        );

        #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
        { sp = spill_buf.as_ptr() as usize; }
    }
    sp
}

// ─────────────────────────────────────────────────────────────────────────────
// Introspection snapshot types (used by heap_introspect and dump-heap)
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct GcState {
    pub clusters:    Vec<ClusterView>,
    pub modules:     Vec<ModuleView>,
    pub type_descs:  Vec<TypeDescEntry>,
    pub mutators:    Vec<MutatorView>,
}

#[derive(Clone)]
pub struct ClusterView {
    pub base: usize, pub size: usize, pub bump: usize,
    pub free_blocks: u64, pub free_bytes: u64,
}

#[derive(Clone)]
pub struct ModuleView {
    pub name: String, pub var_base: usize, pub offset_count: usize,
}

#[derive(Clone)]
pub struct MutatorView {
    pub thread_id:              ThreadId,
    pub stack_top:              usize,
    pub state:                  u8,
    pub parked_sp:              usize,
    pub alloc_blocks_lifetime:  u64,
    pub alloc_bytes_lifetime:   u64,
    pub park_count:             u64,
}

/// Take a locked snapshot of the entire GC state.
pub fn snapshot() -> GcState {
    let heap = heap_lock();
    let mutators_guard = MUTATORS.read().unwrap();

    let clusters = heap.clusters.iter().map(|c| {
        let (fb, fyb) = walk_free_list(c);
        ClusterView { base: c.base as usize, size: c.size, bump: c.bump,
                      free_blocks: fb, free_bytes: fyb }
    }).collect();

    let modules = heap.modules.iter().map(|m| ModuleView {
        name: m.name.clone(), var_base: m.var_base as usize,
        offset_count: m.offsets.len(),
    }).collect();

    let type_descs = heap.type_descs.snapshot();

    let mutators = mutators_guard.iter().map(|m| MutatorView {
        thread_id: m.thread_id,
        stack_top: m.stack_top,
        state: m.state.load(Ordering::Relaxed),
        parked_sp: m.parked_sp.load(Ordering::Relaxed),
        alloc_blocks_lifetime: m.alloc_blocks_lifetime.load(Ordering::Relaxed),
        alloc_bytes_lifetime: m.alloc_bytes_lifetime.load(Ordering::Relaxed),
        park_count: m.park_count.load(Ordering::Relaxed),
    }).collect();

    GcState { clusters, modules, type_descs, mutators }
}

/// Snapshot of the collect log (last 16 cycles).
pub fn collect_log_snapshot() -> Vec<CollectRecord> {
    heap_lock().collect_log.snapshot()
}

fn write_gc_report() {
    let mut out = String::new();

    append_gc_metric_bool(&mut out, "gc.enabled", BOOTSTRAP_STACK_BASE.load(Ordering::Acquire) != 0);
    append_gc_metric_u64(&mut out, "gc.alloc_blocks_lifetime", HEAP_COUNTERS.alloc_blocks_lifetime.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.alloc_bytes_lifetime", HEAP_COUNTERS.alloc_bytes_lifetime.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.free_blocks_lifetime", HEAP_COUNTERS.free_blocks_lifetime.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.free_bytes_lifetime", HEAP_COUNTERS.free_bytes_lifetime.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.bump_path_blocks", HEAP_COUNTERS.bump_path_blocks.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.free_list_path_blocks", HEAP_COUNTERS.free_list_path_blocks.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.grow_events", HEAP_COUNTERS.grow_events.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.collect_cycles", HEAP_COUNTERS.collect_cycles.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.collect_total_nanos", HEAP_COUNTERS.collect_total_nanos.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.collect_last_nanos", HEAP_COUNTERS.collect_last_nanos.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.collect_last_reclaimed_bytes", HEAP_COUNTERS.collect_last_reclaimed_bytes.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.live_blocks", HEAP_COUNTERS.live_blocks.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.live_bytes", HEAP_COUNTERS.live_bytes.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.cluster_count", HEAP_COUNTERS.cluster_count.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.module_root_count", HEAP_COUNTERS.module_root_count.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.peak_live_bytes", HEAP_COUNTERS.peak_live_bytes.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.registered_threads", HEAP_COUNTERS.registered_threads.load(Ordering::Relaxed));
    append_gc_metric_u64(&mut out, "gc.pressure_bytes", alloc_pressure_bytes());
    append_gc_metric_u64(&mut out, "gc.pressure_threshold", gc_pressure_threshold());

    if let Some(last) = collect_log_snapshot().last().cloned() {
        append_gc_metric_u64(&mut out, "gc.last.generation", last.generation);
        append_gc_metric_u64(&mut out, "gc.last.elapsed_nanos", last.elapsed_nanos);
        append_gc_metric_u64(&mut out, "gc.last.mutators_parked", last.mutators_parked);
        append_gc_metric_u64(&mut out, "gc.last.roots_marked", last.roots_marked);
        append_gc_metric_u64(&mut out, "gc.last.blocks_freed", last.blocks_freed);
        append_gc_metric_u64(&mut out, "gc.last.bytes_freed", last.bytes_freed);
        append_gc_metric_u64(&mut out, "gc.last.bytes_live_after", last.bytes_live_after);
    }

    runtime_write_str(&out);
}

fn append_gc_metric_bool(out: &mut String, name: &str, value: bool) {
    out.push_str(name);
    out.push('=');
    out.push_str(if value { "1" } else { "0" });
    out.push('\n');
}

fn append_gc_metric_u64(out: &mut String, name: &str, value: u64) {
    out.push_str(name);
    out.push('=');
    out.push_str(&value.to_string());
    out.push('\n');
}

fn walk_free_list(cluster: &Cluster) -> (u64, u64) {
    let header_size = std::mem::size_of::<BlockHeader>();
    let (mut count, mut bytes) = (0u64, 0u64);
    let mut node = cluster.free_list;
    while !node.is_null() {
        unsafe {
            let hdr = node as *const BlockHeader;
            count += 1;
            bytes += (*hdr).block_size as u64;
            let next_link = node.add(header_size) as *const *mut u8;
            node = *next_link;
        }
    }
    (count, bytes)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal TypeDesc for test allocations.
    /// `ptroffs` is just the sentinel [-1].
    #[repr(C)]
    struct TestTypeDesc {
        header: TypeDesc,
        ptroffs_sentinel: isize,
    }

    static TEST_TD: TestTypeDesc = TestTypeDesc {
        header: TypeDesc {
            size: 32,
            module: std::ptr::null(),
            finalizer: None,
            base: std::ptr::null(),
            vtable: std::ptr::null(),
            vtable_len: 0,
            name: std::ptr::null(),
            ptroffs: [],
        },
        ptroffs_sentinel: -1,
    };

    #[test]
    fn alloc_one_block() {
        // nm2_init_gc registers the test thread.
        let stack_dummy = 0usize;
        unsafe { nm2_init_gc((&stack_dummy as *const usize) as *const u8) };
        let ptr = unsafe { nm2_new_rec(&TEST_TD.header as *const TypeDesc) };
        assert!(!ptr.is_null(), "nm2_new_rec returned null");
        // Payload must be zeroed.
        let val: u64 = unsafe { std::ptr::read(ptr as *const u64) };
        assert_eq!(val, 0, "payload not zeroed");
    }

    #[test]
    fn safepoint_noop_when_no_gc_requested() {
        release_gc_stop(); // ensure flag is clear
        nm2_safepoint();
        // no hang = pass
    }

    #[test]
    fn request_release_roundtrip() {
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

    #[test]
    fn counters_increment_on_alloc() {
        let before = HEAP_COUNTERS.alloc_blocks_lifetime.load(Ordering::Relaxed);
        let stack_dummy = 0usize;
        unsafe { nm2_init_gc((&stack_dummy as *const usize) as *const u8) };
        unsafe { nm2_new_rec(&TEST_TD.header as *const TypeDesc) };
        let after = HEAP_COUNTERS.alloc_blocks_lifetime.load(Ordering::Relaxed);
        assert!(after > before);
    }
}
