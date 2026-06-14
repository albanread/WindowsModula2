//! Native callback interop.
//!
//! The COM-server proof shows external code calling *into* M2 through a vtable;
//! this shows external code calling into an M2 **procedure** through a raw C
//! function pointer — the other half of "sink/callback". An M2 procedure
//! variable lowers to an ordinary function pointer (the Microsoft x64 ABI on
//! this target), so a procedure can be handed to any C API expecting a
//! callback. `nm2_sort_i64` is a self-contained demonstration: it sorts an
//! array of `INTEGER` (i64) in place, deciding order by calling back into an
//! M2-supplied comparator for every comparison.

/// Sort `n` `i64`s at `arr` in place, ordering by the M2 comparator `cmp`
/// (`< 0` ⇒ a before b, like C `qsort` / M2 `a - b`). Every comparison is a
/// call back into M2 code through the supplied function pointer.
///
/// # Safety
/// `arr` must point at `n` writable, contiguous `i64`s and `cmp` must be a live
/// procedure of type `PROCEDURE (INTEGER, INTEGER): INTEGER`.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_sort_i64(
    arr: *mut i64,
    n: usize,
    cmp: extern "C-unwind" fn(i64, i64) -> i64,
) {
    if arr.is_null() || n < 2 {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts_mut(arr, n) };
    slice.sort_by(|&a, &b| cmp(a, b).cmp(&0));
}
