//! Runtime backing for ISO `ProgramArgs`.
//!
//! The driver records the M2 program's command-line arguments by
//! calling `nm2_program_args_set` (a Rust-side API) before the JIT'd
//! entry body runs. The M2 module reads them through two JIT-bound
//! shims:
//!
//!   `nm2_program_args_count() -> CARDINAL`
//!   `nm2_program_args_copy(idx, addr, max) -> CARDINAL`
//!
//! `copy` writes up to `max` bytes of the requested argument into the
//! buffer and returns the actual count (NOT NUL-terminated; the
//! caller can rely on the returned length, or zero-fill the remainder
//! of its slot manually). Argument 0 by ISO convention is the program
//! name; the driver passes the user-supplied `.mod` filename so the
//! M2 view matches the C view.

use std::sync::Mutex;

static PROGRAM_ARGS: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Rust-side API — called by the driver before `run_modules` to record
/// the M2 program's command-line arguments. The first element is
/// conventionally the program (file) name.
pub fn nm2_program_args_set(args: Vec<String>) {
    let mut state = PROGRAM_ARGS.lock().unwrap();
    *state = args;
}

/// Number of recorded arguments (including program name at index 0).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_program_args_count() -> u64 {
    PROGRAM_ARGS.lock().unwrap().len() as u64
}

/// Copy argument `idx` into the CHAR-cell buffer at `addr` (up to `max`
/// cells, no NUL terminator). NewModula2's CHAR is a wide (UTF-16) cell, so
/// each argument byte is written as one cell (ASCII/Latin-1). Returns the
/// actual number of cells written. Out-of-range `idx` returns 0.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_program_args_copy(
    idx: u64,
    addr: *mut u16,
    max: u64,
) -> u64 {
    if addr.is_null() || max == 0 {
        return 0;
    }
    let state = PROGRAM_ARGS.lock().unwrap();
    let Some(arg) = state.get(idx as usize) else {
        return 0;
    };
    let bytes = arg.as_bytes();
    let dst = unsafe { std::slice::from_raw_parts_mut(addr, max as usize) };
    let n = bytes.len().min(max as usize);
    for (cell, &b) in dst.iter_mut().zip(&bytes[..n]) {
        *cell = b as u16;
    }
    n as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cells(s: &str) -> Vec<u16> {
        s.bytes().map(|b| b as u16).collect()
    }

    #[test]
    fn args_roundtrip() {
        nm2_program_args_set(vec![
            "prog.mod".to_string(),
            "first".to_string(),
            "second".to_string(),
        ]);
        assert_eq!(nm2_program_args_count(), 3);
        let mut buf = [0u16; 32];
        let n = unsafe { nm2_program_args_copy(1, buf.as_mut_ptr(), 32) };
        assert_eq!(n, 5);
        assert_eq!(&buf[..5], cells("first").as_slice());
    }

    #[test]
    fn args_truncate_on_overflow() {
        nm2_program_args_set(vec!["x".into(), "hello world".to_string()]);
        let mut buf = [0u16; 5];
        let n = unsafe { nm2_program_args_copy(1, buf.as_mut_ptr(), 5) };
        assert_eq!(n, 5);
        assert_eq!(&buf, cells("hello").as_slice());
    }

    #[test]
    fn args_out_of_range_returns_zero() {
        nm2_program_args_set(vec!["x".into()]);
        let mut buf = [0u16; 16];
        let n = unsafe { nm2_program_args_copy(42, buf.as_mut_ptr(), 16) };
        assert_eq!(n, 0);
    }
}
