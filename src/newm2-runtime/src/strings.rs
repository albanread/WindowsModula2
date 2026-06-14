//! NewM2 string-handling runtime primitives.
//!
//! Currently just `nm2_copy_string`, the backing for the ISO 10514-1 `COPY`
//! standard procedure. As more string-related builtins land (CONCAT, LENGTH,
//! comparison helpers, ...), they belong here.
//!
//! Strings at the M2 level are NUL-terminated `ARRAY OF CHAR` buffers; the
//! runtime helpers operate on raw byte pointers + capacity.

/// `LENGTH(s)` — number of CHAR cells in `s` up to but not including
/// the first NUL. Bounded by the open-array's HIGH companion so the
/// scan stops cleanly on a non-NUL-terminated buffer.
///
/// # Safety
/// `ptr` must be null or point to at least `high + 1` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_string_length(ptr: *const u8, high: u64) -> u64 {
    if ptr.is_null() {
        return 0;
    }
    let cap = high.saturating_add(1) as usize;
    let mut n = 0usize;
    while n < cap {
        if unsafe { *ptr.add(n) } == 0 {
            break;
        }
        n += 1;
    }
    n as u64
}

/// Wide (`CHAR` = UTF-16) variant of [`nm2_string_length`]: number of CHAR
/// cells up to but not including the first NUL, bounded by the open-array's
/// HIGH companion. `ptr` addresses 16-bit code units.
///
/// # Safety
/// `ptr` must be null or point to at least `high + 1` readable 16-bit cells.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_wstr_length(ptr: *const u16, high: u64) -> u64 {
    if ptr.is_null() {
        return 0;
    }
    let cap = high.saturating_add(1) as usize;
    let mut n = 0usize;
    while n < cap {
        if unsafe { *ptr.add(n) } == 0 {
            break;
        }
        n += 1;
    }
    n as u64
}

/// `COPY(src, VAR dst)` — copy NUL-terminated `src` into `dst`, capping at
/// `cap` bytes (intended to be the destination's `HIGH + 1`). The
/// destination is always NUL-terminated after the call: if `src` is
/// shorter than `cap-1`, the NUL is placed after the last copied byte;
/// otherwise it is placed at `dst[cap-1]` and the source is truncated.
///
/// Sentinel `cap` values:
///  - 0: no capacity known (open-array destination with no carried bound);
///    we still copy until the src NUL and write a NUL. This is unsafe if
///    `dst` isn't actually large enough, but matches what we can express
///    today and lines up with how the existing I/O shims treat M2 strings.
///
/// # Safety
/// Both pointers must be non-null and reference valid memory: `src` up to
/// (and including) its NUL terminator; `dst` up to `cap` writable bytes
/// (or whatever the M2 caller's open-array actually holds when `cap == 0`).
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_copy_string(
    src: *const u8,
    dst: *mut u8,
    cap: u64,
) {
    if src.is_null() || dst.is_null() {
        return;
    }
    let cap = if cap == 0 { u64::MAX } else { cap };
    let mut i: u64 = 0;
    // Leave room for the NUL terminator.
    let max = cap.saturating_sub(1);
    while i < max {
        // SAFETY: caller guarantees src is NUL-terminated within its buffer.
        let b = unsafe { *src.add(i as usize) };
        if b == 0 {
            break;
        }
        // SAFETY: i < max <= cap-1 < cap, and cap reflects dst's writable size.
        unsafe { *dst.add(i as usize) = b };
        i += 1;
    }
    unsafe { *dst.add(i as usize) = 0 };
}

/// Wide (`CHAR` = UTF-16) variant of [`nm2_copy_string`]: copy NUL-terminated
/// `src` into `dst`, both arrays of 16-bit code units, capping at `cap` cells
/// (the destination's element count, i.e. `HIGH + 1`). If the source is shorter
/// than the destination, a wide NUL is written after the last copied cell; if
/// the source fills the destination exactly, no terminator is written (ISO
/// `ARRAY OF CHAR` assignment leaves a full buffer unterminated). `cap == 0`
/// means "capacity unknown" — copy up to the source NUL and terminate.
///
/// # Safety
/// `src` must be NUL-terminated within its buffer; `dst` must address at least
/// `cap` writable 16-bit cells (or the M2 caller's actual buffer when `cap==0`).
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_copy_wstring(src: *const u16, dst: *mut u16, cap: u64) {
    if src.is_null() || dst.is_null() {
        return;
    }
    let cap = if cap == 0 { u64::MAX } else { cap };
    let mut i: u64 = 0;
    while i < cap {
        let c = unsafe { *src.add(i as usize) };
        if c == 0 {
            break;
        }
        unsafe { *dst.add(i as usize) = c };
        i += 1;
    }
    // Terminate only when there is room (the source did not fill `dst`).
    if i < cap {
        unsafe { *dst.add(i as usize) = 0 };
    }
}

/// Copy a WIDE (UTF-16) source string into a NARROW (8-bit ACHAR) destination,
/// truncating each code unit to its low byte. Used to assign a string literal
/// (stored internally as UTF-16) to an `ARRAY OF ACHAR`; for the ASCII/ANSI
/// content this is used for, the low byte IS the character.
///
/// # Safety
/// `src` must be NUL-terminated within its buffer; `dst` must address at least
/// `cap` writable bytes (or the M2 caller's actual buffer when `cap==0`).
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_copy_wstring_narrow(src: *const u16, dst: *mut u8, cap: u64) {
    if src.is_null() || dst.is_null() {
        return;
    }
    let cap = if cap == 0 { u64::MAX } else { cap };
    let mut i: u64 = 0;
    let max = cap.saturating_sub(1);
    while i < max {
        let c = unsafe { *src.add(i as usize) };
        if c == 0 {
            break;
        }
        unsafe { *dst.add(i as usize) = (c & 0xFF) as u8 };
        i += 1;
    }
    if i < cap {
        unsafe { *dst.add(i as usize) = 0 };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_copy(src: &[u8], dst_cap: usize) -> Vec<u8> {
        let mut dst = vec![0xFFu8; dst_cap];
        unsafe { nm2_copy_string(src.as_ptr(), dst.as_mut_ptr(), dst_cap as u64) };
        dst
    }

    #[test]
    fn copies_short_string_and_nul_terminates() {
        let out = run_copy(b"hi\0", 8);
        assert_eq!(&out[..3], b"hi\0");
    }

    #[test]
    fn truncates_when_dst_is_smaller() {
        let out = run_copy(b"abcdef\0", 4);
        // cap=4 leaves max=3 chars + NUL.
        assert_eq!(&out[..4], b"abc\0");
    }

    #[test]
    fn empty_src_yields_just_nul() {
        let out = run_copy(b"\0", 8);
        assert_eq!(out[0], 0);
    }

    #[test]
    fn cap_zero_treats_dst_as_unbounded() {
        // We can't test "infinite cap" safely; allocate something large
        // and confirm a normal short copy still works.
        let mut dst = vec![0u8; 64];
        unsafe { nm2_copy_string(b"hello\0".as_ptr(), dst.as_mut_ptr(), 0) };
        assert_eq!(&dst[..6], b"hello\0");
    }
}
