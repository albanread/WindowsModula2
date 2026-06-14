//! JIT-callable bootstrap I/O shims: WriteString, WriteInt, WriteLn etc.
//!
//! The shims are bound by name in `newm2-llvm::bind_runtime_helpers` so that
//! every name a Modula-2 program can call (`STextIO.WriteString`,
//! `InOut.WriteInt`, …) resolves to a real function pointer at JIT time.
//! They are intentionally a narrow bootstrap surface, not the final home for
//! full terminal/file/channel I/O semantics.
//!
//! ## Test-capture mode
//!
//! Call [`nm2_test_capture_start`] before JITting a module under test.
//! Everything written via the shims goes into a thread-local `String` buffer
//! instead of stdout.  Call [`nm2_test_capture_drain`] afterwards to get
//! the accumulated output and reset the buffer.
//!
//! Outside of capture mode the shims write directly to stdout.

use std::cell::RefCell;
use std::ffi::CStr;
use std::io::{self, Read, Write};
use std::os::raw::c_char;
use std::slice;
use std::sync::Mutex;

// ── Thread-local capture buffer ──────────────────────────────────────────────

thread_local! {
    static CAPTURE: RefCell<Option<String>> = const { RefCell::new(None) };
}

static HOST_IO_LOCK: Mutex<()> = Mutex::new(());

/// Begin capturing I/O output for the current thread.
/// All subsequent writes via the shims go into an internal buffer.
pub fn nm2_test_capture_start() {
    CAPTURE.with(|c| *c.borrow_mut() = Some(String::new()));
}

/// Drain the capture buffer and return its contents.
/// Capture mode is disabled after this call.
pub fn nm2_test_capture_drain() -> String {
    CAPTURE.with(|c| c.borrow_mut().take().unwrap_or_default())
}

// ── Internal write helper ─────────────────────────────────────────────────────

fn write_str_inner(s: &str) {
    let captured = CAPTURE.with(|c| {
        let mut borrow = c.borrow_mut();
        if let Some(buf) = borrow.as_mut() {
            buf.push_str(s);
            true
        } else {
            false
        }
    });
    if !captured {
        let _guard = HOST_IO_LOCK.lock().unwrap();
        let mut stdout = io::stdout().lock();
        let _ = stdout.write_all(s.as_bytes());
        let _ = stdout.flush();
    }
}

fn write_ln_inner() {
    let captured = CAPTURE.with(|c| {
        let mut borrow = c.borrow_mut();
        if let Some(buf) = borrow.as_mut() {
            buf.push('\n');
            true
        } else {
            false
        }
    });
    if !captured {
        let _guard = HOST_IO_LOCK.lock().unwrap();
        let mut stdout = io::stdout().lock();
        let _ = stdout.write_all(b"\n");
        let _ = stdout.flush();
    }
}

pub(crate) fn runtime_write_str(s: &str) {
    write_str_inner(s);
}

fn format_int(value: i64, _width: i64) -> String {
    value.to_string()
}

fn format_card(value: u64, _width: u64) -> String {
    value.to_string()
}

pub(crate) fn render_utf16_units(units: &[u16]) -> String {
    let mut out = String::new();
    for item in char::decode_utf16(units.iter().copied()) {
        match item {
            Ok(ch) => out.push(ch),
            Err(err) => out.push_str(&format!("\\u{{{:04X}}}", err.unpaired_surrogate())),
        }
    }
    out
}

pub(crate) unsafe fn utf16_nul_terminated_slice<'a>(ptr: *const u16) -> &'a [u16] {
    let mut len = 0usize;
    while unsafe { *ptr.add(len) } != 0 {
        len += 1;
    }
    unsafe { slice::from_raw_parts(ptr, len) }
}

// ── JIT-callable shims ────────────────────────────────────────────────────────
//
// All are `extern "C-unwind"` so that a Rust panic inside a runtime helper
// can unwind back through JIT'd frames (Windows SEH via uwtable=2).

/// Write a NUL-terminated string to the current output.
/// Bound to: STextIO.WriteString, InOut.WriteString.
/// `_high` is the open-array HIGH companion (native ABI); unused — the
/// string is NUL-terminated — but present so the ABI matches the (ptr, high)
/// open-array calling convention.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_io_write_str(ptr: *const c_char, _high: u64) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: caller (codegen) guarantees a valid NUL-terminated string.
    let s = unsafe { CStr::from_ptr(ptr) }.to_string_lossy();
    write_str_inner(&s);
}

/// Write a NUL-terminated UTF-16 string to the current output.
/// Bound to future representation-specific helpers, not CHAR-mode facades.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_io_write_ustr(ptr: *const u16, _high: u64) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: caller guarantees a valid NUL-terminated UTF-16 buffer.
    let units = unsafe { utf16_nul_terminated_slice(ptr) };
    write_str_inner(&render_utf16_units(units));
}

/// Write a signed integer (value, field_width — width is ignored for now).
/// Bound to: SWholeIO.WriteInt, InOut.WriteInt
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_write_int(value: i64, _width: i64) {
    write_str_inner(&format_int(value, _width));
}

/// Write a signed integer through the UCHAR-family text path.
/// Bound to future representation-specific helpers, not CHAR-mode facades.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_write_uint(value: i64, width: i64) {
    write_str_inner(&format_int(value, width));
}

/// Write a cardinal/unsigned integer (value, field_width).
/// Bound to: SWholeIO.WriteCard, InOut.WriteCard
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_write_card(value: u64, _width: u64) {
    write_str_inner(&format_card(value, _width));
}

/// Write a cardinal through the UCHAR-family text path.
/// Bound to future representation-specific helpers, not CHAR-mode facades.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_write_ucard(value: u64, width: u64) {
    write_str_inner(&format_card(value, width));
}

/// Write a newline.
/// Bound to: STextIO.WriteLn, InOut.WriteLn
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_write_ln() {
    write_ln_inner();
}

/// Write a single character.
/// Bound to: STextIO.WriteChar, InOut.Write
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_write_char(c: u8) {
    write_str_inner(&(c as char).to_string());
}

// ---- Simulated libc -----------------------------------------------------
//
// A small clean-room equivalent of the C-library entry points the conformance
// corpus uses (`printf`, `exit`). These are NewModula2 *runtime* functions —
// not a link to a platform libc — so they behave identically on Windows and
// (later) mac/linux. The format string is taken as NewModula2's wide
// (UTF-16) `ARRAY OF CHAR`; variadic arguments are accepted by the ABI but
// not yet interpolated (the corpus's run tests pass on exit code, not output).

/// `printf` equivalent: write the (UTF-16) format string. Variadic arguments
/// are passed by the caller per the C ABI and ignored here. Bound to:
/// `libc.printf`.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_libc_printf(ptr: *const u16, _high: u64) -> i32 {
    if ptr.is_null() {
        return 0;
    }
    // SAFETY: the format is a NUL-terminated wide string (string literal) or a
    // wide ARRAY OF CHAR; read up to the wide NUL.
    let units = unsafe { utf16_nul_terminated_slice(ptr) };
    let s = render_utf16_units(units);
    write_str_inner(&s);
    s.len() as i32
}

/// `exit` equivalent: terminate the program with `code`. Bound to: `libc.exit`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_libc_exit(code: i64) {
    use std::io::Write;
    let _ = std::io::stdout().flush();
    std::process::exit(code as i32);
}

/// Write a single UTF-16 code unit.
/// Bound to future representation-specific helpers, not CHAR-mode facades.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_write_uchar(c: u16) {
    let rendered = render_utf16_units(&[c]);
    write_str_inner(&rendered);
}

// ── ISO channel device backing (NM2IO.*) ──────────────────────────────────────
//
// These back the StdChans console DeviceTable. NewModula2's CHAR is a wide
// (UTF-16) cell, so the text path takes a `*const u16` count of CHAR cells and
// renders UTF-8. Capture-aware (test harness) for stdout; stderr is direct.

/// Write `n` CHAR cells (UTF-16) at `addr` to stdout. Bound to `NM2.IO.WriteText`.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_io_write_text(addr: *const u16, n: u64) {
    if addr.is_null() || n == 0 {
        return;
    }
    let units = unsafe { slice::from_raw_parts(addr, n as usize) };
    write_str_inner(&render_utf16_units(units));
}

/// Write `n` CHAR cells (UTF-16) at `addr` to stderr. Bound to
/// `NM2.IO.WriteErrText`. Not capture-redirected (diagnostics go to the host).
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_io_write_err_text(addr: *const u16, n: u64) {
    if addr.is_null() || n == 0 {
        return;
    }
    let units = unsafe { slice::from_raw_parts(addr, n as usize) };
    let s = render_utf16_units(units);
    let _guard = HOST_IO_LOCK.lock().unwrap();
    let mut stream = io::stderr().lock();
    let _ = stream.write_all(s.as_bytes());
    let _ = stream.flush();
}

/// Write `n` raw bytes at `addr` to stdout (RawIO / binary path). Bound to
/// `NM2.IO.WriteBytes`. In capture mode the bytes are appended lossily.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_io_write_bytes(addr: *const u8, n: u64) {
    if addr.is_null() || n == 0 {
        return;
    }
    let bytes = unsafe { slice::from_raw_parts(addr, n as usize) };
    let captured = CAPTURE.with(|c| {
        let mut borrow = c.borrow_mut();
        if let Some(buf) = borrow.as_mut() {
            buf.push_str(&String::from_utf8_lossy(bytes));
            true
        } else {
            false
        }
    });
    if !captured {
        let _guard = HOST_IO_LOCK.lock().unwrap();
        let mut stream = io::stdout().lock();
        let _ = stream.write_all(bytes);
        let _ = stream.flush();
    }
}

/// Flush stdout. Bound to `NM2.IO.Flush`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_flush() {
    let captured = CAPTURE.with(|c| c.borrow().is_some());
    if !captured {
        let _guard = HOST_IO_LOCK.lock().unwrap();
        let _ = io::stdout().lock().flush();
    }
}

/// Flush stderr. Bound to `NM2.IO.FlushErr`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_flush_err() {
    let _guard = HOST_IO_LOCK.lock().unwrap();
    let _ = io::stderr().lock().flush();
}

// ── stdin (channel read path) ─────────────────────────────────────────────────
//
// One-cell lookahead so `IOChan.Look` is non-destructive. ASCII/Latin-1 bytes
// map straight to CHAR cells (sufficient for the test surface; full UTF-8
// decoding can layer on later). EOF is sticky.

struct StdinState {
    peek: Option<u16>,
    at_eof: bool,
}

static STDIN_STATE: Mutex<StdinState> = Mutex::new(StdinState { peek: None, at_eof: false });

// IOConsts.ReadResults ordinals (see library/isodef/IOConsts.def).
const READ_ALL_RIGHT: i32 = 1;
const READ_END_OF_LINE: i32 = 4;
const READ_END_OF_INPUT: i32 = 5;

fn refill_peek(state: &mut StdinState) {
    if state.peek.is_some() || state.at_eof {
        return;
    }
    let _guard = HOST_IO_LOCK.lock().unwrap();
    let mut buf = [0u8; 1];
    match io::stdin().lock().read(&mut buf) {
        Ok(0) => state.at_eof = true,
        Ok(_) => state.peek = Some(buf[0] as u16),
        Err(_) => state.at_eof = true,
    }
}

/// Peek the next stdin CHAR without consuming. Stores it into `*out_ch` and an
/// `IOConsts.ReadResults` ordinal into `*out_res`. Bound to `NM2.IO.PeekChar`.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_io_peek_char(out_ch: *mut u16, out_res: *mut i32) {
    if out_ch.is_null() || out_res.is_null() {
        return;
    }
    let mut state = STDIN_STATE.lock().unwrap();
    refill_peek(&mut state);
    match state.peek {
        Some(c) => unsafe {
            *out_ch = c;
            *out_res = if c == b'\n' as u16 { READ_END_OF_LINE } else { READ_ALL_RIGHT };
        },
        None => unsafe {
            *out_ch = 0;
            *out_res = READ_END_OF_INPUT;
        },
    }
}

/// Discard the most-recently-peeked CHAR. Bound to `NM2.IO.ConsumeChar`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_io_consume_char() {
    STDIN_STATE.lock().unwrap().peek = None;
}

/// Read up to `max` CHAR cells from stdin into `addr`; actual count via `*out_n`.
/// Bound to `NM2.IO.ReadText`.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_io_read_text(addr: *mut u16, max: u64, out_n: *mut u64) {
    if out_n.is_null() {
        return;
    }
    if addr.is_null() || max == 0 {
        unsafe { *out_n = 0 };
        return;
    }
    let mut state = STDIN_STATE.lock().unwrap();
    let dst = unsafe { slice::from_raw_parts_mut(addr, max as usize) };
    let mut written = 0usize;
    if let Some(c) = state.peek.take() {
        dst[0] = c;
        written = 1;
    }
    while written < dst.len() && !state.at_eof {
        let _guard = HOST_IO_LOCK.lock().unwrap();
        let mut buf = [0u8; 1];
        match io::stdin().lock().read(&mut buf) {
            Ok(0) => state.at_eof = true,
            Ok(_) => {
                dst[written] = buf[0] as u16;
                written += 1;
            }
            Err(_) => state.at_eof = true,
        }
    }
    unsafe { *out_n = written as u64 };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_ustr_renders_bmp_text() {
        let data = [b'H' as u16, b'i' as u16, 0];
        nm2_test_capture_start();
        unsafe { nm2_io_write_ustr(data.as_ptr(), 0) };
        assert_eq!(nm2_test_capture_drain(), "Hi");
    }

    #[test]
    fn write_ustr_decodes_surrogate_pairs() {
        let data = [0xD83D, 0xDE00, 0];
        nm2_test_capture_start();
        unsafe { nm2_io_write_ustr(data.as_ptr(), 0) };
        assert_eq!(nm2_test_capture_drain(), "😀");
    }

    #[test]
    fn write_uchar_preserves_unpaired_surrogate_visibly() {
        nm2_test_capture_start();
        nm2_io_write_uchar(0xD800);
        assert_eq!(nm2_test_capture_drain(), "\\u{D800}");
    }

    #[test]
    fn write_uint_uses_shared_integer_formatting() {
        nm2_test_capture_start();
        nm2_io_write_uint(-42, 0);
        assert_eq!(nm2_test_capture_drain(), "-42");
    }

    #[test]
    fn write_ucard_uses_shared_cardinal_formatting() {
        nm2_test_capture_start();
        nm2_io_write_ucard(42, 0);
        assert_eq!(nm2_test_capture_drain(), "42");
    }
}
