//! Signal-safe Windows crash handler.
//!
//! Installs a Vectored Exception Handler that, on a *fatal* hardware fault
//! (access violation, illegal/privileged instruction, integer divide-by-zero,
//! in-page error, stack overflow), writes a backtrace to stderr and then lets
//! the OS proceed with default termination.
//!
//! Each frame is annotated two ways in a single dump:
//!  * **High level** — when the return address lands inside a JIT-compiled
//!    Modula-2 procedure, the registered `Module.Proc` name and byte offset.
//!  * **Low level** — otherwise the owning native module (DLL/exe) so runtime
//!    and OS frames remain identifiable.
//!
//! The handler is async-signal-safe: it performs no heap allocation and no
//! locking. The JIT symbol table is built *before* execution starts and then
//! frozen into an immutable, leaked slice published through atomics, so the
//! handler only reads it (lock-free binary search). All output goes through a
//! fixed stack buffer and a single `WriteFile`.

#![allow(clippy::missing_safety_doc)]

#[cfg(windows)]
pub use imp::{nm2_finalize_jit_symbols, nm2_install_crash_handler, nm2_register_jit_symbol};

#[cfg(not(windows))]
mod imp_stub {
    /// No-op on non-Windows targets (this runtime is Windows-first).
    #[unsafe(no_mangle)]
    pub extern "C-unwind" fn nm2_install_crash_handler() {}
    #[unsafe(no_mangle)]
    pub extern "C-unwind" fn nm2_register_jit_symbol(_addr: usize, _name: *const u8, _len: usize) {}
    #[unsafe(no_mangle)]
    pub extern "C-unwind" fn nm2_finalize_jit_symbols() {}
}
#[cfg(not(windows))]
pub use imp_stub::{nm2_finalize_jit_symbols, nm2_install_crash_handler, nm2_register_jit_symbol};

#[cfg(windows)]
mod imp {
    use core::ffi::c_void;
    use std::sync::Mutex;
    use std::sync::Once;
    use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicUsize, Ordering};

    // ── Win32 FFI ────────────────────────────────────────────────────────────
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn AddVectoredExceptionHandler(first: u32, handler: VectoredHandler) -> *mut c_void;
        fn RtlCaptureStackBackTrace(
            frames_to_skip: u32,
            frames_to_capture: u32,
            back_trace: *mut *mut c_void,
            back_trace_hash: *mut u32,
        ) -> u16;
        fn GetStdHandle(which: u32) -> *mut c_void;
        fn WriteFile(
            handle: *mut c_void,
            buf: *const u8,
            len: u32,
            written: *mut u32,
            overlapped: *mut c_void,
        ) -> i32;
        fn GetModuleHandleExW(flags: u32, addr: *const u16, module: *mut *mut c_void) -> i32;
        fn GetModuleFileNameW(module: *mut c_void, buf: *mut u16, size: u32) -> u32;
    }

    type VectoredHandler = unsafe extern "system" fn(*mut ExceptionPointers) -> i32;

    #[repr(C)]
    struct ExceptionPointers {
        exception_record: *mut ExceptionRecord,
        context_record: *mut c_void,
    }

    #[repr(C)]
    struct ExceptionRecord {
        exception_code: u32,
        exception_flags: u32,
        exception_record: *mut ExceptionRecord,
        exception_address: *mut c_void,
        number_parameters: u32,
        exception_information: [usize; 15],
    }

    const STD_ERROR_HANDLE: u32 = 0xFFFF_FFF4; // (DWORD)-12
    const EXCEPTION_CONTINUE_SEARCH: i32 = 0;
    const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS: u32 = 0x0000_0004;
    const GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT: u32 = 0x0000_0002;

    fn is_fatal(code: u32) -> bool {
        matches!(
            code,
            0xC0000005 // ACCESS_VIOLATION
                | 0xC0000006 // IN_PAGE_ERROR
                | 0xC000001D // ILLEGAL_INSTRUCTION
                | 0xC0000025 // NONCONTINUABLE_EXCEPTION
                | 0xC0000094 // INT_DIVIDE_BY_ZERO
                | 0xC0000095 // INT_OVERFLOW
                | 0xC0000096 // PRIV_INSTRUCTION
                | 0xC00000FD // STACK_OVERFLOW
        )
    }

    fn code_name(code: u32) -> &'static str {
        match code {
            0xC0000005 => "EXCEPTION_ACCESS_VIOLATION",
            0xC0000006 => "EXCEPTION_IN_PAGE_ERROR",
            0xC000001D => "EXCEPTION_ILLEGAL_INSTRUCTION",
            0xC0000025 => "EXCEPTION_NONCONTINUABLE_EXCEPTION",
            0xC0000094 => "EXCEPTION_INT_DIVIDE_BY_ZERO",
            0xC0000095 => "EXCEPTION_INT_OVERFLOW",
            0xC0000096 => "EXCEPTION_PRIV_INSTRUCTION",
            0xC00000FD => "EXCEPTION_STACK_OVERFLOW",
            _ => "EXCEPTION",
        }
    }

    // ── JIT symbol registry ──────────────────────────────────────────────────
    //
    // Built before execution (under a Mutex), then frozen into a leaked, sorted
    // slice published via atomics so the handler reads it lock-free.

    struct Sym {
        addr: usize,
        name: String,
    }

    static PENDING: Mutex<Vec<Sym>> = Mutex::new(Vec::new());
    static FROZEN_PTR: AtomicPtr<Sym> = AtomicPtr::new(core::ptr::null_mut());
    static FROZEN_LEN: AtomicUsize = AtomicUsize::new(0);

    /// Record a JIT-compiled function's entry address and `Module.Proc` name.
    #[unsafe(no_mangle)]
    pub extern "C-unwind" fn nm2_register_jit_symbol(addr: usize, name: *const u8, len: usize) {
        if addr == 0 || name.is_null() || len == 0 {
            return;
        }
        // SAFETY: caller passes a valid UTF-8 byte range for the symbol name.
        let bytes = unsafe { core::slice::from_raw_parts(name, len) };
        let name = String::from_utf8_lossy(bytes).into_owned();
        if let Ok(mut v) = PENDING.lock() {
            v.push(Sym { addr, name });
        }
    }

    /// Freeze the registry: sort by address and publish an immutable slice the
    /// crash handler can binary-search without locking. Idempotent-ish; the
    /// last call wins (later registrations simply re-freeze).
    #[unsafe(no_mangle)]
    pub extern "C-unwind" fn nm2_finalize_jit_symbols() {
        let Ok(mut v) = PENDING.lock() else { return };
        // Drain so repeated JIT runs in one process (e.g. the test harness)
        // don't accumulate duplicate symbols across runs.
        let mut syms = core::mem::take(&mut *v);
        syms.sort_by_key(|s| s.addr);
        let boxed: Box<[Sym]> = syms.into_boxed_slice();
        let len = boxed.len();
        let ptr = Box::leak(boxed).as_mut_ptr();
        FROZEN_LEN.store(len, Ordering::Release);
        FROZEN_PTR.store(ptr, Ordering::Release);
    }

    /// Nearest registered symbol with `addr <= pc`, plus the byte offset.
    fn resolve_jit(pc: usize) -> Option<(&'static str, usize)> {
        let ptr = FROZEN_PTR.load(Ordering::Acquire);
        let len = FROZEN_LEN.load(Ordering::Acquire);
        if ptr.is_null() || len == 0 {
            return None;
        }
        // SAFETY: the slice is leaked (immutable for the process lifetime).
        let syms = unsafe { core::slice::from_raw_parts(ptr, len) };
        // upper_bound: first index whose addr > pc, then step back one.
        let mut lo = 0usize;
        let mut hi = len;
        while lo < hi {
            let mid = (lo + hi) / 2;
            if syms[mid].addr <= pc {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if lo == 0 {
            return None;
        }
        let s = &syms[lo - 1];
        let offset = pc - s.addr;
        // Without per-function sizes we use nearest-symbol resolution; reject
        // implausibly large offsets so native frames above the JIT code region
        // aren't misattributed to the highest M2 symbol.
        const MAX_FN_SPAN: usize = 1 << 20; // 1 MiB
        if offset > MAX_FN_SPAN {
            return None;
        }
        Some((s.name.as_str(), offset))
    }

    // ── Async-signal-safe output ─────────────────────────────────────────────

    fn write_all(bytes: &[u8]) {
        unsafe {
            let h = GetStdHandle(STD_ERROR_HANDLE);
            let mut written: u32 = 0;
            let mut off = 0usize;
            while off < bytes.len() {
                let chunk = (bytes.len() - off).min(u32::MAX as usize) as u32;
                let rc = WriteFile(h, bytes[off..].as_ptr(), chunk, &mut written, core::ptr::null_mut());
                if rc == 0 || written == 0 {
                    break;
                }
                off += written as usize;
            }
        }
    }

    /// Fixed-capacity, no-alloc line buffer.
    struct Line {
        buf: [u8; 512],
        len: usize,
    }
    impl Line {
        fn new() -> Self {
            Line { buf: [0u8; 512], len: 0 }
        }
        fn push(&mut self, s: &[u8]) {
            let n = s.len().min(self.buf.len() - self.len);
            self.buf[self.len..self.len + n].copy_from_slice(&s[..n]);
            self.len += n;
        }
        fn push_str(&mut self, s: &str) {
            self.push(s.as_bytes());
        }
        fn push_hex(&mut self, mut v: usize) {
            let mut tmp = [0u8; 16];
            let mut i = tmp.len();
            if v == 0 {
                self.push(b"0");
                return;
            }
            while v != 0 {
                i -= 1;
                let d = (v & 0xf) as u8;
                tmp[i] = if d < 10 { b'0' + d } else { b'a' + (d - 10) };
                v >>= 4;
            }
            self.push(&tmp[i..]);
        }
        fn push_dec(&mut self, mut v: usize) {
            let mut tmp = [0u8; 20];
            let mut i = tmp.len();
            if v == 0 {
                self.push(b"0");
                return;
            }
            while v != 0 {
                i -= 1;
                tmp[i] = b'0' + (v % 10) as u8;
                v /= 10;
            }
            self.push(&tmp[i..]);
        }
        fn flush(&mut self) {
            write_all(&self.buf[..self.len]);
            self.len = 0;
        }
    }

    /// Best-effort native module name for `pc` (basename only), written into a
    /// stack buffer. Returns the number of bytes written, 0 if unknown.
    fn module_basename(pc: usize, out: &mut [u8; 260]) -> usize {
        unsafe {
            let mut module: *mut c_void = core::ptr::null_mut();
            let rc = GetModuleHandleExW(
                GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                    | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                pc as *const u16,
                &mut module,
            );
            if rc == 0 {
                return 0;
            }
            let mut wide = [0u16; 260];
            let n = GetModuleFileNameW(module, wide.as_mut_ptr(), wide.len() as u32) as usize;
            if n == 0 {
                return 0;
            }
            // Take the basename and down-convert to ASCII bytes (best effort).
            let mut start = 0usize;
            for i in 0..n {
                if wide[i] == b'\\' as u16 || wide[i] == b'/' as u16 {
                    start = i + 1;
                }
            }
            let mut k = 0usize;
            for i in start..n {
                if k >= out.len() {
                    break;
                }
                let c = wide[i];
                out[k] = if c < 128 { c as u8 } else { b'?' };
                k += 1;
            }
            k
        }
    }

    // ── The handler ──────────────────────────────────────────────────────────

    static IN_HANDLER: AtomicBool = AtomicBool::new(false);

    unsafe extern "system" fn handler(info: *mut ExceptionPointers) -> i32 {
        let rec = unsafe { (*info).exception_record };
        if rec.is_null() {
            return EXCEPTION_CONTINUE_SEARCH;
        }
        let code = unsafe { (*rec).exception_code };
        if !is_fatal(code) {
            return EXCEPTION_CONTINUE_SEARCH;
        }
        // Guard against re-entrancy (a fault while dumping).
        if IN_HANDLER.swap(true, Ordering::SeqCst) {
            return EXCEPTION_CONTINUE_SEARCH;
        }

        let fault_addr = unsafe { (*rec).exception_address } as usize;

        let mut line = Line::new();
        line.push_str("\n=== NewM2 fatal exception: ");
        line.push_str(code_name(code));
        line.push_str(" (0x");
        line.push_hex(code as usize);
        line.push_str(") at 0x");
        line.push_hex(fault_addr);
        // Access violation records [read/write, target address].
        if code == 0xC0000005 || code == 0xC0000006 {
            let np = unsafe { (*rec).number_parameters } as usize;
            if np >= 2 {
                let kind = unsafe { (*rec).exception_information[0] };
                let target = unsafe { (*rec).exception_information[1] };
                line.push_str(if kind == 0 {
                    " reading 0x"
                } else if kind == 1 {
                    " writing 0x"
                } else {
                    " executing 0x"
                });
                line.push_hex(target);
            }
        }
        line.push_str(" ===\n");
        line.flush();

        // Capture and annotate the backtrace.
        let mut frames: [*mut c_void; 64] = [core::ptr::null_mut(); 64];
        let n = unsafe {
            RtlCaptureStackBackTrace(0, frames.len() as u32, frames.as_mut_ptr(), core::ptr::null_mut())
        } as usize;

        for (i, &f) in frames.iter().take(n).enumerate() {
            let pc = f as usize;
            if pc == 0 {
                break;
            }
            let mut l = Line::new();
            l.push_str("  #");
            l.push_dec(i);
            l.push_str("  0x");
            l.push_hex(pc);
            if let Some((name, off)) = resolve_jit(pc) {
                // High-level: a JIT-compiled Modula-2 procedure.
                l.push_str("  M2 ");
                l.push_str(name);
                l.push_str("+0x");
                l.push_hex(off);
            } else {
                // Low-level: native module basename.
                let mut modbuf = [0u8; 260];
                let mn = module_basename(pc, &mut modbuf);
                if mn > 0 {
                    l.push_str("  ");
                    l.push(&modbuf[..mn]);
                } else {
                    l.push_str("  <unknown>");
                }
            }
            l.push_str("\n");
            l.flush();
        }

        let mut tail = Line::new();
        tail.push_str("=== end backtrace ===\n");
        tail.flush();

        IN_HANDLER.store(false, Ordering::SeqCst);
        // Let the OS / default handler terminate the process.
        EXCEPTION_CONTINUE_SEARCH
    }

    static INSTALL: Once = Once::new();

    /// Install the vectored exception handler (idempotent).
    #[unsafe(no_mangle)]
    pub extern "C-unwind" fn nm2_install_crash_handler() {
        INSTALL.call_once(|| unsafe {
            // first=1: call ours before previously registered handlers.
            AddVectoredExceptionHandler(1, handler);
        });
    }
}
