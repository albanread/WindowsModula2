//! Floating-point primitives backing the ISO `LowReal` / `LowLong`
//! modules: `frexp`, `ldexp`, `modf` and a few related helpers that
//! don't map to a single LLVM intrinsic.
//!
//! All operate on `f64`. The Modula-2 `LowReal` port (`REAL` = f32 in
//! NewM2) widens to LONGREAL on the M2 side before calling these.

/// `frexp(x)` — split `x` into a normalized fraction `m` in `[0.5, 1.0)`
/// (or 0 for x=0) and a power-of-two exponent `e` such that `x = m * 2^e`.
/// `0`, `±inf`, and NaN return `(x, 0)`. Bound to `NM2.Math.Frexp`.
///
/// `out_exp` is `*mut i64` to match Modula-2 `INTEGER` (NewM2 = 8 bytes).
/// A narrower i32 would leave the upper four bytes uninitialised, which
/// in the M2 caller reads back as random garbage. (We learned that one
/// the hard way — `exponent(8.0)` came back as `777389080580` instead
/// of `4` before this fix.)
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_math_frexp(
    x: f64,
    out_exp: *mut i64,
) -> f64 {
    if out_exp.is_null() {
        return x;
    }
    if x == 0.0 || !x.is_finite() {
        unsafe { *out_exp = 0 };
        return x;
    }
    let bits = x.to_bits();
    let raw_exp = ((bits >> 52) & 0x7FF) as i64;
    if raw_exp == 0 {
        // Subnormal — normalise by repeatedly doubling. Simpler than
        // a bit-counting variant for code we'll rarely hit at runtime.
        let mut m = x;
        let mut e: i64 = 0;
        while m.abs() < 0.5 {
            m *= 2.0;
            e -= 1;
        }
        unsafe { *out_exp = e };
        return m;
    }
    // Normal: set the biased exponent to 1022 so the implicit-leading-1
    // mantissa renders the fraction in `[0.5, 1.0)`.
    let new_bits = (bits & !(0x7FFu64 << 52)) | (1022u64 << 52);
    let fraction = f64::from_bits((bits & (1u64 << 63)) | (new_bits & !(1u64 << 63)));
    unsafe { *out_exp = raw_exp - 1022 };
    fraction
}

/// `ldexp(x, n)` — `x * 2^n`. `n` is `i64` to match Modula-2 INTEGER.
/// Bound to `NM2.Math.Ldexp`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_ldexp(x: f64, n: i64) -> f64 {
    if x == 0.0 || !x.is_finite() {
        return x;
    }
    // Clamp n to i32 before powi — beyond ±1023 the result is either
    // 0 or ±inf anyway, and powi takes i32.
    let n_clamped = n.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
    x * (2.0f64).powi(n_clamped)
}

/// `modf(x)` — split `x` into integer and fractional parts. Both share
/// `x`'s sign. Returns the fractional part; integer part is written to
/// `*out_int`. Bound to `NM2.Math.Modf`.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_math_modf(
    x: f64,
    out_int: *mut f64,
) -> f64 {
    if out_int.is_null() {
        return x;
    }
    if !x.is_finite() {
        unsafe { *out_int = x };
        return if x.is_nan() { x } else { x.copysign(0.0) };
    }
    let ipart = x.trunc();
    unsafe { *out_int = ipart };
    x - ipart
}

// ── Transcendental / power primitives (NM2Math.*) ────────────────────────────
//
// REAL and LONGREAL are both `f64` in this build, so each function backs both
// the plain (REAL) and the `L`-prefixed (LONGREAL) NM2Math procedure. Bound by
// name in newm2-llvm; the ISO RealMath / LongMath bodies call them qualified.

macro_rules! math1 {
    ($name:ident, $method:ident) => {
        #[unsafe(no_mangle)]
        pub extern "C-unwind" fn $name(x: f64) -> f64 {
            x.$method()
        }
    };
}

math1!(nm2_math_sin, sin);
math1!(nm2_math_cos, cos);
math1!(nm2_math_tan, tan);
math1!(nm2_math_arcsin, asin);
math1!(nm2_math_arccos, acos);
math1!(nm2_math_arctan, atan);
math1!(nm2_math_exp, exp);
math1!(nm2_math_ln, ln);
math1!(nm2_math_lg, log2);
math1!(nm2_math_sqrt, sqrt);
math1!(nm2_math_sinh, sinh);
math1!(nm2_math_cosh, cosh);
math1!(nm2_math_tanh, tanh);
math1!(nm2_math_arcsinh, asinh);
math1!(nm2_math_arccosh, acosh);
math1!(nm2_math_arctanh, atanh);
math1!(nm2_math_floor, floor);

/// `arctan2(y, x)` — the angle of the point (x, y).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_arctan2(y: f64, x: f64) -> f64 {
    y.atan2(x)
}

/// `pow(base, exponent)` — `base ** exponent`.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_pow(base: f64, exponent: f64) -> f64 {
    base.powf(exponent)
}

/// `truncToInt(x)` — truncate towards zero to a signed INTEGER.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_trunc_to_int(x: f64) -> i64 {
    x.trunc() as i64
}

/// `truncToCard(x)` — truncate towards zero to a CARDINAL.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_math_trunc_to_card(x: f64) -> u64 {
    x.trunc() as u64
}
