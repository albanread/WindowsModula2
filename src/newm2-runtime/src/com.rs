//! COM interop glue.
//!
//! NewM2's class object layout — a pointer to `{ vtable_ptr, fields… }` — and
//! its virtual dispatch (load the vtable pointer, load the slot, call with the
//! receiver as the first argument) are exactly the Microsoft COM ABI. So an M2
//! class declared with the interface methods in IUnknown order can *consume* a
//! real OS COM object: hold the interface pointer in a class variable and call
//! its methods through ordinary virtual dispatch.
//!
//! This module supplies the OS entry points (apartment init, the task
//! allocator) via the `windows-sys` crate, plus a GUID equality helper for
//! `QueryInterface` dispatch.

use core::ffi::c_void;

#[cfg(windows)]
use windows_sys::Win32::System::Com::{
    CoGetMalloc, CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED,
};

/// `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)` — initialise COM on this
/// thread. Returns the HRESULT (0 = S_OK, 1 = S_FALSE already-initialised).
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_com_init() -> i32 {
    #[cfg(windows)]
    unsafe {
        CoInitializeEx(core::ptr::null(), COINIT_APARTMENTTHREADED as u32)
    }
    #[cfg(not(windows))]
    {
        -1
    }
}

/// `CoUninitialize()` — tear down COM on this thread.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_com_uninit() {
    #[cfg(windows)]
    unsafe {
        CoUninitialize();
    }
}

/// `CoGetMalloc(1, &p)` — the process's COM task allocator (`IMalloc*`). Returns
/// the interface pointer, or NULL on failure. Used to demonstrate consuming a
/// real OS COM object through M2 virtual dispatch.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_com_get_malloc() -> *mut c_void {
    #[cfg(windows)]
    unsafe {
        let mut p: *mut c_void = core::ptr::null_mut();
        let hr = CoGetMalloc(1, &mut p as *mut *mut c_void as *mut _);
        if hr == 0 { p } else { core::ptr::null_mut() }
    }
    #[cfg(not(windows))]
    {
        core::ptr::null_mut()
    }
}

/// The vtable shape of an M2 class that implements `IUnknown` plus one custom
/// `Bump` slot, in declaration order. Each method takes the object pointer as
/// its first argument (`this` / `SELF`) — exactly the COM ABI. M2 `INTEGER` is
/// `i64`; `ADDRESS` is a pointer.
#[repr(C)]
struct IUnknownPlusVtbl {
    // QueryInterface(this, riid, ppv) -> HRESULT
    query_interface: unsafe extern "C-unwind" fn(*mut c_void, *const c_void, *mut c_void) -> i64,
    // AddRef(this) -> new ref count
    add_ref: unsafe extern "C-unwind" fn(*mut c_void) -> i64,
    // Release(this) -> new ref count
    release: unsafe extern "C-unwind" fn(*mut c_void) -> i64,
    // Bump(this, delta) -> new value  (the custom server method)
    bump: unsafe extern "C-unwind" fn(*mut c_void, i64) -> i64,
}

/// Drive an **M2-implemented COM object** through the `IUnknown` ABI plus a
/// custom `Bump` slot, exactly as an external COM client would: read the vtable
/// from the object pointer and call each slot with the object as `this`. This is
/// the *server* counterpart to `nm2_com_get_malloc` (consuming): it proves an
/// M2 class object IS a callable COM interface, not just that M2 can call one.
///
/// Sequence: QueryInterface (S_OK, permissive) → Release (balance QI's AddRef)
/// → AddRef → Bump(`d`) → Release. Returns a packed witness so the M2 caller can
/// verify ref counting end to end:
///   `qi_ok*1000 + addref_result*100 + release_result`  (expected `1201`).
/// The object's value field ends up mutated by `Bump`.
///
/// # Safety
/// `punk` must be a live M2 object whose first field is a pointer to an
/// `IUnknownPlusVtbl`-shaped vtable (i.e. a class declaring QueryInterface,
/// AddRef, Release, Bump in that order). The object's ref count must be 1.
#[unsafe(no_mangle)]
pub unsafe extern "C-unwind" fn nm2_com_drive(punk: *mut c_void, d: i64) -> i64 {
    if punk.is_null() {
        return -1;
    }
    // The object pointer's first machine word is the vtable pointer.
    let vtbl = unsafe { *(punk as *const *const IUnknownPlusVtbl) };
    if vtbl.is_null() {
        return -2;
    }
    let v = unsafe { &*vtbl };

    // QueryInterface: permissive M2 impl returns S_OK (0) and AddRefs (refs 1→2).
    let hr = unsafe { (v.query_interface)(punk, core::ptr::null(), core::ptr::null_mut()) };
    let qi_ok = if hr == 0 { 1 } else { 0 };
    // Balance QI's AddRef so the lifetime accounting stays honest (2→1).
    let _ = unsafe { (v.release)(punk) };

    let a = unsafe { (v.add_ref)(punk) }; // 1 → 2
    let _ = unsafe { (v.bump)(punk, d) }; // value += d, through the COM vtable
    let r = unsafe { (v.release)(punk) }; // 2 → 1

    qi_ok * 1000 + a * 100 + r
}

/// `IsEqualGUID(a, b)` — compare two 16-byte GUIDs. The COM `QueryInterface`
/// dispatch chain uses this to match interface identifiers.
#[unsafe(no_mangle)]
pub extern "C-unwind" fn nm2_guid_eq(a: *const c_void, b: *const c_void) -> bool {
    if a.is_null() || b.is_null() {
        return a == b;
    }
    unsafe {
        let a = core::slice::from_raw_parts(a as *const u8, 16);
        let b = core::slice::from_raw_parts(b as *const u8, 16);
        a == b
    }
}
