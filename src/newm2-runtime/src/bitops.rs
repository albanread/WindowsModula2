//! `SYSTEM.SHIFT` and `SYSTEM.ROTATE` runtime helpers.
//!
//! These operate on a bit pattern of a given `width` (8/16/32/64). The compiler
//! lowers `SHIFT(v, n)` / `ROTATE(v, n)` to a call carrying the value
//! zero-extended to 64 bits, the (signed) count, and the operand's bit width.

/// Low `width` bits set; `width == 64` is all ones.
fn mask_for(width: u64) -> u64 {
    if width >= 64 {
        u64::MAX
    } else {
        (1u64 << width) - 1
    }
}

/// `SYSTEM.SHIFT(v, n)` — logical shift of the low `width` bits of `val`:
/// left by `n` when `n >= 0`, right by `-n` when `n < 0`. Vacated bits are
/// zero; bits shifted past the width are lost.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_shift(val: u64, count: i64, width: u64) -> u64 {
    let width = width.clamp(1, 64);
    let mask = mask_for(width);
    let v = val & mask;
    let out = if count >= 0 {
        let c = count as u64;
        if c >= width as u64 { 0 } else { v << c }
    } else {
        let c = count.unsigned_abs();
        if c >= width as u64 { 0 } else { v >> c }
    };
    out & mask
}

/// `SYSTEM.ROTATE(v, n)` — rotate the low `width` bits of `val`: left by `n`
/// when `n >= 0`, right by `-n` when `n < 0`. The rotation wraps within
/// `width` bits.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_rotate(val: u64, count: i64, width: u64) -> u64 {
    let width = width.clamp(1, 64);
    let mask = mask_for(width);
    let v = val & mask;
    let w = width as i64;
    // Normalise the rotation amount to [0, width).
    let r = (((count % w) + w) % w) as u64;
    if r == 0 {
        return v;
    }
    ((v << r) | (v >> (width - r))) & mask
}
